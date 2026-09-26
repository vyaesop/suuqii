"""Sync engine correctness: idempotency, per-event atomicity, poison events.

These pin the batch semantics the offline clients depend on: an event that
is rejected must leave no partial writes, and a single bad event must never
take down the rest of the batch.
"""
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from uuid import uuid4

from sqlalchemy import func, select

from app.models import AuditLog, Debt, Product, Sale, SyncEvent
from app.schemas.sync import SyncEventIn, SyncResultStatus
from app.services.sync_service import SyncService


def _svc(db, shop, user, device="dev-1"):
    return SyncService(db, shop_id=shop.id, user=user, device_id=device)


def _sale_event(product, *, total=None, payment="cash", customer=None,
                quantity="2", unit_price="100.00", unit_cost="80.00",
                sale_id=None, client_event_id=None):
    sale_id = sale_id or uuid4()
    payload = {
        "id": str(sale_id),
        "items": [{
            "id": str(uuid4()),
            "product_id": str(product.id),
            "product_name_snapshot": product.name,
            "quantity": quantity,
            "unit_price": unit_price,
            "unit_cost": unit_cost,
        }],
        "payment_method": payment,
        "occurred_at": datetime.now(UTC).isoformat(),
    }
    if total is not None:
        payload["total"] = total
    if customer is not None:
        payload["customer"] = customer
    return SyncEventIn(
        client_event_id=client_event_id or uuid4(),
        op="sale.create",
        occurred_at=datetime.now(UTC),
        payload=payload,
    )


async def _count(db, model):
    return (await db.execute(select(func.count()).select_from(model))).scalar_one()


async def test_sale_applies_and_totals_recomputed_server_side(db, shop, owner, product):
    svc = _svc(db, shop, owner)
    # Client lies: declares total=0 for a 2×100 sale.
    ev = _sale_event(product, total="0")
    res = await svc.apply(ev)
    assert res.status == SyncResultStatus.APPLIED

    sale = (await db.execute(select(Sale))).scalar_one()
    assert sale.subtotal == Decimal("200.00")
    assert sale.total == Decimal("200.00")           # not the client's 0
    assert sale.cost_total == Decimal("160.00")

    # The mismatch is flagged for the owner.
    audit = (await db.execute(
        select(AuditLog).where(AuditLog.action == "sale.total_mismatch")
    )).scalar_one()
    assert audit.new_value["server_total"] == "200.00"

    # Stock decremented by the delta.
    prod = await db.get(Product, product.id)
    await db.refresh(prod)
    assert prod.stock == Decimal("48")


async def test_duplicate_client_event_id_is_deduped(db, shop, owner, product):
    svc = _svc(db, shop, owner)
    ev = _sale_event(product)
    assert (await svc.apply(ev)).status == SyncResultStatus.APPLIED
    #

    # Same client_event_id again — same batch, no commit in between.
    assert (await svc.apply(ev)).status == SyncResultStatus.DUPLICATE
    assert await _count(db, Sale) == 1
    assert await _count(db, SyncEvent) == 1


async def test_rejected_credit_sale_leaves_no_partial_writes(db, shop, cashier, product):
    """A cashier's over-threshold credit sale w/o owner PIN must be rejected
    AND leave nothing behind: no sale, no debt, no stock decrement, no event."""
    svc = _svc(db, shop, cashier)
    ev = _sale_event(
        product,
        payment="credit",
        quantity="6", unit_price="100.00",   # 600 > 500 threshold
        customer={"name": "Abebe", "phone": "+251911111111"},
    )
    res = await svc.apply(ev)
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "customer_credit_limit_exceeded"

    assert await _count(db, Sale) == 0
    assert await _count(db, Debt) == 0
    assert await _count(db, SyncEvent) == 0
    prod = await db.get(Product, product.id)
    await db.refresh(prod)
    assert prod.stock == Decimal("50")   # untouched


