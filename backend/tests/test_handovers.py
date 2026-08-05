"""Baker handovers + production-time ingredient deduction (migration 0011).

Two behaviours are pinned here:

1. Ingredients are consumed by the *bake*, not by the sale. Before 0011 a tray
   that sat unsold kept its flour on the books as unused stock for as long as
   it took to sell — which for real bakery data is weeks, not hours.
2. A handover is two independent counts and nothing else. It moves no stock,
   and the person who declared it cannot be the person who confirms it.
"""
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import uuid4

from sqlalchemy import func, select

from app.models import (
    AuditLog,
    Handover,
    HandoverItem,
    InventoryLog,
    Product,
    Sale,
    StockLot,
    Supply,
    User,
)
from app.models.handover import STATUS_ACCEPTED, STATUS_DISPUTED, STATUS_PENDING
from app.schemas.sync import SyncEventIn, SyncResultStatus
from app.services.sync_service import SyncService


def _svc(db, shop, user, device="dev-1"):
    return SyncService(db, shop_id=shop.id, user=user, device_id=device)


def _ev(op, payload):
    return SyncEventIn(
        client_event_id=uuid4(), op=op,
        occurred_at=datetime.now(UTC), payload=payload,
    )


def _production(product, produced, spoiled=None, lot_id=None):
    p = {
        "id": str(lot_id or uuid4()),
        "product_id": str(product.id),
        "quantity_produced": str(produced),
        "occurred_at": datetime.now(UTC).isoformat(),
    }
    if spoiled is not None:
        p["quantity_spoiled"] = str(spoiled)
    return _ev("production.record", p)


def _sale(product, qty, unit_price="25.00", unit_cost="0", supply_deductions=None):
    p = {
        "id": str(uuid4()),
        "items": [{
            "id": str(uuid4()),
            "product_id": str(product.id),
            "product_name_snapshot": product.name,
            "quantity": str(qty),
            "unit_price": unit_price,
            "unit_cost": unit_cost,
        }],
        "payment_method": "cash",
        "occurred_at": datetime.now(UTC).isoformat(),
    }
    if supply_deductions is not None:
        p["supply_deductions"] = supply_deductions
    return _ev("sale.create", p)


async def _mk_user(db, shop, role, name, phone):
    u = User(id=uuid4(), shop_id=shop.id, name=name, phone=phone,
             password_hash="x", role=role, is_active=True)
    db.add(u)
    await db.flush()
    return u


# ---------- production-time ingredient deduction ----------

async def test_production_deducts_ingredients_for_the_whole_bake(owner_bakery):
    """0.5 kg flour per bread × 20 baked = 10 kg off a 100 kg sack, at bake
    time, with nothing sold yet."""
    db, shop, owner, bread, flour = owner_bakery
    res = await _svc(db, shop, owner).apply(_production(bread, 20))
    assert res.status == SyncResultStatus.APPLIED

    await db.refresh(flour)
    assert flour.quantity_on_hand == Decimal("90")

    prod = await db.get(Product, bread.id)
    await db.refresh(prod)
    assert prod.stock == Decimal("20")


async def test_unsold_stock_does_not_hold_its_ingredients_on_the_books(owner_bakery):
    """The Keol case: 30 baked, 17 sold across the following fortnight, 13 still
    on the shelf. All 15 kg of flour was gone on day one."""
    db, shop, owner, bread, flour = owner_bakery
    svc = _svc(db, shop, owner)
    assert (await svc.apply(_production(bread, 30))).status == SyncResultStatus.APPLIED
    await db.refresh(flour)
    assert flour.quantity_on_hand == Decimal("85")  # 100 - 30×0.5

    for _ in range(17):
        assert (await svc.apply(_sale(bread, 1))).status == SyncResultStatus.APPLIED

    # Selling does not touch ingredients again.
    await db.refresh(flour)
    assert flour.quantity_on_hand == Decimal("85")
    prod = await db.get(Product, bread.id)
    await db.refresh(prod)
    assert prod.stock == Decimal("13")


