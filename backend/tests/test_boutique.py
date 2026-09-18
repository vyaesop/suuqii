"""Boutique shop type (docs/19-boutique-shop-type.md §11, migration 0013).

Styles + variants, partial returns / exchanges, the haggling floor, and the
REST surface around them. Scratch-Postgres pattern: the schema here is built
from metadata, so RLS *policies* are not present — tenant isolation is
exercised at the application layer (shop-scoped queries), and the policy DDL
itself is covered by running the migration up/down.
"""
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select

from app.core.deps import current_token_payload, current_user, db_session
from app.core.security import issue_owner_challenge
from app.main import app
from app.models import (
    AuditLog,
    InventoryLog,
    LotConsumption,
    Product,
    Sale,
    SaleItem,
    SaleReturn,
    SaleReturnItem,
    StockLot,
    Style,
)
from app.schemas.auth import RegisterShopRequest
from app.schemas.sync import SyncEventIn, SyncResultStatus
from app.services.shift_service import ShiftService
from app.services.sync_service import SyncService

# ---------------------------------------------------------------- helpers ---


def _svc(db, shop, user, challenge=None):
    return SyncService(db, shop_id=shop.id, user=user, device_id="dev-1",
                       owner_challenge=challenge)


def _ev(op, payload, client_event_id=None):
    return SyncEventIn(
        client_event_id=client_event_id or uuid4(), op=op,
        occurred_at=datetime.now(UTC), payload=payload,
    )


def _now():
    return datetime.now(UTC).isoformat()


def _variant(size, color, *, sku=None, selling=None, purchase=None, floor=None, threshold="0"):
    v = {"id": str(uuid4()), "size": size, "color": color, "sku": sku,
         "low_stock_threshold": threshold}
    if selling is not None:
        v["selling_price"] = selling
    if purchase is not None:
        v["purchase_price"] = purchase
    if floor is not None:
        v["min_selling_price"] = floor
    return v


def _style_payload(name="Slim jeans", *, variants=None, prefix="JN", selling="1200.00",
                   purchase="800.00", **extra):
    p = {
        "id": str(uuid4()),
        "name": name,
        "brand": "Levi's",
        "category": "Jeans",
        "segment": "men",
        "image_url": None,
        "default_selling_price": selling,
        "default_purchase_price": purchase,
        "size_set": "waist",
        "sku_prefix": prefix,
        "client_updated_at": _now(),
        # SKUs are unique per shop (products_sku_uq), so default variants
        # carry the style's own prefix — two styles in one test must not
        # collide on "JN-32-BLU".
        "variants": variants if variants is not None else [
            _variant("32", "Blue", sku=f"{prefix}-32-BLU" if prefix else None),
            _variant("34", "Blue", sku=f"{prefix}-34-BLU" if prefix else None),
            _variant("32", "Black", sku=f"{prefix}-32-BLA" if prefix else None),
        ],
    }
    p.update(extra)
    return p


def _receive(product_id, qty, cost):
    return _ev("stock.receive", {
        "id": str(uuid4()), "product_id": str(product_id),
        "quantity": qty, "unit_cost": cost, "occurred_at": _now(),
    })


def _sale(lines, *, payment="cash", discount=None, shift_id=None, occurred=None,
          sale_id=None, **extra):
    """lines: [(product, qty, unit_price[, list_price])]."""
    items = []
    for line in lines:
        product, qty, price = line[0], line[1], line[2]
        item = {
            "id": str(uuid4()), "product_id": str(product.id),
            "product_name_snapshot": product.name, "quantity": qty,
            "unit_price": price, "unit_cost": str(product.purchase_price),
        }
        if len(line) > 3 and line[3] is not None:
            item["list_price"] = line[3]
        items.append(item)
    p = {
        "id": str(sale_id or uuid4()), "items": items, "payment_method": payment,
        "occurred_at": (occurred or datetime.now(UTC)).isoformat(),
    }
    if discount is not None:
        p["discount"] = discount
    if shift_id is not None:
        p["shift_id"] = str(shift_id)
    p.update(extra)
    return _ev("sale.create", p)


def _return(sale_ev, lines, *, refund="0", method=None, exchange=None, reason="wrong_size",
            return_id=None, shift_id=None, occurred=None):
    """lines: [(item_index, qty, condition)]."""
    return _ev("sale.return", {
        "id": str(return_id or uuid4()),
        "sale_id": sale_ev.payload["id"],
        "shift_id": str(shift_id) if shift_id else None,
        "occurred_at": (occurred or datetime.now(UTC)).isoformat(),
        "items": [
            {"id": str(uuid4()), "sale_item_id": sale_ev.payload["items"][idx]["id"],
             "quantity": qty, "condition": cond}
            for idx, qty, cond in lines
        ],
        "refund_amount": refund,
        "refund_method": method,
        "exchange_sale_id": exchange,
        "reason": reason,
        "note": None,
    })


async def _create_style(db, shop, owner, **kw):
    payload = _style_payload(**kw)
    res = await _svc(db, shop, owner).apply(_ev("style.create", payload))
    assert res.status == SyncResultStatus.APPLIED, res
    variants = {
        (v.size, v.color): v for v in (await db.execute(
            select(Product).where(Product.style_id == payload["id"])
        )).scalars().all()
    }
    return payload, variants


async def _count(db, model, *where):
    return (await db.execute(select(func.count()).select_from(model).where(*where))).scalar_one()


async def _fresh(db, obj):
    await db.refresh(obj)
    return obj


@pytest.fixture
async def client(db):
    """HTTP client with the test session injected; caller sets `as_user`.

    `require_cap` reads the token payload directly, so that dependency is
    overridden too and derived from the same user.
    """
    holder = {}

    async def _db():
        yield db

    async def _user():
        return holder["user"]

    async def _payload():
        u = holder["user"]
        return {"sub": str(u.id), "shop_id": str(u.shop_id), "role": u.role, "typ": "access"}

    app.dependency_overrides[db_session] = _db
    app.dependency_overrides[current_user] = _user
    app.dependency_overrides[current_token_payload] = _payload
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        c.as_user = lambda u: holder.__setitem__("user", u)  # type: ignore[attr-defined]
        yield c
    app.dependency_overrides.clear()


# ------------------------------------------------------------ phase 0 ------


def test_register_shop_accepts_boutique_and_rejects_unknown():
    base = {"shop_name": "B", "owner_name": "O", "phone": "0911223344",
            "password": "longpassword", "owner_pin": "4321", "device_fingerprint": "fp"}
    assert RegisterShopRequest(**base, shop_type="boutique").shop_type == "boutique"
    with pytest.raises(ValueError):
        RegisterShopRequest(**base, shop_type="pharmacy")


async def test_baker_invite_needs_a_shop_with_production(client, db, boutique_shop, boutique_owner):
    client.as_user(boutique_owner)
    r = await client.post("/v1/auth/invite", json={"name": "B", "phone": "0911000001", "role": "baker"})
    assert r.status_code == 400
    assert r.json()["code"] == "bad_shop_type"


