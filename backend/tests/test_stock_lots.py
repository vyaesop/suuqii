"""Batch/lot engine: FEFO consumption, spoilage, expiry, refund reversal.

Pins the docs/16 behavior, including the user's canonical scenario:
10 sodas bought at 10 birr sold at 15, then 10 more at 13 sold at 16 —
per-batch margins must stay separable.
"""
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import uuid4

from sqlalchemy import select

from app.models import (
    AuditLog,
    LotConsumption,
    Product,
    Sale,
    SaleItem,
    StockLot,
    Supply,
)
from app.schemas.sync import SyncEventIn, SyncResultStatus
from app.services.sync_service import SyncService


def _svc(db, shop, user):
    return SyncService(db, shop_id=shop.id, user=user, device_id="dev-1")


def _ev(op, payload):
    return SyncEventIn(
        client_event_id=uuid4(), op=op,
        occurred_at=datetime.now(UTC), payload=payload,
    )


def _receive(product, qty, cost, *, expiry=None, spoiled=None, occurred=None):
    p = {
        "id": str(uuid4()),
        "product_id": str(product.id),
        "quantity": qty,
        "unit_cost": cost,
        "occurred_at": (occurred or datetime.now(UTC)).isoformat(),
    }
    if expiry:
        p["expiry_date"] = expiry
    if spoiled:
        p["spoiled_quantity"] = spoiled
    return _ev("stock.receive", p)


def _sale(product, qty, price, cost="0"):
    return _ev("sale.create", {
        "id": str(uuid4()),
        "items": [{
            "id": str(uuid4()),
            "product_id": str(product.id),
            "product_name_snapshot": product.name,
            "quantity": qty,
            "unit_price": price,
            "unit_cost": cost,
        }],
        "payment_method": "cash",
        "occurred_at": datetime.now(UTC).isoformat(),
    })


async def test_receive_creates_lot_and_updates_stock_and_last_cost(db, shop, owner, product):
    svc = _svc(db, shop, owner)
    res = await svc.apply(_receive(product, "10", "10.00"))
    assert res.status == SyncResultStatus.APPLIED

    lot = (await db.execute(select(StockLot))).scalar_one()
    assert lot.qty_received == Decimal("10")
    assert lot.qty_remaining == Decimal("10")
    assert lot.unit_cost == Decimal("10.00")

    prod = await db.get(Product, product.id)
    await db.refresh(prod)
    assert prod.stock == Decimal("60")           # fixture 50 + 10
    assert prod.purchase_price == Decimal("10.00")  # last cost


async def test_receive_with_spoilage_nets_out(db, shop, owner, product):
    svc = _svc(db, shop, owner)
    res = await svc.apply(_receive(product, "10", "8.00", spoiled="2"))
    assert res.status == SyncResultStatus.APPLIED

    lot = (await db.execute(select(StockLot))).scalar_one()
    assert lot.qty_remaining == Decimal("8")
    spoil = (await db.execute(
        select(LotConsumption).where(LotConsumption.movement == "spoilage")
    )).scalar_one()
    assert spoil.quantity == Decimal("2")
    assert spoil.unit_cost == Decimal("8.00")

    prod = await db.get(Product, product.id)
    await db.refresh(prod)
    assert prod.stock == Decimal("58")           # 50 + 10 − 2