async def test_malformed_payload_rejects_event_but_not_batch(db, shop, owner, product):
    svc = _svc(db, shop, owner)
    bad = SyncEventIn(
        client_event_id=uuid4(),
        op="sale.create",
        occurred_at=datetime.now(UTC),
        payload={"id": "not-a-uuid"},   # missing everything, bad UUID
    )
    good = _sale_event(product)

    res_bad = await svc.apply(bad)
    assert res_bad.status == SyncResultStatus.REJECTED
    assert res_bad.code == "invalid_payload"

    # The batch continues; the good event still applies.
    res_good = await svc.apply(good)
    assert res_good.status == SyncResultStatus.APPLIED
    assert await _count(db, Sale) == 1


async def test_fk_miss_returns_conflict_and_batch_continues(db, shop, owner, product):
    """A sale referencing a product that hasn't synced yet must yield a
    per-event CONFLICT (retryable), not a 500, and not poison the batch."""
    svc = _svc(db, shop, owner)

    ghost = Product(id=uuid4(), shop_id=shop.id, name="ghost",
                    purchase_price=Decimal("1"), selling_price=Decimal("2"),
                    stock=Decimal("0"), low_stock_threshold=Decimal("0"), unit="piece")
    # NOT added to the db — simulates out-of-order sync.
    missing = _sale_event(ghost)
    res = await svc.apply(missing)
    assert res.status == SyncResultStatus.CONFLICT
    assert res.code == "integrity_error"

    # Outer transaction survives; the next event applies cleanly.
    ok = _sale_event(product)
    assert (await svc.apply(ok)).status == SyncResultStatus.APPLIED
    assert await _count(db, Sale) == 1


async def test_unsupported_op_rejected_per_event(db, shop, owner):
    svc = _svc(db, shop, owner)
    ev = SyncEventIn(
        client_event_id=uuid4(),
        op="sale.teleport",
        occurred_at=datetime.now(UTC),
        payload={},
    )
    res = await svc.apply(ev)
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "unsupported_op"


async def test_sensitive_op_requires_owner_pin_for_cashier(db, shop, cashier):
    svc = _svc(db, shop, cashier)
    ev = SyncEventIn(
        client_event_id=uuid4(),
        op="inventory.adjust",
        occurred_at=datetime.now(UTC),
        payload={"product_id": str(uuid4()), "quantity_delta": "5"},
    )
    res = await svc.apply(ev)
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "owner_pin_required"


async def test_challenge_token_is_shop_scoped(db, shop, cashier):
    """A PIN challenge issued for another shop must not authorize ops here."""
    from app.core.security import issue_owner_challenge

    foreign_token = issue_owner_challenge(user_id=uuid4(), shop_id=uuid4())
    svc = SyncService(db, shop_id=shop.id, user=cashier, device_id="dev-1",
                      owner_challenge=foreign_token)
    ev = SyncEventIn(
        client_event_id=uuid4(),
        op="inventory.adjust",
        occurred_at=datetime.now(UTC),
        payload={"product_id": str(uuid4()), "quantity_delta": "5"},
    )
    res = await svc.apply(ev)
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "owner_pin_required"


async def test_inventory_adjust_sums_deltas(db, shop, owner, product):
    svc = _svc(db, shop, owner)
    for delta in ("-3", "10"):
        ev = SyncEventIn(
            client_event_id=uuid4(),
            op="inventory.adjust",
            occurred_at=datetime.now(UTC),
            payload={"product_id": str(product.id), "quantity_delta": delta},
        )
        assert (await svc.apply(ev)).status == SyncResultStatus.APPLIED

    prod = await db.get(Product, product.id)
    await db.refresh(prod)
    assert prod.stock == Decimal("57")   # 50 - 3 + 10


async def test_naive_timestamp_coerced_to_utc(db, shop, owner, product):
    svc = _svc(db, shop, owner)
    ev = _sale_event(product)
    ev.payload["occurred_at"] = "2026-07-11T10:00:00"   # naive
    assert (await svc.apply(ev)).status == SyncResultStatus.APPLIED
    sale = (await db.execute(select(Sale))).scalar_one()
    assert sale.occurred_at == datetime(2026, 7, 11, 10, 0, tzinfo=UTC)