async def test_production_record_rejected_for_boutique(db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    v = variants[("32", "Blue")]
    res = await _svc(db, boutique_shop, boutique_owner).apply(_ev("production.record", {
        "id": str(uuid4()), "product_id": str(v.id), "quantity_produced": "5",
        "occurred_at": _now(),
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "bad_shop_type"


# ------------------------------------------------------------ phase 1 ------


async def test_style_create_is_atomic_and_idempotent(db, boutique_shop, boutique_owner):
    payload, variants = await _create_style(db, boutique_shop, boutique_owner)
    assert len(variants) == 3
    blue32 = variants[("32", "Blue")]
    assert blue32.name == "Slim jeans · 32 · Blue"
    assert blue32.sku == "JN-32-BLU"
    assert blue32.stock == Decimal("0")
    assert blue32.unit == "piece"
    assert blue32.category == "Jeans"
    assert blue32.image_url is None
    assert blue32.selling_price == Decimal("1200.00")
    assert blue32.purchase_price == Decimal("800.00")   # owner may set cost
    assert blue32.client_updated_at is not None

    style = await db.get(Style, payload["id"])
    assert style.sku_prefix == "JN"
    assert style.default_purchase_price == Decimal("800.00")

    # Same style id again (a re-queued event with a new client_event_id) is a
    # no-op: still one style, still three products.
    res = await _svc(db, boutique_shop, boutique_owner).apply(_ev("style.create", payload))
    assert res.status == SyncResultStatus.APPLIED
    assert await _count(db, Style) == 1
    assert await _count(db, Product) == 3


async def test_style_create_rejects_duplicate_variant_in_payload(db, boutique_shop, boutique_owner):
    payload = _style_payload(variants=[
        _variant("32", "Blue"), _variant(" 32 ", "Blue "),   # same after trimming
    ])
    res = await _svc(db, boutique_shop, boutique_owner).apply(_ev("style.create", payload))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "invalid_payload"
    # Atomic: nothing half-applied.
    assert await _count(db, Style) == 0
    assert await _count(db, Product) == 0


async def test_style_create_bounds_and_enums(db, boutique_shop, boutique_owner):
    svc = _svc(db, boutique_shop, boutique_owner)
    res = await svc.apply(_ev("style.create", _style_payload(variants=[])))
    assert res.code == "invalid_payload"
    res = await svc.apply(_ev("style.create", _style_payload(segment="teen")))
    assert res.code == "invalid_payload"
    assert await _count(db, Style) == 0


async def test_style_create_cashier_pin_gated_and_cost_masked(
    db, boutique_shop, boutique_owner, boutique_cashier,
):
    payload = _style_payload()
    res = await _svc(db, boutique_shop, boutique_cashier).apply(_ev("style.create", payload))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "owner_pin_required"

    token = issue_owner_challenge(user_id=boutique_owner.id, shop_id=boutique_shop.id)
    res = await _svc(db, boutique_shop, boutique_cashier, challenge=token).apply(
        _ev("style.create", payload)
    )
    assert res.status == SyncResultStatus.APPLIED
    # A cashier — even with the owner's PIN — does not get to set cost.
    style = await db.get(Style, payload["id"])
    assert style.default_purchase_price == Decimal("0")
    costs = {p.purchase_price for p in (await db.execute(select(Product))).scalars().all()}
    assert costs == {Decimal("0")}


async def test_style_update_recomposes_names_skus_and_marks_down(db, boutique_shop, boutique_owner):
    payload, variants = await _create_style(db, boutique_shop, boutique_owner)
    blue32 = variants[("32", "Blue")]
    later = (datetime.now(UTC) + timedelta(seconds=5)).isoformat()

    res = await _svc(db, boutique_shop, boutique_owner).apply(_ev("style.update", {
        "id": payload["id"], "client_updated_at": later,
        "name": "Straight jeans", "sku_prefix": "SJ", "category": "Denim",
        "default_selling_price": "900.00", "apply_price_to_variants": True,
    }))
    assert res.status == SyncResultStatus.APPLIED

    await db.refresh(blue32)
    assert blue32.name == "Straight jeans · 32 · Blue"
    assert blue32.sku == "SJ-32-BLU"
    assert blue32.category == "Denim"
    assert blue32.selling_price == Decimal("900.00")
    assert blue32.client_updated_at.isoformat() == later

    audit = (await db.execute(
        select(AuditLog).where(AuditLog.action == "style.markdown")
    )).scalar_one()
    assert audit.old_value["default_selling_price"] == "1200.00"
    assert audit.new_value["default_selling_price"] == "900.00"
    assert audit.new_value["variant_count"] == 3


async def test_style_update_untouched_variants_keep_their_timestamp(db, boutique_shop, boutique_owner):
    payload, variants = await _create_style(db, boutique_shop, boutique_owner)
    blue32 = variants[("32", "Blue")]
    original_ts = blue32.client_updated_at
    later = (datetime.now(UTC) + timedelta(seconds=5)).isoformat()

    # Brand only: no variant is affected, so none is touched.
    res = await _svc(db, boutique_shop, boutique_owner).apply(_ev("style.update", {
        "id": payload["id"], "client_updated_at": later, "brand": "Turkish",
    }))
    assert res.status == SyncResultStatus.APPLIED
    await db.refresh(blue32)
    assert blue32.client_updated_at == original_ts
    assert await _count(db, AuditLog, AuditLog.action == "style.markdown") == 0

    # A stale timestamp is a conflict, as for product.update.
    res = await _svc(db, boutique_shop, boutique_owner).apply(_ev("style.update", {
        "id": payload["id"], "client_updated_at": payload["client_updated_at"], "brand": "X",
    }))
    assert res.status == SyncResultStatus.CONFLICT


async def test_markdown_is_owner_only_even_with_pin(db, boutique_shop, boutique_owner, boutique_cashier):
    payload, variants = await _create_style(db, boutique_shop, boutique_owner)
    token = issue_owner_challenge(user_id=boutique_owner.id, shop_id=boutique_shop.id)
    later = (datetime.now(UTC) + timedelta(seconds=5)).isoformat()
    res = await _svc(db, boutique_shop, boutique_cashier, challenge=token).apply(_ev("style.update", {
        "id": payload["id"], "client_updated_at": later,
        "default_selling_price": "900.00", "apply_price_to_variants": True,
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "forbidden"
    # Rejected atomically: neither the style nor its variants were repriced.
    assert (await db.get(Style, payload["id"])).default_selling_price == Decimal("1200.00")
    v = variants[("32", "Blue")]
    await db.refresh(v)
    assert v.selling_price == Decimal("1200.00")
    assert await _count(db, AuditLog, AuditLog.action == "style.markdown") == 0


async def test_style_delete_refuses_with_stock_then_succeeds(db, boutique_shop, boutique_owner):
    payload, variants = await _create_style(db, boutique_shop, boutique_owner)
    blue32 = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    assert (await svc.apply(_receive(blue32.id, "2", "800.00"))).status == SyncResultStatus.APPLIED

    res = await svc.apply(_ev("style.delete", {"id": payload["id"]}))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "style_has_stock"
    assert (await db.get(Style, payload["id"])).deleted_at is None

    assert (await svc.apply(_ev("stock.spoil", {
        "product_id": str(blue32.id), "quantity": "2", "occurred_at": _now(),
    }))).status == SyncResultStatus.APPLIED
    res = await svc.apply(_ev("style.delete", {"id": payload["id"]}))
    assert res.status == SyncResultStatus.APPLIED
    assert (await db.get(Style, payload["id"])).deleted_at is not None
    live = await _count(db, Product, Product.deleted_at.is_(None))
    assert live == 0
    # Idempotent.
    assert (await svc.apply(_ev("style.delete", {"id": payload["id"]}))).status == SyncResultStatus.APPLIED


async def test_style_add_variants(db, boutique_shop, boutique_owner):
    payload, _ = await _create_style(db, boutique_shop, boutique_owner)
    svc = _svc(db, boutique_shop, boutique_owner)
    new = _variant("36", "Blue", sku="JN-36-BLU")
    res = await svc.apply(_ev("style.add_variants", {
        "style_id": payload["id"], "client_updated_at": _now(), "variants": [new],
    }))
    assert res.status == SyncResultStatus.APPLIED
    added = await db.get(Product, new["id"])
    assert added.name == "Slim jeans · 36 · Blue"
    assert added.style_id.hex == payload["id"].replace("-", "")

    # Same variant id again → no-op; a different id for a live (size, colour)
    # → variant_exists.
    res = await svc.apply(_ev("style.add_variants", {
        "style_id": payload["id"], "client_updated_at": _now(), "variants": [new],
    }))
    assert res.status == SyncResultStatus.APPLIED
    assert await _count(db, Product) == 4
    res = await svc.apply(_ev("style.add_variants", {
        "style_id": payload["id"], "client_updated_at": _now(),
        "variants": [_variant("36", "Blue")],
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "variant_exists"


async def test_product_update_recomposes_name_for_variant(db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    blue32 = variants[("32", "Blue")]
    res = await _svc(db, boutique_shop, boutique_owner).apply(_ev("product.update", {
        "id": str(blue32.id), "client_updated_at": (datetime.now(UTC) + timedelta(seconds=5)).isoformat(),
        "color": "Red", "min_selling_price": "1000.00",
    }))
    assert res.status == SyncResultStatus.APPLIED
    await db.refresh(blue32)
    assert blue32.name == "Slim jeans · 32 · Red"
    assert blue32.min_selling_price == Decimal("1000.00")


# ------------------------------------------------------------ phase 2 ------


async def test_sale_return_partial_reverses_only_that_items_lot(db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a, b = variants[("32", "Blue")], variants[("34", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    await svc.apply(_receive(b.id, "10", "800.00"))
    sale_ev = _sale([(a, "2", "1200.00"), (b, "1", "1200.00")])
    assert (await svc.apply(sale_ev)).status == SyncResultStatus.APPLIED

    ret = _return(sale_ev, [(0, "1", "resellable")], refund="1200.00", method="cash")
    res = await svc.apply(ret)
    assert res.status == SyncResultStatus.APPLIED, res

    lot_a = (await db.execute(select(StockLot).where(StockLot.product_id == a.id))).scalar_one()
    lot_b = (await db.execute(select(StockLot).where(StockLot.product_id == b.id))).scalar_one()
    await db.refresh(lot_a)
    await db.refresh(lot_b)
    assert lot_a.qty_remaining == Decimal("9")     # 10 − 2 + 1
    assert lot_b.qty_remaining == Decimal("9")     # untouched by the return
    assert (await _fresh(db, a)).stock == Decimal("9")
    assert (await _fresh(db, b)).stock == Decimal("9")

    reversal = (await db.execute(
        select(LotConsumption).where(LotConsumption.movement == "refund_reversal")
    )).scalar_one()
    assert reversal.quantity == Decimal("-1")
    assert reversal.sale_item_id.hex == sale_ev.payload["items"][0]["id"].replace("-", "")

    log = (await db.execute(
        select(InventoryLog).where(InventoryLog.movement == "refund")
    )).scalar_one()
    assert log.reference_type == "sale_return"
    assert str(log.reference_id) == ret.payload["id"]

    sale = await db.get(Sale, sale_ev.payload["id"])
    assert sale.status == "partially_returned"
    item = (await db.execute(select(SaleReturnItem))).scalar_one()
    assert item.unit_price == Decimal("1200.00")


async def test_sale_return_damaged_writes_spoilage_pair_and_keeps_stock(db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    sale_ev = _sale([(a, "2", "1200.00")])
    await svc.apply(sale_ev)

    res = await svc.apply(_return(sale_ev, [(0, "1", "damaged")], refund="1200.00", method="cash",
                                  reason="defect"))
    assert res.status == SyncResultStatus.APPLIED, res

    lot = (await db.execute(select(StockLot))).scalar_one()
    await db.refresh(lot)
    assert lot.qty_remaining == Decimal("8")          # back on, straight off again
    assert (await _fresh(db, a)).stock == Decimal("8")

    spoil = (await db.execute(
        select(LotConsumption).where(LotConsumption.movement == "spoilage")
    )).scalar_one()
    assert spoil.quantity == Decimal("1")
    assert spoil.unit_cost == Decimal("800.00")
    spoil_log = (await db.execute(
        select(InventoryLog).where(InventoryLog.movement == "spoilage")
    )).scalar_one()
    assert spoil_log.reason == "return_damaged"
    assert spoil_log.quantity_delta == Decimal("-1")
    assert await _count(db, InventoryLog, InventoryLog.movement == "refund") == 1


async def test_sale_return_over_return_rejected_and_idempotent(db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    sale_ev = _sale([(a, "2", "1200.00")])
    await svc.apply(sale_ev)

    res = await svc.apply(_return(sale_ev, [(0, "3", "resellable")]))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "return_exceeds_sold"
    assert await _count(db, SaleReturn) == 0

    first = _return(sale_ev, [(0, "2", "resellable")], refund="2400.00", method="cash")
    assert (await svc.apply(first)).status == SyncResultStatus.APPLIED
    # Same event again → duplicate; same return id in a new event → no-op.
    assert (await svc.apply(first)).status == SyncResultStatus.DUPLICATE
    again = _return(sale_ev, [(0, "2", "resellable")], refund="2400.00", method="cash",
                    return_id=first.payload["id"])
    assert (await svc.apply(again)).status == SyncResultStatus.APPLIED
    assert await _count(db, SaleReturn) == 1
    assert (await _fresh(db, a)).stock == Decimal("10")

    # Everything is back: the sale reads refunded; any further return is a conflict.
    sale = await db.get(Sale, sale_ev.payload["id"])
    assert sale.status == "refunded"
    res = await svc.apply(_return(sale_ev, [(0, "1", "resellable")]))
    assert res.status == SyncResultStatus.CONFLICT


async def test_legacy_full_refund_refuses_a_partially_returned_sale(db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    sale_ev = _sale([(a, "2", "1200.00")])
    await svc.apply(sale_ev)
    assert (await svc.apply(_return(sale_ev, [(0, "1", "resellable")]))).status == SyncResultStatus.APPLIED
    res = await svc.apply(_ev("sale.refund", {"sale_id": sale_ev.payload["id"], "occurred_at": _now()}))
    assert res.status == SyncResultStatus.CONFLICT


async def test_sale_return_credit_is_proportional_and_bounds_refund(db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    # 2 × 1000 with a 200 cart discount → total 1800, ratio 0.9 → credit 900/unit.
    sale_ev = _sale([(a, "2", "1000.00")], discount="200.00")
    assert (await svc.apply(sale_ev)).status == SyncResultStatus.APPLIED

    res = await svc.apply(_return(sale_ev, [(0, "1", "resellable")], refund="1000.00", method="cash"))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "invalid_payload"
    res = await svc.apply(_return(sale_ev, [(0, "1", "resellable")], refund="-1", method="cash"))
    assert res.code == "invalid_payload"

    res = await svc.apply(_return(sale_ev, [(0, "1", "resellable")], refund="900.00", method="cash"))
    assert res.status == SyncResultStatus.APPLIED, res
    item = (await db.execute(select(SaleReturnItem))).scalar_one()
    assert item.unit_price == Decimal("900.00")


async def test_sale_return_validates_items_and_references(db, boutique_shop, boutique_owner, shop, owner, product):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    sale_ev = _sale([(a, "2", "1200.00")])
    await svc.apply(sale_ev)
    # A sale in another shop, to point a bogus sale_item_id / exchange_sale_id at.
    other_sale = _sale([(product, "1", "100.00")])
    assert (await _svc(db, shop, owner).apply(other_sale)).status == SyncResultStatus.APPLIED

    bad_item = _return(sale_ev, [(0, "1", "resellable")])
    bad_item.payload["items"][0]["sale_item_id"] = other_sale.payload["items"][0]["id"]
    assert (await svc.apply(bad_item)).code == "invalid_payload"

    bad_cond = _return(sale_ev, [(0, "1", "worn")])
    assert (await svc.apply(bad_cond)).code == "invalid_payload"

    bad_exchange = _return(sale_ev, [(0, "1", "resellable")], exchange=str(uuid4()))
    assert (await svc.apply(bad_exchange)).code == "not_found"
    foreign_exchange = _return(sale_ev, [(0, "1", "resellable")], exchange=other_sale.payload["id"])
    assert (await svc.apply(foreign_exchange)).code == "not_found"

    # A return from another shop against this sale is invisible (RLS-style
    # scoping at the application layer).
    foreign = _return(sale_ev, [(0, "1", "resellable")])
    assert (await _svc(db, shop, owner).apply(foreign)).code == "not_found"
    assert await _count(db, SaleReturn) == 0


async def test_sale_return_cashier_pin_gated(db, boutique_shop, boutique_owner, boutique_cashier):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    sale_ev = _sale([(a, "1", "1200.00")])
    await svc.apply(sale_ev)
    res = await _svc(db, boutique_shop, boutique_cashier).apply(
        _return(sale_ev, [(0, "1", "resellable")])
    )
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "owner_pin_required"


async def test_exchange_links_sales_and_shift_cash_counts_cash_refunds(db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a, b = variants[("32", "Blue")], variants[("34", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    await svc.apply(_receive(b.id, "10", "800.00"))
    shift_id = uuid4()
    assert (await svc.apply(_ev("shift.open", {
        "id": str(shift_id), "opened_at": _now(), "opening_cash": "100.00",
    }))).status == SyncResultStatus.APPLIED

    # Day 1: 1200 cash for a 32.
    original = _sale([(a, "1", "1200.00")], shift_id=shift_id)
    assert (await svc.apply(original)).status == SyncResultStatus.APPLIED
    # Exchange for a 34 priced 1500: new sale carries the 1200 credit as its
    # discount (customer pays 300), then the return links to it, refund 0.
    replacement = _sale([(b, "1", "1500.00")], discount="1200.00", shift_id=shift_id)
    assert (await svc.apply(replacement)).status == SyncResultStatus.APPLIED
    ret = _return(original, [(0, "1", "resellable")], refund="0", exchange=replacement.payload["id"],
                  shift_id=shift_id)
    assert (await svc.apply(ret)).status == SyncResultStatus.APPLIED

    row = (await db.execute(select(SaleReturn))).scalar_one()
    assert str(row.exchange_sale_id) == replacement.payload["id"]
    assert row.refund_amount == Decimal("0")
    assert (await db.get(Sale, original.payload["id"])).status == "refunded"
    assert await _count(db, AuditLog, AuditLog.action == "sale.exchange") == 1

    # Till: 100 + 1200 (original, fully returned but paid in cash) + 300 − 0.
    expected = await ShiftService(db, boutique_shop.id).expected_cash(shift_id, Decimal("100.00"))
    assert expected == Decimal("1600.00")

    # A plain cash refund on another sale in the same shift comes off the till.
    second = _sale([(a, "2", "1200.00")], shift_id=shift_id)
    assert (await svc.apply(second)).status == SyncResultStatus.APPLIED
    assert (await svc.apply(_return(second, [(0, "1", "resellable")], refund="1200.00",
                                    method="cash", shift_id=shift_id))).status == SyncResultStatus.APPLIED
    expected = await ShiftService(db, boutique_shop.id).expected_cash(shift_id, Decimal("100.00"))
    assert expected == Decimal("1600.00") + Decimal("2400.00") - Decimal("1200.00")

    # Mobile-money refunds do not touch cash.
    third = _sale([(a, "1", "1200.00")], shift_id=shift_id)
    assert (await svc.apply(third)).status == SyncResultStatus.APPLIED
    assert (await svc.apply(_return(third, [(0, "1", "resellable")], refund="1200.00",
                                    method="mobile_money", shift_id=shift_id))).status == SyncResultStatus.APPLIED
    expected = await ShiftService(db, boutique_shop.id).expected_cash(shift_id, Decimal("100.00"))
    assert expected == Decimal("2800.00") + Decimal("1200.00")


async def test_legacy_refund_path_unchanged_in_shift_math(db, shop, owner, product):
    svc = _svc(db, shop, owner)
    shift_id = uuid4()
    await svc.apply(_ev("shift.open", {"id": str(shift_id), "opened_at": _now(), "opening_cash": "0"}))
    kept = _sale([(product, "1", "100.00")], shift_id=shift_id)
    refunded = _sale([(product, "1", "100.00")], shift_id=shift_id)
    await svc.apply(kept)
    await svc.apply(refunded)
    before = await ShiftService(db, shop.id).expected_cash(shift_id, Decimal("0"))
    assert before == Decimal("200.00")
    await svc.apply(_ev("sale.refund", {"sale_id": refunded.payload["id"], "occurred_at": _now()}))
    after = await ShiftService(db, shop.id).expected_cash(shift_id, Decimal("0"))
    # Pre-existing behaviour (docs/13): a legacy full refund is subtracted as the
    # whole total and the sale also leaves cash_sales.
    assert after == Decimal("0.00")


async def test_return_outside_window_is_audited_for_owner_only(db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    old = datetime.now(UTC) - timedelta(days=10)
    sale_ev = _sale([(a, "2", "1200.00")], occurred=old)
    await svc.apply(sale_ev)

    # Inside the 7-day window: no audit.
    inside = _return(sale_ev, [(0, "1", "resellable")], occurred=old + timedelta(days=3))
    assert (await svc.apply(inside)).status == SyncResultStatus.APPLIED
    assert await _count(db, AuditLog, AuditLog.action == "sale.return_outside_window") == 0

    outside = _return(sale_ev, [(0, "1", "resellable")], refund="1200.00", method="cash")
    assert (await svc.apply(outside)).status == SyncResultStatus.APPLIED
    audit = (await db.execute(
        select(AuditLog).where(AuditLog.action == "sale.return_outside_window")
    )).scalar_one()
    assert audit.new_value["return_window_days"] == 7
    assert str(audit.entity_id) == outside.payload["id"]


# ------------------------------------------------------------ phase 3 ------


async def test_floor_rule_for_cashier_and_owner(db, boutique_shop, boutique_owner, boutique_cashier):
    _, variants = await _create_style(db, boutique_shop, boutique_owner, variants=[
        _variant("32", "Blue", floor="1000.00"),
    ])
    a = variants[("32", "Blue")]
    await _svc(db, boutique_shop, boutique_owner).apply(_receive(a.id, "10", "800.00"))

    # At or above the floor: fine for anyone.
    ok = await _svc(db, boutique_shop, boutique_cashier).apply(_sale([(a, "1", "1000.00", "1200.00")]))
    assert ok.status == SyncResultStatus.APPLIED

    # Below the floor, cashier, no PIN.
    res = await _svc(db, boutique_shop, boutique_cashier).apply(_sale([(a, "1", "900.00", "1200.00")]))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "below_price_floor"
    assert await _count(db, Sale) == 1

    # With a challenge.
    token = issue_owner_challenge(user_id=boutique_owner.id, shop_id=boutique_shop.id)
    res = await _svc(db, boutique_shop, boutique_cashier, challenge=token).apply(
        _sale([(a, "1", "900.00", "1200.00")])
    )
    assert res.status == SyncResultStatus.APPLIED
    assert await _count(db, AuditLog, AuditLog.action == "sale.below_floor") == 0

    # Owner: accepted and audited.
    owner_sale = _sale([(a, "1", "900.00", "1200.00")])
    res = await _svc(db, boutique_shop, boutique_owner).apply(owner_sale)
    assert res.status == SyncResultStatus.APPLIED
    audit = (await db.execute(
        select(AuditLog).where(AuditLog.action == "sale.below_floor")
    )).scalar_one()
    assert str(audit.entity_id) == owner_sale.payload["id"]
    assert audit.new_value["items"][0]["floor"] == "1000.00"

    item = (await db.execute(
        select(SaleItem).where(SaleItem.sale_id == owner_sale.payload["id"])
    )).scalar_one()
    assert item.list_price == Decimal("1200.00")
    assert item.unit_price == Decimal("900.00")

    # Negative price is malformed for everyone.
    res = await _svc(db, boutique_shop, boutique_owner).apply(_sale([(a, "1", "-1.00")]))
    assert res.code == "invalid_payload"


async def test_floor_without_min_price_only_when_discount_declared(
    db, boutique_shop, boutique_owner, boutique_cashier,
):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)  # no min_selling_price
    a = variants[("32", "Blue")]
    await _svc(db, boutique_shop, boutique_owner).apply(_receive(a.id, "10", "800.00"))
    cashier = _svc(db, boutique_shop, boutique_cashier)

    # Declared discount below the tag → floor is the selling price → PIN.
    res = await cashier.apply(_sale([(a, "1", "1100.00", "1200.00")]))
    assert res.code == "below_price_floor"
    # No list_price: a stale cached price is not a haggle; accepted as-is.
    res = await cashier.apply(_sale([(a, "1", "1100.00")]))
    assert res.status == SyncResultStatus.APPLIED
    # list_price equal to unit_price is not a discount either.
    res = await cashier.apply(_sale([(a, "1", "1100.00", "1100.00")]))
    assert res.status == SyncResultStatus.APPLIED


async def test_floor_not_applied_for_regular_shop(db, shop, cashier, product):
    product.min_selling_price = Decimal("95.00")
    await db.flush()
    res = await _svc(db, shop, cashier).apply(_sale([(product, "1", "50.00", "100.00")]))
    assert res.status == SyncResultStatus.APPLIED
    item = (await db.execute(select(SaleItem))).scalar_one()
    assert item.list_price == Decimal("100.00")   # stored regardless of shop type


# ------------------------------------------------------------- REST --------


async def test_dashboard_low_stock_counts_broken_runs(client, db, boutique_shop, boutique_owner):
    full, fv = await _create_style(db, boutique_shop, boutique_owner, name="Full run", prefix="FR")
    broken, bv = await _create_style(db, boutique_shop, boutique_owner, name="Broken run", prefix="BR")
    svc = _svc(db, boutique_shop, boutique_owner)
    for v in fv.values():
        await svc.apply(_receive(v.id, "3", "10.00"))
    for (size, _), v in bv.items():
        if size != "34":
            await svc.apply(_receive(v.id, "3", "10.00"))

    client.as_user(boutique_owner)
    r = await client.get("/v1/reports/dashboard")
    assert r.status_code == 200
    low = r.json()["low_stock"]
    assert len(low) == 1
    assert low[0]["id"] == broken["id"]
    assert low[0]["name"] == "Broken run"
    assert low[0]["sizes_out"] == 1


async def test_styles_endpoint_masks_cost_for_cashier(client, db, boutique_shop, boutique_owner, boutique_cashier):
    payload, variants = await _create_style(db, boutique_shop, boutique_owner)
    await _svc(db, boutique_shop, boutique_owner).apply(_receive(variants[("32", "Blue")].id, "4", "800.00"))

    client.as_user(boutique_owner)
    r = await client.get("/v1/styles")
    assert r.status_code == 200
    body = r.json()
    assert body["has_more"] is False
    [item] = body["items"]
    assert item["id"] == payload["id"]
    assert item["default_purchase_price"] == "800.00"
    assert item["variant_count"] == 3
    assert Decimal(item["stock_total"]) == Decimal("4")
    assert item["sizes_out"] == 2

    client.as_user(boutique_cashier)
    r = await client.get("/v1/styles")
    [item] = r.json()["items"]
    assert item["default_purchase_price"] == "0"
    assert item["default_selling_price"] == "1200.00"

    r = await client.get(f"/v1/styles/{payload['id']}")
    assert r.status_code == 200
    detail = r.json()
    assert detail["default_purchase_price"] == "0"
    assert len(detail["variants"]) == 3
    assert {v["purchase_price"] for v in detail["variants"]} == {"0"}
    assert {v["sku"] for v in detail["variants"]} == {"JN-32-BLU", "JN-34-BLU", "JN-32-BLA"}

    # Filters + pagination.
    r = await client.get("/v1/styles", params={"segment": "women"})
    assert r.json()["items"] == []
    r = await client.get("/v1/styles", params={"q": "levi"})
    assert len(r.json()["items"]) == 1


async def test_products_query_matches_sku_and_barcode_exactly(client, db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    client.as_user(boutique_owner)
    r = await client.get("/v1/products", params={"q": "JN-32-BLU"})
    items = r.json()["items"]
    assert [i["sku"] for i in items] == ["JN-32-BLU"]
    assert items[0]["style_id"] is not None
    assert items[0]["size"] == "32"
    assert items[0]["color"] == "Blue"
    assert items[0]["min_selling_price"] is None
    r = await client.get("/v1/products", params={"q": "jeans"})
    assert len(r.json()["items"]) == 3


async def test_sale_detail_shape_and_isolation(client, db, boutique_shop, boutique_owner, boutique_cashier, shop, owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    sale_ev = _sale([(a, "2", "1100.00", "1200.00")])
    await svc.apply(sale_ev)
    ret = _return(sale_ev, [(0, "1", "damaged")], refund="1100.00", method="cash", reason="defect")
    assert (await svc.apply(ret)).status == SyncResultStatus.APPLIED
    sale_id = sale_ev.payload["id"]

    client.as_user(boutique_owner)
    r = await client.get(f"/v1/sales/{sale_id}")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "partially_returned"
    assert body["total"] == "2200.00"
    assert "profit" in body
    [item] = body["items"]
    assert item["list_price"] == "1200.00"
    assert item["unit_price"] == "1100.00"
    assert item["returned_quantity"] == "1.000"
    [r_out] = body["returns"]
    assert r_out["id"] == ret.payload["id"]
    assert r_out["refund_amount"] == "1100.00"
    assert r_out["refund_method"] == "cash"
    assert r_out["reason"] == "defect"
    assert r_out["items"] == [{
        "id": ret.payload["items"][0]["id"],
        "sale_item_id": sale_ev.payload["items"][0]["id"],
        "quantity": "1.000", "condition": "damaged", "unit_price": "1100.00",
    }]

    client.as_user(boutique_cashier)
    r = await client.get(f"/v1/sales/{sale_id}")
    assert r.status_code == 200
    assert "profit" not in r.json()
    r = await client.get(f"/v1/sales/{sale_id}/returns")
    assert len(r.json()["items"]) == 1

    # Another shop's owner cannot see it at all.
    client.as_user(owner)
    assert (await client.get(f"/v1/sales/{sale_id}")).status_code == 404
    assert (await client.get(f"/v1/sales/{sale_id}/returns")).status_code == 404


async def test_styles_isolated_between_shops(client, db, boutique_shop, boutique_owner, shop, owner):
    payload, _ = await _create_style(db, boutique_shop, boutique_owner)
    client.as_user(owner)
    r = await client.get("/v1/styles")
    assert r.json()["items"] == []
    assert (await client.get(f"/v1/styles/{payload['id']}")).status_code == 404
    # And the other shop cannot mutate it either.
    res = await _svc(db, shop, owner).apply(_ev("style.update", {
        "id": payload["id"], "client_updated_at": _now(), "name": "Hijacked",
    }))
    assert res.code == "not_found"
    assert (await db.get(Style, payload["id"])).name == "Slim jeans"


async def test_shop_settings_return_window(client, db, boutique_shop, boutique_owner):
    from app.api.v1.auth import _issue_token_bundle

    client.as_user(boutique_owner)
    r = await client.get("/v1/shops/settings")
    assert r.json()["return_window_days"] == 7
    r = await client.patch("/v1/shops/settings", json={"return_window_days": 14})
    assert r.status_code == 200
    assert r.json()["return_window_days"] == 14
    assert (await client.patch("/v1/shops/settings", json={"return_window_days": 91})).status_code == 422
    bundle = await _issue_token_bundle(db, boutique_owner, "fp-b", "Phone", shop=boutique_shop)
    assert bundle.return_window_days == 14
    assert bundle.shop_type == "boutique"


async def test_returns_and_price_leakage_reports(client, db, boutique_shop, boutique_owner, boutique_cashier):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    # Two haggled lines (200 off × 3, 100 off × 1) and one at list. Two of the
    # three haggled units come back, leaving that sale partially returned —
    # a fully returned (refunded) sale would rightly drop out of leakage.
    haggled = _sale([(a, "3", "1000.00", "1200.00")])
    await svc.apply(haggled)
    await svc.apply(_sale([(a, "1", "1100.00", "1200.00")]))
    await svc.apply(_sale([(a, "1", "1200.00", "1200.00")]))
    await svc.apply(_return(haggled, [(0, "1", "damaged")], refund="1000.00", method="cash", reason="defect"))
    await svc.apply(_return(haggled, [(0, "1", "resellable")], refund="500.00", method="mobile_money",
                            reason="changed_mind"))
    assert (await db.get(Sale, haggled.payload["id"])).status == "partially_returned"

    client.as_user(boutique_owner)
    r = await client.get("/v1/reports/returns")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] == 2
    assert body["refund_total"] == "1500.00"
    assert body["damaged_value"] == "800.00"       # 1 × unit cost
    assert body["by_reason"] == {"defect": 1, "changed_mind": 1}
    assert body["by_user"] == [{"user_id": str(boutique_owner.id), "count": 2, "refund_total": "1500.00"}]

    r = await client.get("/v1/reports/price-leakage")
    assert r.status_code == 200
    body = r.json()
    assert body["leakage_total"] == "700.00"       # 3×200 + 1×100
    assert body["lines"] == 2
    assert body["by_user"] == [{"user_id": str(boutique_owner.id), "lines": 2, "leakage": "700.00"}]
    assert body["by_style"][0]["name"] == "Slim jeans"
    assert body["by_style"][0]["leakage"] == "700.00"

    client.as_user(boutique_cashier)
    assert (await client.get("/v1/reports/returns")).status_code == 403
    assert (await client.get("/v1/reports/price-leakage")).status_code == 403


async def test_csv_export_and_import_create_styles(client, db, boutique_shop, boutique_owner):
    client.as_user(boutique_owner)
    csv_text = (
        "name,category,selling_price,purchase_price,stock,low_stock_threshold,unit,barcode,"
        "style,brand,segment,size,color,sku,min_selling_price\n"
        ",Shirts,900,500,3,1,,,Oxford shirt,Turkish,men,M,White,OX-M-WHI,750\n"
        ",Shirts,900,500,0,1,,,Oxford shirt,Turkish,men,L,White,OX-L-WHI,750\n"
        ",Shirts,950,500,2,1,,,Oxford shirt,Other brand,men,XL,White,,\n"
        "Plain soap,Household,20,12,10,2,piece,,,,,,,,\n"
    )
    files = {"file": ("products.csv", csv_text.encode("utf-8"), "text/csv")}

    r = await client.post("/v1/export/products/import", params={"dry_run": "false"}, files=files)
    assert r.status_code == 200, r.text
    assert r.json() == {"created": 4, "updated": 0, "skipped": 0, "errors": [],
                        "committed": True, "styles_created": 2}

    styles = {(s.name, s.brand): s for s in (await db.execute(select(Style))).scalars().all()}
    assert set(styles) == {("Oxford shirt", "Turkish"), ("Oxford shirt", "Other brand")}
    turkish = styles[("Oxford shirt", "Turkish")]
    assert turkish.segment == "men"
    assert turkish.default_selling_price == Decimal("900")

    products = {p.name: p for p in (await db.execute(select(Product))).scalars().all()}
    assert set(products) == {
        "Oxford shirt · M · White", "Oxford shirt · L · White",
        "Oxford shirt · XL · White", "Plain soap",
    }
    m_white = products["Oxford shirt · M · White"]
    assert m_white.style_id == turkish.id
    assert m_white.sku == "OX-M-WHI"
    assert m_white.min_selling_price == Decimal("750")
    assert m_white.size == "M" and m_white.color == "White"
    assert m_white.stock == Decimal("3")
    assert m_white.unit == "piece"
    # The other brand's row is a separate style; its variant name would
    # collide only if it shared a size, which is the duplicate-name rule.
    assert products["Oxford shirt · XL · White"].style_id == styles[("Oxford shirt", "Other brand")].id
    assert products["Oxford shirt · XL · White"].sku is None
    assert products["Plain soap"].style_id is None

    r = await client.get("/v1/export/products.csv")
    assert r.status_code == 200
    header = r.text.lstrip("﻿").splitlines()[0]
    assert header.endswith("style,brand,segment,size,color,sku,min_selling_price")
    assert "Oxford shirt · L · White,Shirts,900.00,500.00" in r.text

    # Round trip: the same file again is all updates (matched by SKU or by the
    # composed name), no new styles; and a dry run writes nothing. The dry run
    # comes last because its rollback also discards this test's uncommitted
    # fixtures — in production each request has its own session.
    r = await client.post("/v1/export/products/import", files=files)
    assert r.status_code == 200, r.text
    assert r.json() == {"created": 0, "updated": 4, "skipped": 0, "errors": [],
                        "committed": False, "styles_created": 0}
    assert await _count(db, Style) == 2
    assert await _count(db, Product) == 4


async def test_csv_import_rejects_bad_segment(client, db, boutique_shop, boutique_owner):
    client.as_user(boutique_owner)
    csv_text = "style,size,color,selling_price,segment\nCap,,Red,100,teen\n"
    r = await client.post("/v1/export/products/import", params={"dry_run": "false"},
                          files={"file": ("p.csv", csv_text.encode(), "text/csv")})
    assert r.status_code == 200
    body = r.json()
    assert body["committed"] is False
    assert "segment" in body["errors"][0]["message"]
    assert await _count(db, Style) == 0


# ------------------------------------------------- review fixes (round 2) ---


async def test_two_return_lines_for_one_item_restore_each_lot_once(db, boutique_shop, boutique_owner):
    """1 resellable + 1 damaged of the same line: lot A and lot B are each
    restored exactly once, and the damaged spoilage draws from the lot the
    second line actually restored (B), not from A again."""
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    older = _receive(a.id, "1", "700.00")
    older.payload["occurred_at"] = (datetime.now(UTC) - timedelta(days=1)).isoformat()
    assert (await svc.apply(older)).status == SyncResultStatus.APPLIED
    assert (await svc.apply(_receive(a.id, "1", "800.00"))).status == SyncResultStatus.APPLIED
    sale_ev = _sale([(a, "2", "1200.00")])
    assert (await svc.apply(sale_ev)).status == SyncResultStatus.APPLIED

    res = await svc.apply(_return(
        sale_ev, [(0, "1", "resellable"), (0, "1", "damaged")], refund="2400.00", method="cash",
    ))
    assert res.status == SyncResultStatus.APPLIED, res

    lots = (await db.execute(select(StockLot).order_by(StockLot.received_at))).scalars().all()
    lot_a, lot_b = lots
    await db.refresh(lot_a)
    await db.refresh(lot_b)
    assert lot_a.unit_cost == Decimal("700.00")
    assert lot_a.qty_remaining == Decimal("1")      # restored by the resellable line
    assert lot_b.qty_remaining == Decimal("0")      # restored, then spoiled as damaged

    reversals = (await db.execute(
        select(LotConsumption).where(LotConsumption.movement == "refund_reversal")
    )).scalars().all()
    assert sorted((c.lot_id, c.quantity) for c in reversals) == sorted(
        [(lot_a.id, Decimal("-1")), (lot_b.id, Decimal("-1"))]
    )
    spoil = (await db.execute(
        select(LotConsumption).where(LotConsumption.movement == "spoilage")
    )).scalar_one()
    assert spoil.lot_id == lot_b.id
    assert spoil.unit_cost == Decimal("800.00")
    assert (await _fresh(db, a)).stock == Decimal("1")
    assert (await db.get(Sale, sale_ev.payload["id"])).status == "refunded"


async def test_revenue_reports_net_out_returns(client, db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    sale_ev = _sale([(a, "2", "1200.00")])
    assert (await svc.apply(sale_ev)).status == SyncResultStatus.APPLIED
    assert (await svc.apply(_return(
        sale_ev, [(0, "1", "resellable")], refund="1200.00", method="cash",
    ))).status == SyncResultStatus.APPLIED

    client.as_user(boutique_owner)
    body = (await client.get("/v1/reports/dashboard")).json()
    assert body["billed_revenue"] == "1200.00"        # 2400 - 1200 refunded
    assert body["gross_profit"] == "400.00"           # (2400 - 1600) - 1200 + 800 cost back
    assert body["refund_total"] == "1200.00"
    assert Decimal(body["spoilage_cost"]) == 0

    body = (await client.get("/v1/reports/payment-mix", params={"range": "today"})).json()
    assert body["methods"] == [{"method": "cash", "total": "1200.00", "count": 1}]

    body = (await client.get("/v1/reports/cashier-performance")).json()
    [row] = body["cashiers"]
    assert row["revenue"] == "1200.00"
    assert row["gross_profit"] == "400.00"
    assert row["refund_count"] == 1
    assert row["refund_total"] == "1200.00"

    body = (await client.get("/v1/reports/sales-series")).json()
    [today] = body["series"]
    assert Decimal(today["revenue"]) == Decimal("1200.00")
    assert Decimal(today["profit"]) == Decimal("400.00")

    body = (await client.get("/v1/reports/top-products")).json()
    [item] = body["items"]
    assert Decimal(item["qty_sold"]) == Decimal("1")
    assert Decimal(item["revenue"]) == Decimal("1200")
    assert Decimal(item["profit"]) == Decimal("400")


async def test_revenue_reports_damaged_return_is_a_loss_once(client, db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    sale_ev = _sale([(a, "1", "1200.00")])
    await svc.apply(sale_ev)
    await svc.apply(_return(sale_ev, [(0, "1", "damaged")], refund="1200.00", method="cash",
                            reason="defect"))
    client.as_user(boutique_owner)
    body = (await client.get("/v1/reports/dashboard")).json()
    assert body["billed_revenue"] == "0.00"
    assert body["gross_profit"] == "-800.00"          # the unit's cost, lost
    assert Decimal(body["spoilage_cost"]) == 0        # not counted a second time
    assert Decimal(body["net_profit"]) == Decimal("-800.00")


async def test_revenue_reports_count_exchange_correctly(client, db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a, b = variants[("32", "Blue")], variants[("34", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    await svc.apply(_receive(b.id, "10", "800.00"))
    original = _sale([(a, "1", "1200.00")])
    assert (await svc.apply(original)).status == SyncResultStatus.APPLIED
    replacement = _sale([(b, "1", "1500.00")], discount="1200.00")
    assert (await svc.apply(replacement)).status == SyncResultStatus.APPLIED
    assert (await svc.apply(_return(
        original, [(0, "1", "resellable")], refund="0", exchange=replacement.payload["id"],
    ))).status == SyncResultStatus.APPLIED

    client.as_user(boutique_owner)
    body = (await client.get("/v1/reports/dashboard")).json()
    assert body["billed_revenue"] == "1500.00"        # 1200 paid + 300 paid, nothing handed back
    # 1500 revenue - 800 cost of the one item the customer kept: the returned
    # item's cost went back to stock. (400 - 500 + 800.)
    assert body["gross_profit"] == "700.00"
    assert Decimal(body["refund_total"]) == 0


async def test_exports_are_owner_only(client, db, boutique_shop, boutique_cashier, boutique_owner):
    client.as_user(boutique_cashier)
    assert (await client.get("/v1/export/products.csv")).status_code == 403
    assert (await client.get("/v1/export/sales.csv")).status_code == 403
    files = {"file": ("p.csv", b"name,selling_price\nX,10\n", "text/csv")}
    r = await client.post("/v1/export/products/import", params={"dry_run": "false"}, files=files)
    assert r.status_code == 403
    assert await _count(db, Product) == 0

    client.as_user(boutique_owner)
    assert (await client.get("/v1/export/products.csv")).status_code == 200


async def test_variant_uniqueness_treats_null_colour_as_a_value(db, boutique_shop, boutique_owner):
    payload, _ = await _create_style(db, boutique_shop, boutique_owner, variants=[_variant("M", None)])
    svc = _svc(db, boutique_shop, boutique_owner)
    twin = {
        "id": str(uuid4()), "name": "ignored", "selling_price": "10", "style_id": payload["id"],
        "size": "M", "color": "",
    }
    res = await svc.apply(_ev("product.create", twin))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "variant_exists"

    # product.update moving another variant onto the taken slot is refused too.
    res = await svc.apply(_ev("style.add_variants", {
        "style_id": payload["id"], "client_updated_at": _now(), "variants": [_variant("L", None)],
    }))
    assert res.status == SyncResultStatus.APPLIED
    large = (await db.execute(select(Product).where(Product.size == "L"))).scalar_one()
    res = await svc.apply(_ev("product.update", {
        "id": str(large.id), "client_updated_at": (datetime.now(UTC) + timedelta(seconds=5)).isoformat(),
        "size": "M",
    }))
    assert res.code == "variant_exists"
    await db.refresh(large)
    assert large.size == "L"


async def test_variant_unique_index_coalesces_nulls(db, boutique_shop, boutique_owner):
    """The DB itself refuses two live (style, M, NULL) rows — the model
    mirror of products_variant_uq must coalesce, not just the handler."""
    from sqlalchemy.exc import IntegrityError

    payload, _ = await _create_style(db, boutique_shop, boutique_owner, variants=[_variant("M", None)])
    db.add(Product(
        id=uuid4(), shop_id=boutique_shop.id, style_id=payload["id"], name="twin", size="M",
        color=None, purchase_price=Decimal("0"), selling_price=Decimal("1"),
        stock=Decimal("0"), low_stock_threshold=Decimal("0"), unit="piece",
    ))
    with pytest.raises(IntegrityError) as e:
        await db.flush()
    assert "products_variant_uq" in str(e.value.orig)


async def test_sale_create_ignores_client_status(db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    for claimed in ("refunded", "partially_returned", "voided"):
        ev = _sale([(a, "1", "1200.00")], status=claimed)
        assert (await svc.apply(ev)).status == SyncResultStatus.APPLIED
        assert (await db.get(Sale, ev.payload["id"])).status == "completed"


async def test_hardening_validation(db, boutique_shop, boutique_owner, shop, owner, product):
    svc = _svc(db, boutique_shop, boutique_owner)
    # sku_prefix longer than the column → invalid_payload, not a DataError.
    res = await svc.apply(_ev(
        "style.create", _style_payload(prefix="TOOLONGPREFIX", variants=[_variant("M", None)]),
    ))
    assert res.code == "invalid_payload"
    payload, variants = await _create_style(db, boutique_shop, boutique_owner)
    res = await svc.apply(_ev("style.update", {
        "id": payload["id"],
        "client_updated_at": (datetime.now(UTC) + timedelta(seconds=5)).isoformat(),
        "sku_prefix": "ABCDEFGHI",
    }))
    assert res.code == "invalid_payload"
    assert (await db.get(Style, payload["id"])).sku_prefix == "JN"

    # reason is required on a return.
    a = variants[("32", "Blue")]
    await svc.apply(_receive(a.id, "10", "800.00"))
    sale_ev = _sale([(a, "1", "1200.00")])
    await svc.apply(sale_ev)
    for reason in (None, "because"):
        res = await svc.apply(_return(sale_ev, [(0, "1", "resellable")], reason=reason))
        assert res.code == "invalid_payload", reason
    assert await _count(db, SaleReturn) == 0

    # A legacy full refund on another shop's sale is invisible.
    res = await _svc(db, shop, owner).apply(_ev("sale.refund", {
        "sale_id": sale_ev.payload["id"], "occurred_at": _now(),
    }))
    assert res.code == "not_found"
    assert (await db.get(Sale, sale_ev.payload["id"])).status == "completed"


async def test_style_prefix_rewrite_refuses_sku_collision(db, boutique_shop, boutique_owner):
    jeans, _ = await _create_style(db, boutique_shop, boutique_owner, name="Jeans", prefix="JN")
    denim, dv = await _create_style(db, boutique_shop, boutique_owner, name="Denim", prefix="DN")
    svc = _svc(db, boutique_shop, boutique_owner)
    res = await svc.apply(_ev("style.update", {
        "id": denim["id"],
        "client_updated_at": (datetime.now(UTC) + timedelta(seconds=5)).isoformat(),
        "sku_prefix": "JN",
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "sku_collision"
    # Nothing written: prefix and SKUs untouched.
    assert (await db.get(Style, denim["id"])).sku_prefix == "DN"
    v = dv[("32", "Blue")]
    await db.refresh(v)
    assert v.sku == "DN-32-BLU"
    # A prefix nobody uses goes through.
    res = await svc.apply(_ev("style.update", {
        "id": denim["id"],
        "client_updated_at": (datetime.now(UTC) + timedelta(seconds=6)).isoformat(),
        "sku_prefix": "DM",
    }))
    assert res.status == SyncResultStatus.APPLIED
    await db.refresh(v)
    assert v.sku == "DM-32-BLU"


async def test_returning_an_exchanged_item_credits_its_full_price(db, boutique_shop, boutique_owner):
    """The exchange credit rides in the replacement sale's discount; that
    discount is money the customer really paid, so a later return of the
    replacement must credit the line price, not total/subtotal of it."""
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a, b = variants[("32", "Blue")], variants[("34", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    await svc.apply(_receive(b.id, "10", "800.00"))
    original = _sale([(a, "1", "1500.00")])
    assert (await svc.apply(original)).status == SyncResultStatus.APPLIED
    replacement = _sale([(b, "1", "1500.00")], discount="1500.00")   # even exchange: pays 0
    assert (await svc.apply(replacement)).status == SyncResultStatus.APPLIED
    assert (await db.get(Sale, replacement.payload["id"])).total == Decimal("0")
    assert (await svc.apply(_return(
        original, [(0, "1", "resellable")], refund="0", exchange=replacement.payload["id"],
    ))).status == SyncResultStatus.APPLIED

    # Now the customer brings the replacement back for cash.
    res = await svc.apply(_return(
        replacement, [(0, "1", "resellable")], refund="1500.00", method="cash",
        reason="changed_mind",
    ))
    assert res.status == SyncResultStatus.APPLIED, res
    item = (await db.execute(
        select(SaleReturnItem)
        .join(SaleReturn, SaleReturn.id == SaleReturnItem.return_id)
        .where(SaleReturn.sale_id == replacement.payload["id"])
    )).scalar_one()
    assert item.unit_price == Decimal("1500.00")
    assert (await db.get(Sale, replacement.payload["id"])).status == "refunded"


# ------------------------------------------------- review fixes (round 3) ---


async def test_product_sku_collision_is_terminal_not_conflict(db, boutique_shop, boutique_owner):
    """A duplicate SKU must come back as `sku_collision` (a rejection the
    client can act on), never as an integrity CONFLICT it retries forever."""
    payload, variants = await _create_style(db, boutique_shop, boutique_owner)   # owns JN-32-BLU
    svc = _svc(db, boutique_shop, boutique_owner)

    # product.create with a taken SKU.
    res = await svc.apply(_ev("product.create", {
        "id": str(uuid4()), "name": "Loose thing", "selling_price": "10", "sku": "JN-32-BLU",
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "sku_collision"
    assert await _count(db, Product) == 3

    # product.update moving onto a taken SKU; keeping its own is fine.
    black = variants[("32", "Black")]
    later = (datetime.now(UTC) + timedelta(seconds=5)).isoformat()
    res = await svc.apply(_ev("product.update", {
        "id": str(black.id), "client_updated_at": later, "sku": "JN-32-BLU",
    }))
    assert res.code == "sku_collision"
    await db.refresh(black)
    assert black.sku == "JN-32-BLA"
    res = await svc.apply(_ev("product.update", {
        "id": str(black.id), "client_updated_at": later, "sku": "JN-32-BLA", "barcode": "123",
    }))
    assert res.status == SyncResultStatus.APPLIED

    # style.add_variants and style.create reuse the same check.
    res = await svc.apply(_ev("style.add_variants", {
        "style_id": payload["id"], "client_updated_at": _now(),
        "variants": [_variant("36", "Blue", sku="JN-32-BLU")],
    }))
    assert res.code == "sku_collision"
    res = await svc.apply(_ev("style.create", _style_payload(
        name="Other", prefix="OT", variants=[_variant("M", None, sku="JN-32-BLU")],
    )))
    assert res.code == "sku_collision"
    res = await svc.apply(_ev("style.create", _style_payload(
        name="Other", prefix="OT",
        variants=[_variant("M", None, sku="OT-M"), _variant("L", None, sku="OT-M")],
    )))
    assert res.code == "invalid_payload"
    assert await _count(db, Style) == 1

    # A soft-deleted product frees its SKU.
    res = await svc.apply(_ev("product.delete", {"id": str(black.id)}))
    assert res.status == SyncResultStatus.APPLIED
    res = await svc.apply(_ev("product.create", {
        "id": str(uuid4()), "name": "Reuses sku", "selling_price": "10", "sku": "JN-32-BLA",
    }))
    assert res.status == SyncResultStatus.APPLIED


async def test_csv_import_reports_sku_collisions_as_row_errors(client, db, boutique_shop, boutique_owner):
    await _create_style(db, boutique_shop, boutique_owner)   # owns JN-32-BLU etc.
    client.as_user(boutique_owner)
    csv_text = (
        "name,selling_price,sku\n"
        "Belt,100,JN-32-BLU\n"          # belongs to a variant already
        "Hat,50,HAT-1\n"
        "Cap,60,HAT-1\n"                # twice in the file
    )
    r = await client.post("/v1/export/products/import", params={"dry_run": "false"},
                          files={"file": ("p.csv", csv_text.encode(), "text/csv")})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["committed"] is False
    assert [e["row"] for e in body["errors"]] == [2, 4]
    assert "already belongs to" in body["errors"][0]["message"]
    assert "appears twice" in body["errors"][1]["message"]


# ------------------------------------------------- review fixes (round 4) ---


async def test_partial_return_restores_lots_in_draw_order(db, boutique_shop, boutique_owner):
    """A line drawing from two lots must be reversed in the order it drew.

    Both lots are received in the same instant, so `received_at` cannot break
    the tie and only the expiry date orders them (FEFO). Ordering the
    reversal by (consumed_at, id) instead — the consumptions share a
    consumed_at and carry random UUIDs — left this arbitrary, so a partial
    return could credit the unit back to a batch it never came from.
    """
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)

    received = datetime.now(UTC) - timedelta(days=1)
    soon = (received + timedelta(days=2)).date().isoformat()     # drawn first
    later = (received + timedelta(days=30)).date().isoformat()   # drawn second
    for expiry, cost in ((soon, "700.00"), (later, "800.00")):
        ev = _receive(a.id, "1", cost)
        ev.payload["occurred_at"] = received.isoformat()
        ev.payload["expiry_date"] = expiry
        assert (await svc.apply(ev)).status == SyncResultStatus.APPLIED

    lots = {
        lot.expiry_date.isoformat(): lot
        for lot in (await db.execute(select(StockLot))).scalars().all()
    }
    lot_soon, lot_later = lots[soon], lots[later]
    assert lot_soon.received_at == lot_later.received_at   # only expiry orders them

    sale_ev = _sale([(a, "2", "1200.00")])
    assert (await svc.apply(sale_ev)).status == SyncResultStatus.APPLIED
    item = (await db.execute(select(SaleItem))).scalar_one()
    assert item.unit_cost == Decimal("750.00")             # (700 + 800) / 2
    for lot in (lot_soon, lot_later):
        await db.refresh(lot)
        assert lot.qty_remaining == Decimal("0")

    # First unit back goes to the lot the sale drew from first.
    first = _return(sale_ev, [(0, "1", "resellable")], refund="1200.00", method="cash")
    assert (await svc.apply(first)).status == SyncResultStatus.APPLIED
    await db.refresh(lot_soon)
    await db.refresh(lot_later)
    assert lot_soon.qty_remaining == Decimal("1")
    assert lot_later.qty_remaining == Decimal("0")
    reversal = (await db.execute(
        select(LotConsumption).where(LotConsumption.movement == "refund_reversal")
    )).scalar_one()
    assert reversal.lot_id == lot_soon.id
    assert reversal.unit_cost == Decimal("700.00")

    # The second restores the other lot, not the one already credited.
    second = _return(sale_ev, [(0, "1", "resellable")], refund="1200.00", method="cash")
    assert (await svc.apply(second)).status == SyncResultStatus.APPLIED
    await db.refresh(lot_soon)
    await db.refresh(lot_later)
    assert lot_soon.qty_remaining == Decimal("1")
    assert lot_later.qty_remaining == Decimal("1")
    reversals = (await db.execute(
        select(LotConsumption).where(LotConsumption.movement == "refund_reversal")
    )).scalars().all()
    assert sorted((c.lot_id, c.unit_cost) for c in reversals) == sorted(
        [(lot_soon.id, Decimal("700.00")), (lot_later.id, Decimal("800.00"))]
    )
    assert (await _fresh(db, a)).stock == Decimal("2")
    assert (await db.get(Sale, sale_ev.payload["id"])).status == "refunded"


# ------------------------------------------------- review fixes (round 5) ---


async def test_return_item_ids_are_exposed_and_stable(client, db, boutique_shop, boutique_owner):
    """Every nested row carries its own id, identically on repeat fetches.

    A client caching a remotely-fetched sale keys on these ids; without one
    for a return line it mints a random UUID per fetch, so two overlapping
    fetches of the same uncached sale double the return lines — doubling
    already-returned quantities and the exchange credit.
    """
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    a, b = variants[("32", "Blue")], variants[("34", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive(a.id, "10", "800.00"))
    await svc.apply(_receive(b.id, "10", "800.00"))
    sale_ev = _sale([(a, "2", "1200.00"), (b, "1", "1200.00")])
    assert (await svc.apply(sale_ev)).status == SyncResultStatus.APPLIED
    # Two returns, the first with two lines, so every nested list has >1 row.
    first = _return(
        sale_ev, [(0, "1", "resellable"), (1, "1", "damaged")],
        refund="2400.00", method="cash",
    )
    assert (await svc.apply(first)).status == SyncResultStatus.APPLIED
    second = _return(sale_ev, [(0, "1", "resellable")], refund="1200.00", method="cash")
    assert (await svc.apply(second)).status == SyncResultStatus.APPLIED

    client.as_user(boutique_owner)
    sale_id = sale_ev.payload["id"]
    detail = (await client.get(f"/v1/sales/{sale_id}")).json()
    listed = (await client.get(f"/v1/sales/{sale_id}/returns")).json()["items"]

    # Ids the client sent are the ids it reads back, on both endpoints.
    expected = {
        ev.payload["id"]: sorted(i["id"] for i in ev.payload["items"])
        for ev in (first, second)
    }
    for payload in (detail["returns"], listed):
        assert [r["id"] for r in payload] == [first.payload["id"], second.payload["id"]]
        for r in payload:
            assert sorted(i["id"] for i in r["items"]) == expected[r["id"]]
            assert all(i["sale_item_id"] for i in r["items"])

    # Every nested row in the endpoint exposes an id — the property the
    # client's dedupe depends on, asserted structurally rather than per field.
    assert all("id" in i for i in detail["items"])
    assert all("id" in r and all("id" in i for i in r["items"]) for r in detail["returns"])

    # A second fetch is identical, so caching it twice cannot duplicate rows.
    again = (await client.get(f"/v1/sales/{sale_id}")).json()
    assert again == detail
    assert (await client.get(f"/v1/sales/{sale_id}/returns")).json()["items"] == listed