async def test_two_soda_batches_keep_separate_margins(db, shop, owner):
    """The canonical scenario: batch A 10 @ cost 10 sold @15; batch B
    10 @ cost 13 sold @16. FIFO consumption; margins separable per lot."""
    soda = Product(
        id=uuid4(), shop_id=shop.id, name="Soda",
        purchase_price=Decimal("10.00"), selling_price=Decimal("15.00"),
        stock=Decimal("0"), low_stock_threshold=Decimal("0"), unit="piece",
    )
    db.add(soda)
    await db.flush()

    svc = _svc(db, shop, owner)
    t0 = datetime.now(UTC) - timedelta(days=2)
    assert (await svc.apply(_receive(soda, "10", "10.00", occurred=t0))).status == SyncResultStatus.APPLIED
    assert (await svc.apply(_receive(soda, "10", "13.00"))).status == SyncResultStatus.APPLIED

    # Sell all 10 of batch A at 15 (FIFO: oldest lot first).
    res = await svc.apply(_sale(soda, "10", "15.00"))
    assert res.status == SyncResultStatus.APPLIED
    sale_a = (await db.execute(select(Sale))).scalar_one()
    assert sale_a.cost_total == Decimal("100.00")     # 10 × 10, NOT 13
    item_a = (await db.execute(select(SaleItem))).scalar_one()
    assert item_a.unit_cost == Decimal("10.00")

    # Sell 4 of batch B at 16.
    res = await svc.apply(_sale(soda, "4", "16.00"))
    assert res.status == SyncResultStatus.APPLIED
    items = (await db.execute(
        select(SaleItem).order_by(SaleItem.unit_cost)
    )).scalars().all()
    assert items[-1].unit_cost == Decimal("13.00")

    lots = (await db.execute(
        select(StockLot).order_by(StockLot.received_at)
    )).scalars().all()
    assert lots[0].qty_remaining == Decimal("0")
    assert lots[1].qty_remaining == Decimal("6")

    # Per-lot consumption records make the margin report exact.
    a_cons = (await db.execute(
        select(LotConsumption).where(LotConsumption.lot_id == lots[0].id)
    )).scalars().all()
    assert sum(c.quantity for c in a_cons) == Decimal("10")
    assert all(c.unit_cost == Decimal("10.00") for c in a_cons)


async def test_sale_spanning_two_lots_gets_weighted_cost(db, shop, owner, product):
    svc = _svc(db, shop, owner)
    t0 = datetime.now(UTC) - timedelta(days=1)
    await svc.apply(_receive(product, "10", "10.00", occurred=t0))
    await svc.apply(_receive(product, "10", "13.00"))

    res = await svc.apply(_sale(product, "12", "16.00"))
    assert res.status == SyncResultStatus.APPLIED
    item = (await db.execute(select(SaleItem))).scalar_one()
    # (10×10 + 2×13) / 12 = 10.5
    assert item.unit_cost == Decimal("10.50")


async def test_fefo_expiring_lot_consumed_first(db, shop, owner, product):
    """A lot expiring sooner is consumed before an older no-expiry lot."""
    svc = _svc(db, shop, owner)
    t0 = datetime.now(UTC) - timedelta(days=5)
    await svc.apply(_receive(product, "10", "10.00", occurred=t0))  # older, no expiry
    soon = (datetime.now(UTC) + timedelta(days=2)).date().isoformat()
    await svc.apply(_receive(product, "10", "12.00", expiry=soon))  # newer, expires soon

    await svc.apply(_sale(product, "3", "15.00"))
    item = (await db.execute(select(SaleItem))).scalar_one()
    assert item.unit_cost == Decimal("12.00")   # expiring batch first

    lots = (await db.execute(
        select(StockLot).order_by(StockLot.received_at)
    )).scalars().all()
    assert lots[0].qty_remaining == Decimal("10")   # untouched
    assert lots[1].qty_remaining == Decimal("7")


async def test_refund_returns_quantities_to_the_same_lots(db, shop, owner, product):
    svc = _svc(db, shop, owner)
    await svc.apply(_receive(product, "10", "10.00"))
    sale_ev = _sale(product, "4", "15.00")
    await svc.apply(sale_ev)

    lot = (await db.execute(select(StockLot))).scalar_one()
    assert lot.qty_remaining == Decimal("6")

    res = await svc.apply(_ev("sale.refund", {"sale_id": sale_ev.payload["id"],
                                              "occurred_at": datetime.now(UTC).isoformat()}))
    assert res.status == SyncResultStatus.APPLIED
    await db.refresh(lot)
    assert lot.qty_remaining == Decimal("10")

    reversals = (await db.execute(
        select(LotConsumption).where(LotConsumption.movement == "refund_reversal")
    )).scalars().all()
    assert sum(c.quantity for c in reversals) == Decimal("-4")