async def test_spoiled_units_are_not_double_deducted(owner_bakery):
    """Spoilage used to be the only path that deducted ingredients. Now the
    whole bake deducts once, and spoilage only writes off finished units."""
    db, shop, owner, bread, flour = owner_bakery
    res = await _svc(db, shop, owner).apply(_production(bread, 20, spoiled=5))
    assert res.status == SyncResultStatus.APPLIED

    await db.refresh(flour)
    assert flour.quantity_on_hand == Decimal("90")  # 20×0.5, not 25×0.5

    prod = await db.get(Product, bread.id)
    await db.refresh(prod)
    assert prod.stock == Decimal("15")


async def test_legacy_sale_time_supply_deductions_are_ignored(owner_bakery):
    """An old client still sends supply_deductions. Honouring them as well as
    the production deduction would double-count the flour."""
    db, shop, owner, bread, flour = owner_bakery
    svc = _svc(db, shop, owner)
    await svc.apply(_production(bread, 10))
    await db.refresh(flour)
    assert flour.quantity_on_hand == Decimal("95")

    res = await svc.apply(_sale(
        bread, 2,
        supply_deductions=[{"supply_id": str(flour.id), "quantity_delta": "-1.0"}],
    ))
    assert res.status == SyncResultStatus.APPLIED
    await db.refresh(flour)
    assert flour.quantity_on_hand == Decimal("95")


async def test_bakery_sale_consumes_its_production_lot(owner_bakery):
    """Bakery sales used to skip lots entirely, so production lots sat at full
    qty_remaining forever and batch reports were meaningless."""
    db, shop, owner, bread, _flour = owner_bakery
    svc = _svc(db, shop, owner)
    lot_id = uuid4()
    await svc.apply(_production(bread, 10, lot_id=lot_id))
    assert (await svc.apply(_sale(bread, 4))).status == SyncResultStatus.APPLIED

    lot = await db.get(StockLot, lot_id)
    await db.refresh(lot)
    assert lot.qty_remaining == Decimal("6")
    # COGS comes from the recipe-costed lot (0.5 kg × 40.00 = 20.00/unit).
    sale = (await db.execute(select(Sale))).scalar_one()
    assert sale.cost_total == Decimal("80.00")

    logs = (await db.execute(
        select(InventoryLog.movement).where(InventoryLog.shop_id == shop.id)
    )).scalars().all()
    assert "sale" in logs and "production" in logs


async def test_bakery_refund_restores_stock_but_not_flour(owner_bakery):
    """The customer handing the loaf back does not put flour in the sack."""
    db, shop, owner, bread, flour = owner_bakery
    svc = _svc(db, shop, owner)
    await svc.apply(_production(bread, 10))
    sale_ev = _sale(bread, 3)
    await svc.apply(sale_ev)
    await db.refresh(flour)
    flour_after_sale = flour.quantity_on_hand

    res = await svc.apply(_ev("sale.refund", {
        "sale_id": sale_ev.payload["id"],
        "occurred_at": datetime.now(UTC).isoformat(),
    }))
    assert res.status == SyncResultStatus.APPLIED

    prod = await db.get(Product, bread.id)
    await db.refresh(prod)
    assert prod.stock == Decimal("10")          # 10 - 3 + 3
    await db.refresh(flour)
    assert flour.quantity_on_hand == flour_after_sale


# ---------- handovers ----------

async def test_handover_records_two_counts_and_moves_no_stock(owner_bakery):
    db, shop, owner, bread, _flour = owner_bakery
    baker = await _mk_user(db, shop, "baker", "Baker Bekele", "+251900000021")
    seller = await _mk_user(db, shop, "cashier", "Seller Sara", "+251900000022")

    await _svc(db, shop, owner).apply(_production(bread, 20))
    prod = await db.get(Product, bread.id)
    await db.refresh(prod)
    stock_before = prod.stock

    handover_id = uuid4()
    res = await _svc(db, shop, baker).apply(_ev("handover.create", {
        "id": str(handover_id),
        "to_user_id": str(seller.id),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [{"product_id": str(bread.id), "qty_handed": "20"}],
    }))
    assert res.status == SyncResultStatus.APPLIED

    # The control records the transfer; it does not move the goods.
    await db.refresh(prod)
    assert prod.stock == stock_before

    h = await db.get(Handover, handover_id)
    assert h.status == STATUS_PENDING
    assert h.from_user_id == baker.id

    res = await _svc(db, shop, seller).apply(_ev("handover.accept", {
        "handover_id": str(handover_id),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [{"product_id": str(bread.id), "qty_received": "20"}],
    }))
    assert res.status == SyncResultStatus.APPLIED

    await db.refresh(h)
    assert h.status == STATUS_ACCEPTED
    assert h.accepted_by_user_id == seller.id
    item = (await db.execute(select(HandoverItem))).scalar_one()
    await db.refresh(item)
    assert item.variance == Decimal("0.000")
    await db.refresh(prod)
    assert prod.stock == stock_before