# --- credit due dates and the owner-challenge lifecycle ---------------------


async def test_credit_sale_with_due_date_applies(db, shop, owner, product):
    """`customer.due_date` arrives as "YYYY-MM-DD"; handed to the DATE column
    as a string it failed in the driver and every credit sale with a due date
    came back `internal_error`."""
    svc = _svc(db, shop, owner)
    ev = _sale_event(
        product, payment="credit",
        customer={"name": "Abebe", "phone": "+251911000111", "due_date": "2026-10-01"},
    )
    res = await svc.apply(ev)
    assert res.status == SyncResultStatus.APPLIED, (res.code, res.detail)
    debt = (await db.execute(select(Debt))).scalar_one()
    assert debt.due_date == date(2026, 10, 1)


async def test_credit_sale_without_due_date_applies(db, shop, owner, product):
    """Regression: with no relationship() between Debt and Sale the unit of
    work wrote the debt before the sale (debts_sale_id_fkey) and *every*
    credit sale came back integrity_error, due date or not."""
    res = await _svc(db, shop, owner).apply(
        _sale_event(product, payment="credit", customer={"name": "Abebe"}),
    )
    assert res.status == SyncResultStatus.APPLIED, (res.code, res.detail)
    debt = (await db.execute(select(Debt))).scalar_one()
    assert debt.due_date is None
    assert debt.amount_owed == Decimal("200.00")


def _adjust_event(product_id, token=None, occurred_at=None):
    payload = {"product_id": str(product_id), "quantity_delta": "5"}
    if token:
        payload["owner_challenge"] = token
    return SyncEventIn(
        client_event_id=uuid4(), op="inventory.adjust",
        occurred_at=occurred_at or datetime.now(UTC), payload=payload,
    )


async def test_owner_challenge_survives_a_failed_attempt(db, shop, cashier, owner, product):
    """The approval is spent when the event applies, not when it is checked:
    a retry after a transient failure must not come back owner_pin_required."""
    from app.core.security import issue_owner_challenge

    token = issue_owner_challenge(user_id=owner.id, shop_id=shop.id)
    svc = _svc(db, shop, cashier)
    # A product this device has not synced yet: FK violation, retry later.
    first = await svc.apply(_adjust_event(uuid4(), token))
    assert first.status == SyncResultStatus.CONFLICT
    assert first.code == "integrity_error"
    # The same approval carries the retried work...
    second = await svc.apply(_adjust_event(product.id, token))
    assert second.status == SyncResultStatus.APPLIED, (second.code, second.detail)
    # ...and is then spent.
    third = await svc.apply(_adjust_event(product.id, token))
    assert third.status == SyncResultStatus.REJECTED
    assert third.code == "owner_pin_required"


async def test_owner_challenge_valid_at_action_time_outlives_its_ttl(
    db, shop, cashier, owner, product,
):
    """Offline queue: the PIN is entered when the action happens; the push may
    reach the server long after the token's 5-minute TTL."""
    import jwt

    from app.core.config import settings

    now = datetime.now(UTC)
    issued = now - timedelta(hours=2)
    token = jwt.encode({
        "sub": str(owner.id), "shop_id": str(shop.id), "purpose": "owner_pin",
        "nonce": uuid4().hex, "iat": int(issued.timestamp()),
        "exp": int((issued + timedelta(minutes=5)).timestamp()),
    }, settings.jwt_secret, algorithm="HS256")
    svc = _svc(db, shop, cashier)
    # An action taken after the token died is not covered by it.
    late = await svc.apply(_adjust_event(product.id, token, occurred_at=now))
    assert late.status == SyncResultStatus.REJECTED
    assert late.code == "owner_pin_required"
    # One taken while it was alive is, however late the push.
    in_time = await svc.apply(
        _adjust_event(product.id, token, occurred_at=issued + timedelta(minutes=2)),
    )
    assert in_time.status == SyncResultStatus.APPLIED, (in_time.code, in_time.detail)