async def test_stock_spoil_consumes_fefo_and_audits_value(db, shop, owner, product):
    svc = _svc(db, shop, owner)
    await svc.apply(_receive(product, "10", "10.00"))
    res = await svc.apply(_ev("stock.spoil", {
        "product_id": str(product.id),
        "quantity": "3",
        "reason": "expired",
        "occurred_at": datetime.now(UTC).isoformat(),
    }))
    assert res.status == SyncResultStatus.APPLIED

    lot = (await db.execute(select(StockLot))).scalar_one()
    assert lot.qty_remaining == Decimal("7")
    audit = (await db.execute(
        select(AuditLog).where(AuditLog.action == "stock.spoilage")
    )).scalar_one()
    assert audit.new_value["value"] == "30.00"

    prod = await db.get(Product, product.id)
    await db.refresh(prod)
    assert prod.stock == Decimal("57")           # 50 + 10 − 3


async def test_spoil_is_pin_gated_for_cashiers(db, shop, cashier, product):
    svc = _svc(db, shop, cashier)
    res = await svc.apply(_ev("stock.spoil", {
        "product_id": str(product.id), "quantity": "1",
        "occurred_at": datetime.now(UTC).isoformat(),
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "owner_pin_required"


async def test_adjust_creates_and_consumes_lots(db, shop, owner, product):
    svc = _svc(db, shop, owner)
    res = await svc.apply(_ev("inventory.adjust", {
        "product_id": str(product.id), "quantity_delta": "5",
        "occurred_at": datetime.now(UTC).isoformat(),
    }))
    assert res.status == SyncResultStatus.APPLIED
    lot = (await db.execute(select(StockLot))).scalar_one()
    assert lot.qty_remaining == Decimal("5")
    assert lot.unit_cost == product.purchase_price

    res = await svc.apply(_ev("inventory.adjust", {
        "product_id": str(product.id), "quantity_delta": "-2",
        "occurred_at": datetime.now(UTC).isoformat(),
    }))
    assert res.status == SyncResultStatus.APPLIED
    await db.refresh(lot)
    assert lot.qty_remaining == Decimal("3")


async def test_production_record_bakery_spoilage_deducts_supplies(db, owner_bakery):
    db_, shop, owner, bread, flour = owner_bakery
    svc = _svc(db_, shop, owner)
    res = await svc.apply(_ev("production.record", {
        "id": str(uuid4()),
        "product_id": str(bread.id),
        "quantity_produced": "50",
        "quantity_spoiled": "5",
        "occurred_at": datetime.now(UTC).isoformat(),
    }))
    assert res.status == SyncResultStatus.APPLIED

    lot = (await db_.execute(select(StockLot))).scalar_one()
    # recipe: 0.5 kg flour @ 40/kg = 20.00 per bread
    assert lot.unit_cost == Decimal("20.00")
    assert lot.qty_remaining == Decimal("45")

    # Spoiled units consumed ingredients that never reach a sale:
    # 5 breads × 0.5 kg = 2.5 kg deducted.
    fl = await db_.get(Supply, flour.id)
    await db_.refresh(fl)
    assert fl.quantity_on_hand == Decimal("97.5")

    bread_row = await db_.get(Product, bread.id)
    await db_.refresh(bread_row)
    assert bread_row.stock == Decimal("45")


async def test_production_record_rejected_for_regular_shop(db, shop, owner, product):
    svc = _svc(db, shop, owner)
    res = await svc.apply(_ev("production.record", {
        "id": str(uuid4()), "product_id": str(product.id),
        "quantity_produced": "10",
        "occurred_at": datetime.now(UTC).isoformat(),
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "bad_shop_type"


async def test_cashier_cannot_close_others_shift(db, shop, owner, cashier):
    svc_owner = _svc(db, shop, owner)
    shift_id = str(uuid4())
    res = await svc_owner.apply(_ev("shift.open", {
        "id": shift_id,
        "opened_at": datetime.now(UTC).isoformat(),
        "opening_cash": "100.00",
    }))
    assert res.status == SyncResultStatus.APPLIED

    svc_cashier = _svc(db, shop, cashier)
    res = await svc_cashier.apply(_ev("shift.close", {
        "id": shift_id,
        "declared_closing_cash": "100.00",
        "occurred_at": datetime.now(UTC).isoformat(),
    }))
    assert res.status == SyncResultStatus.REJECTED
    assert res.code == "forbidden"