async def test_mismatched_counts_are_disputed_and_audited(owner_bakery):
    """The 18-11 row in the Keol sheet: 18 units unaccounted for, absorbed
    silently. Here the gap gets a number, two names and an audit entry."""
    db, shop, owner, bread, _flour = owner_bakery
    baker = await _mk_user(db, shop, "baker", "Baker", "+251900000031")
    seller = await _mk_user(db, shop, "cashier", "Seller", "+251900000032")

    handover_id = uuid4()
    await _svc(db, shop, baker).apply(_ev("handover.create", {
        "id": str(handover_id),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [{"product_id": str(bread.id), "qty_handed": "30"}],
    }))
    await _svc(db, shop, seller).apply(_ev("handover.accept", {
        "handover_id": str(handover_id),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [{"product_id": str(bread.id), "qty_received": "12"}],
    }))

    h = await db.get(Handover, handover_id)
    await db.refresh(h)
    assert h.status == STATUS_DISPUTED

    item = (await db.execute(select(HandoverItem))).scalar_one()
    await db.refresh(item)
    assert item.variance == Decimal("-18.000")

    audit = (await db.execute(
        select(AuditLog).where(AuditLog.action == "handover.variance")
    )).scalar_one()
    assert audit.new_value["lines"][0]["handed"] == "30.000"
    assert audit.new_value["lines"][0]["received"] == "12.000"


async def test_baker_cannot_accept_their_own_handover(owner_bakery):
    """Without this the two counts collapse into one and the control is
    worthless. Enforced server-side because the UI is not a boundary."""
    db, shop, _owner, bread, _flour = owner_bakery
    baker = await _mk_user(db, shop, "baker", "Baker", "+251900000041")

    handover_id = uuid4()
    svc = _svc(db, shop, baker)
    await svc.apply(_ev("handover.create", {
        "id": str(handover_id),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [{"product_id": str(bread.id), "qty_handed": "10"}],
    }))
    res = await svc.apply(_ev("handover.accept", {
        "handover_id": str(handover_id),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [{"product_id": str(bread.id), "qty_received": "10"}],
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "self_accept_forbidden"

    h = await db.get(Handover, handover_id)
    await db.refresh(h)
    assert h.status == STATUS_PENDING


async def test_partial_count_is_rejected(owner_bakery):
    """A handover with an uncounted line has no meaningful variance."""
    db, shop, owner, bread, _flour = owner_bakery
    baker = await _mk_user(db, shop, "baker", "Baker", "+251900000051")
    seller = await _mk_user(db, shop, "cashier", "Seller", "+251900000052")
    cake = Product(id=uuid4(), shop_id=shop.id, name="Cake",
                   purchase_price=Decimal("0"), selling_price=Decimal("80.00"),
                   stock=Decimal("0"), low_stock_threshold=Decimal("0"), unit="piece")
    db.add(cake)
    await db.flush()

    handover_id = uuid4()
    await _svc(db, shop, baker).apply(_ev("handover.create", {
        "id": str(handover_id),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [
            {"product_id": str(bread.id), "qty_handed": "10"},
            {"product_id": str(cake.id), "qty_handed": "4"},
        ],
    }))
    res = await _svc(db, shop, seller).apply(_ev("handover.accept", {
        "handover_id": str(handover_id),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [{"product_id": str(bread.id), "qty_received": "10"}],
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "incomplete_count"


async def test_second_accept_conflicts(owner_bakery):
    db, shop, _owner, bread, _flour = owner_bakery
    baker = await _mk_user(db, shop, "baker", "Baker", "+251900000061")
    seller = await _mk_user(db, shop, "cashier", "Seller", "+251900000062")
    other = await _mk_user(db, shop, "cashier", "Other", "+251900000063")

    handover_id = uuid4()
    await _svc(db, shop, baker).apply(_ev("handover.create", {
        "id": str(handover_id),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [{"product_id": str(bread.id), "qty_handed": "10"}],
    }))
    accept = {
        "handover_id": str(handover_id),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [{"product_id": str(bread.id), "qty_received": "10"}],
    }
    assert (await _svc(db, shop, seller).apply(
        _ev("handover.accept", accept)
    )).status == SyncResultStatus.APPLIED
    res = await _svc(db, shop, other).apply(_ev("handover.accept", accept))
    assert res.status == SyncResultStatus.CONFLICT
    assert res.server["status"] == STATUS_ACCEPTED


async def test_handover_create_is_idempotent(owner_bakery):
    db, shop, _owner, bread, _flour = owner_bakery
    baker = await _mk_user(db, shop, "baker", "Baker", "+251900000071")
    handover_id = uuid4()
    payload = {
        "id": str(handover_id),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [{"product_id": str(bread.id), "qty_handed": "10"}],
    }
    svc = _svc(db, shop, baker)
    assert (await svc.apply(_ev("handover.create", payload))).status == SyncResultStatus.APPLIED
    # Same handover id, different client_event_id — a retry after a lost ack.
    assert (await svc.apply(_ev("handover.create", payload))).status == SyncResultStatus.APPLIED
    count = (await db.execute(
        select(func.count()).select_from(HandoverItem)
    )).scalar_one()
    assert count == 1


# ---------- role enforcement at the sync boundary ----------

async def test_baker_cannot_push_a_sale(owner_bakery):
    db, shop, _owner, bread, _flour = owner_bakery
    baker = await _mk_user(db, shop, "baker", "Baker", "+251900000081")
    res = await _svc(db, shop, baker).apply(_sale(bread, 1))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "forbidden_for_role"
    assert (await db.execute(select(func.count()).select_from(Sale))).scalar_one() == 0


async def test_baker_cannot_push_an_expense_or_collect_debt(owner_bakery):
    db, shop, _owner, _bread, _flour = owner_bakery
    baker = await _mk_user(db, shop, "baker", "Baker", "+251900000091")
    svc = _svc(db, shop, baker)
    for op, payload in (
        ("expense.create", {"id": str(uuid4()), "title": "Fuel", "amount": "100.00",
                            "occurred_at": datetime.now(UTC).isoformat()}),
        ("debt.writeoff", {"debt_id": str(uuid4()),
                           "occurred_at": datetime.now(UTC).isoformat()}),
    ):
        res = await svc.apply(_ev(op, payload))
        assert res.status == SyncResultStatus.REJECTED, op
        assert res.code == "forbidden_for_role", op


async def test_baker_records_production_without_an_owner_pin(owner_bakery):
    """production.record is in SENSITIVE_OPS — a cashier needs the PIN. For a
    baker it is the job, so no challenge is required."""
    db, shop, _owner, bread, _flour = owner_bakery
    baker = await _mk_user(db, shop, "baker", "Baker", "+251900000101")
    cashier = await _mk_user(db, shop, "cashier", "Cashier", "+251900000102")

    assert (await _svc(db, shop, baker).apply(
        _production(bread, 5)
    )).status == SyncResultStatus.APPLIED

    res = await _svc(db, shop, cashier).apply(_production(bread, 5))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "owner_pin_required"


async def test_handover_cannot_reference_another_shops_user(owner_bakery, shop):
    """FKs alone would let a client name a user in a different tenant."""
    db, bakery, _owner, bread, _flour = owner_bakery
    baker = await _mk_user(db, bakery, "baker", "Baker", "+251900000111")
    outsider = await _mk_user(db, shop, "cashier", "Outsider", "+251900000112")

    res = await _svc(db, bakery, baker).apply(_ev("handover.create", {
        "id": str(uuid4()),
        "to_user_id": str(outsider.id),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [{"product_id": str(bread.id), "qty_handed": "10"}],
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "not_found"


async def test_handover_is_bakery_only(db, shop, owner, product):
    baker = await _mk_user(db, shop, "baker", "Baker", "+251900000121")
    res = await _svc(db, shop, baker).apply(_ev("handover.create", {
        "id": str(uuid4()),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [{"product_id": str(product.id), "qty_handed": "10"}],
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "bad_shop_type"


async def test_duplicate_product_in_one_handover_is_rejected(owner_bakery):
    """Two lines for the same product would make the variance ambiguous."""
    db, shop, _owner, bread, _flour = owner_bakery
    baker = await _mk_user(db, shop, "baker", "Baker", "+251900000131")
    res = await _svc(db, shop, baker).apply(_ev("handover.create", {
        "id": str(uuid4()),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [
            {"product_id": str(bread.id), "qty_handed": "10"},
            {"product_id": str(bread.id), "qty_handed": "5"},
        ],
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "invalid_payload"


async def test_rejected_handover_leaves_no_partial_rows(owner_bakery):
    """The parent row is inserted before the lines are validated, so the
    savepoint has to roll it back."""
    db, shop, _owner, bread, _flour = owner_bakery
    baker = await _mk_user(db, shop, "baker", "Baker", "+251900000141")
    res = await _svc(db, shop, baker).apply(_ev("handover.create", {
        "id": str(uuid4()),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [
            {"product_id": str(bread.id), "qty_handed": "10"},
            {"product_id": str(uuid4()), "qty_handed": "5"},  # unknown product
        ],
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert (await db.execute(select(func.count()).select_from(Handover))).scalar_one() == 0
    assert (await db.execute(select(func.count()).select_from(HandoverItem))).scalar_one() == 0


async def test_negative_qty_handed_is_rejected(owner_bakery):
    db, shop, _owner, bread, _flour = owner_bakery
    baker = await _mk_user(db, shop, "baker", "Baker", "+251900000151")
    res = await _svc(db, shop, baker).apply(_ev("handover.create", {
        "id": str(uuid4()),
        "occurred_at": datetime.now(UTC).isoformat(),
        "items": [{"product_id": str(bread.id), "qty_handed": "-3"}],
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "invalid_payload"


async def test_unknown_op_is_rejected_not_500(owner_bakery):
    db, shop, owner, _bread, _flour = owner_bakery
    res = await _svc(db, shop, owner).apply(_ev("payroll.pay_everyone", {}))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "unsupported_op"


async def test_variance_report_attributes_the_gap_to_the_baker(owner_bakery):
    """Net cancels out across days; gross does not. The owner needs gross."""
    db, shop, _owner, bread, _flour = owner_bakery
    baker = await _mk_user(db, shop, "baker", "Baker", "+251900000161")
    seller = await _mk_user(db, shop, "cashier", "Seller", "+251900000162")

    for handed, received in (("30", "12"), ("10", "13")):
        hid = uuid4()
        await _svc(db, shop, baker).apply(_ev("handover.create", {
            "id": str(hid),
            "occurred_at": datetime.now(UTC).isoformat(),
            "items": [{"product_id": str(bread.id), "qty_handed": handed}],
        }))
        await _svc(db, shop, seller).apply(_ev("handover.accept", {
            "handover_id": str(hid),
            "occurred_at": datetime.now(UTC).isoformat(),
            "items": [{"product_id": str(bread.id), "qty_received": received}],
        }))

    row = (await db.execute(
        select(
            func.sum(HandoverItem.variance).label("net"),
            func.sum(func.abs(HandoverItem.variance)).label("gross"),
        )
        .join(Handover, Handover.id == HandoverItem.handover_id)
        .where(
            Handover.shop_id == shop.id,
            Handover.occurred_at >= datetime.now(UTC) - timedelta(days=7),
            HandoverItem.variance != 0,
        )
    )).one()
    assert row.net == Decimal("-15.000")    # -18 + 3
    assert row.gross == Decimal("21.000")   # 18 + 3


async def test_supply_stays_shop_scoped_on_production(owner_bakery, shop):
    """A recipe can only ever draw down its own shop's supplies."""
    db, bakery, owner, bread, flour = owner_bakery
    other_flour = Supply(id=uuid4(), shop_id=shop.id, name="Other Flour", unit="kg",
                         quantity_on_hand=Decimal("50"), reorder_threshold=Decimal("5"),
                         cost_per_unit=Decimal("40.00"))
    db.add(other_flour)
    await db.flush()

    await _svc(db, bakery, owner).apply(_production(bread, 10))
    await db.refresh(other_flour)
    assert other_flour.quantity_on_hand == Decimal("50")
    await db.refresh(flour)
    assert flour.quantity_on_hand == Decimal("95")
