from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Literal
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.capabilities import VIEW_REPORTS, can
from app.core.config import settings
from app.core.deps import current_user, db_session
from app.models import (
    Debt,
    Expense,
    InventoryLog,
    LotConsumption,
    Product,
    Sale,
    SaleItem,
    Shop,
    StockLot,
    Supply,
    User,
)

router = APIRouter(prefix="/reports", tags=["reports"])

_EXPENSE_CATEGORIES = ("rent", "transport", "utilities", "salary", "supplies", "other")


def _range_start(range_: str) -> datetime:
    now = datetime.now(UTC)
    if range_ == "today":
        # "Today" means the shop's local day (settings.timezone, e.g.
        # Africa/Addis_Ababa = UTC+3), not the UTC day — otherwise the
        # dashboard resets at 3 AM local and disagrees with sales_daily_mv.
        tz = ZoneInfo(settings.timezone)
        local_midnight = now.astimezone(tz).replace(hour=0, minute=0, second=0, microsecond=0)
        return local_midnight.astimezone(UTC)
    if range_ == "7d":
        return now - timedelta(days=7)
    return now - timedelta(days=30)


@router.get("/dashboard")
async def dashboard(
    range_: Literal["today", "7d", "30d"] = Query("today", alias="range"),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    start = _range_start(range_)

    # ── Revenue ──────────────────────────────────────────────────────────────
    billed_revenue = (await db.execute(
        select(func.coalesce(func.sum(Sale.total), 0)).where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None),
            Sale.status == "completed",
            Sale.occurred_at >= start,
        )
    )).scalar_one()

    # Collected revenue = billed revenue minus debt still outstanding
    # (credit sales that have not yet been paid reduce collected revenue).
    all_outstanding = (await db.execute(
        select(func.coalesce(func.sum(Debt.amount_owed - Debt.amount_paid), 0)).where(
            Debt.shop_id == user.shop_id,
            Debt.deleted_at.is_(None),
            Debt.status.in_(["open", "partial"]),
        )
    )).scalar_one()
    collected_revenue = Decimal(billed_revenue) - Decimal(all_outstanding)

    # ── Gross profit ─────────────────────────────────────────────────────────
    gross_profit = (await db.execute(
        select(func.coalesce(func.sum(Sale.total - Sale.cost_total), 0)).where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None),
            Sale.status == "completed",
            Sale.occurred_at >= start,
        )
    )).scalar_one()

    # ── Expenses — total + breakdown by category ──────────────────────────────
    expense_rows = (await db.execute(
        select(
            Expense.category,
            func.coalesce(func.sum(Expense.amount), 0).label("total"),
        )
        .where(
            Expense.shop_id == user.shop_id,
            Expense.deleted_at.is_(None),
            Expense.occurred_at >= start,
        )
        .group_by(Expense.category)
    )).all()
    expenses_by_category: dict[str, str] = {c: "0" for c in _EXPENSE_CATEGORIES}
    total_expenses = Decimal("0")
    for row in expense_rows:
        cat = row.category if row.category in _EXPENSE_CATEGORIES else "other"
        expenses_by_category[cat] = str(
            Decimal(expenses_by_category[cat]) + Decimal(row.total)
        )
        total_expenses += Decimal(row.total)

    # ── Spoilage / waste (valued at lot cost at spoilage time) ───────────────
    spoilage_cost = (await db.execute(
        select(func.coalesce(func.sum(LotConsumption.quantity * LotConsumption.unit_cost), 0))
        .where(
            LotConsumption.shop_id == user.shop_id,
            LotConsumption.movement == "spoilage",
            LotConsumption.consumed_at >= start,
        )
    )).scalar_one()

    net_profit = Decimal(gross_profit) - total_expenses - Decimal(spoilage_cost)

    # ── Credit sales & outstanding debt ──────────────────────────────────────
    credit_sales = (await db.execute(
        select(func.coalesce(func.sum(Sale.total), 0)).where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None),
            Sale.status == "completed",
            Sale.payment_method == "credit",
            Sale.occurred_at >= start,
        )
    )).scalar_one()

    # ── Low stock ─────────────────────────────────────────────────────────────
    shop = await db.get(Shop, user.shop_id)
    is_bakery = shop is not None and shop.shop_type == "bakery"

    if is_bakery:
        low_stock_rows = (await db.execute(
            select(Supply).where(
                Supply.shop_id == user.shop_id,
                Supply.deleted_at.is_(None),
                Supply.quantity_on_hand <= Supply.reorder_threshold,
            ).limit(20)
        )).scalars().all()
        low_stock_out = [
            {"id": str(s.id), "name": s.name, "stock": str(s.quantity_on_hand)}
            for s in low_stock_rows
        ]
    else:
        low_stock_rows = (await db.execute(
            select(Product).where(
                Product.shop_id == user.shop_id,
                Product.deleted_at.is_(None),
                Product.stock <= Product.low_stock_threshold,
            ).limit(20)
        )).scalars().all()
        low_stock_out = [
            {"id": str(p.id), "name": p.name, "stock": str(p.stock)}
            for p in low_stock_rows
        ]

    return {
        "range": range_,
        # Billed revenue = all completed sales (includes uncollected credit).
        "billed_revenue": str(billed_revenue),
        # Collected revenue = billed minus total outstanding AR across all time.
        "collected_revenue": str(collected_revenue),
        # Legacy alias — kept for mobile backward compatibility.
        "revenue": str(billed_revenue),
        "gross_profit": str(gross_profit),
        # Legacy alias.
        "profit": str(gross_profit),
        "expenses": str(total_expenses),
        "expenses_by_category": expenses_by_category,
        "spoilage_cost": str(spoilage_cost),
        "net_profit": str(net_profit),
        "credit_sales": str(credit_sales),
        "outstanding_debt": str(all_outstanding),
        "low_stock": low_stock_out,
    }


@router.get("/sales-series")
async def sales_series(
    range_: Literal["7d", "30d"] = Query("7d", alias="range"),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Per-day sales / profit / expense totals for the requested range."""
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    start = _range_start(range_)
    day = func.date_trunc("day", Sale.occurred_at)
    rows = (await db.execute(
        select(
            day.label("d"),
            func.coalesce(func.sum(Sale.total), 0).label("revenue"),
            func.coalesce(func.sum(Sale.total - Sale.cost_total), 0).label("profit"),
            func.count(Sale.id).label("sale_count"),
        )
        .where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None),
            Sale.status == "completed",
            Sale.occurred_at >= start,
        )
        .group_by(day)
        .order_by(day)
    )).all()

    e_day = func.date_trunc("day", Expense.occurred_at)
    expense_rows = (await db.execute(
        select(e_day.label("d"), func.coalesce(func.sum(Expense.amount), 0).label("amount"))
        .where(
            Expense.shop_id == user.shop_id,
            Expense.deleted_at.is_(None),
            Expense.occurred_at >= start,
        )
        .group_by(e_day)
    )).all()
    expenses_by_day = {r.d.date().isoformat(): str(r.amount) for r in expense_rows}

    series = []
    for r in rows:
        date_key = r.d.date().isoformat()
        series.append({
            "date": date_key,
            "revenue": str(r.revenue),
            "profit": str(r.profit),
            "expenses": expenses_by_day.get(date_key, "0"),
            "sale_count": int(r.sale_count),
        })

    return {"range": range_, "series": series}


@router.get("/top-products")
async def top_products(
    range_: Literal["7d", "30d"] = Query("7d", alias="range"),
    limit: int = Query(10, ge=1, le=50),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Best-selling products ranked by revenue, with margin %."""
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    start = _range_start(range_)
    rows = (await db.execute(
        select(
            SaleItem.product_id,
            SaleItem.product_name_snapshot.label("name"),
            func.coalesce(func.sum(SaleItem.quantity), 0).label("qty"),
            func.coalesce(
                func.sum(SaleItem.quantity * SaleItem.unit_price), 0
            ).label("revenue"),
            func.coalesce(
                func.sum(SaleItem.quantity * (SaleItem.unit_price - SaleItem.unit_cost)),
                0,
            ).label("profit"),
        )
        .join(Sale, Sale.id == SaleItem.sale_id)
        .where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None),
            Sale.status == "completed",
            Sale.occurred_at >= start,
        )
        .group_by(SaleItem.product_id, SaleItem.product_name_snapshot)
        .order_by(func.sum(SaleItem.quantity * SaleItem.unit_price).desc())
        .limit(limit)
    )).all()

    items = []
    for r in rows:
        revenue = Decimal(r.revenue)
        profit = Decimal(r.profit)
        # Margin % is on line-item revenue before any cart-level discount.
        # Cart discounts live on sale.discount and are not apportioned to items,
        # so true margin may be slightly lower than reported here.
        margin_pct = (profit / revenue * 100).quantize(Decimal("0.1")) if revenue else Decimal("0")
        items.append({
            "product_id": str(r.product_id),
            "name": r.name,
            "qty_sold": str(r.qty),
            "revenue": str(revenue),
            "profit": str(profit),
            "margin_pct": str(margin_pct),
        })

    return {"range": range_, "items": items}


@router.get("/payment-mix")
async def payment_mix(
    range_: Literal["today", "7d", "30d"] = Query("7d", alias="range"),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Revenue split by payment method (cash / mobile / credit)."""
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    start = _range_start(range_)
    rows = (await db.execute(
        select(
            Sale.payment_method,
            func.coalesce(func.sum(Sale.total), 0).label("total"),
            func.count(Sale.id).label("count"),
        )
        .where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None),
            Sale.status == "completed",
            Sale.occurred_at >= start,
        )
        .group_by(Sale.payment_method)
    )).all()

    return {
        "range": range_,
        "methods": [
            {
                "method": r.payment_method,
                "total": str(r.total),
                "count": int(r.count),
            }
            for r in rows
        ],
    }


@router.get("/ar-aging")
async def ar_aging(
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Accounts-receivable aging: open/partial debts bucketed by age.

    Buckets: 0-30 days, 31-60 days, 61-90 days, 90+ days.
    Age is measured from the sale date (debt created_at).
    """
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    now = datetime.now(UTC)
    rows = (await db.execute(
        select(
            Debt.id,
            Debt.customer_name,
            Debt.customer_phone,
            Debt.amount_owed,
            Debt.amount_paid,
            (Debt.amount_owed - Debt.amount_paid).label("remaining"),
            Debt.due_date,
            Debt.status,
            Debt.created_at,
        )
        .where(
            Debt.shop_id == user.shop_id,
            Debt.deleted_at.is_(None),
            Debt.status.in_(["open", "partial"]),
        )
        .order_by(Debt.created_at.asc())
    )).all()

    buckets: dict[str, list] = {
        "0_30": [],
        "31_60": [],
        "61_90": [],
        "90_plus": [],
    }
    bucket_totals: dict[str, Decimal] = {k: Decimal("0") for k in buckets}

    for r in rows:
        age_days = (now - r.created_at).days
        remaining = Decimal(r.amount_owed) - Decimal(r.amount_paid)
        overdue = r.due_date is not None and r.due_date < now.date()

        entry = {
            "id": str(r.id),
            "customer_name": r.customer_name,
            "customer_phone": r.customer_phone,
            "amount_owed": str(r.amount_owed),
            "amount_paid": str(r.amount_paid),
            "remaining": str(remaining),
            "status": r.status,
            "due_date": r.due_date.isoformat() if r.due_date else None,
            "age_days": age_days,
            "overdue": overdue,
        }

        if age_days <= 30:
            key = "0_30"
        elif age_days <= 60:
            key = "31_60"
        elif age_days <= 90:
            key = "61_90"
        else:
            key = "90_plus"

        buckets[key].append(entry)
        bucket_totals[key] += remaining

    total_outstanding = sum(bucket_totals.values())

    return {
        "total_outstanding": str(total_outstanding),
        "buckets": {
            key: {
                "total": str(bucket_totals[key]),
                "count": len(entries),
                "debts": entries,
            }
            for key, entries in buckets.items()
        },
    }


@router.get("/inventory-valuation")
async def inventory_valuation(
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Current inventory value at purchase cost (stock × purchase_price).

    For bakery shops, also returns supply stock value (quantity × cost_per_unit).
    """
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    shop = await db.get(Shop, user.shop_id)
    is_bakery = shop is not None and shop.shop_type == "bakery"

    product_rows = (await db.execute(
        select(
            Product.id,
            Product.name,
            Product.category,
            Product.unit,
            Product.stock,
            Product.purchase_price,
            Product.selling_price,
            Product.low_stock_threshold,
            (Product.stock * Product.purchase_price).label("cost_value"),
            (Product.stock * Product.selling_price).label("retail_value"),
        )
        .where(
            Product.shop_id == user.shop_id,
            Product.deleted_at.is_(None),
            Product.stock > 0,
        )
        .order_by(Product.name)
    )).all()

    products_out = []
    total_cost_value = Decimal("0")
    total_retail_value = Decimal("0")

    for p in product_rows:
        cost_val = Decimal(p.cost_value)
        retail_val = Decimal(p.retail_value)
        total_cost_value += cost_val
        total_retail_value += retail_val
        products_out.append({
            "id": str(p.id),
            "name": p.name,
            "category": p.category,
            "unit": p.unit,
            "stock": str(p.stock),
            "purchase_price": str(p.purchase_price),
            "selling_price": str(p.selling_price),
            "cost_value": str(cost_val),
            "retail_value": str(retail_val),
            "is_low_stock": Decimal(p.stock) <= Decimal(p.low_stock_threshold),
        })

    result: dict = {
        "total_cost_value": str(total_cost_value),
        "total_retail_value": str(total_retail_value),
        "potential_gross_profit": str(total_retail_value - total_cost_value),
        "products": products_out,
    }

    if is_bakery:
        supply_rows = (await db.execute(
            select(
                Supply.id,
                Supply.name,
                Supply.unit,
                Supply.quantity_on_hand,
                Supply.cost_per_unit,
                Supply.reorder_threshold,
                (Supply.quantity_on_hand * Supply.cost_per_unit).label("value"),
            )
            .where(
                Supply.shop_id == user.shop_id,
                Supply.deleted_at.is_(None),
                Supply.quantity_on_hand > 0,
            )
            .order_by(Supply.name)
        )).all()

        total_supply_value = Decimal("0")
        supplies_out = []
        for s in supply_rows:
            val = Decimal(s.value)
            total_supply_value += val
            supplies_out.append({
                "id": str(s.id),
                "name": s.name,
                "unit": s.unit,
                "quantity_on_hand": str(s.quantity_on_hand),
                "cost_per_unit": str(s.cost_per_unit),
                "value": str(val),
                "is_low_stock": Decimal(s.quantity_on_hand) <= Decimal(s.reorder_threshold),
            })

        result["supplies_value"] = str(total_supply_value)
        result["supplies"] = supplies_out
        result["total_asset_value"] = str(total_cost_value + total_supply_value)

    return result


@router.get("/adjustments")
async def adjustments(
    range_: Literal["7d", "30d"] = Query("30d", alias="range"),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Manual inventory adjustments and waste movements in the requested period.

    Returns each non-sale, non-refund stock movement with the responsible user,
    helping owners spot patterns that may indicate theft or spoilage.
    """
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    start = _range_start(range_)

    rows = (await db.execute(
        select(
            InventoryLog.id,
            InventoryLog.product_id,
            InventoryLog.movement,
            InventoryLog.quantity_delta,
            InventoryLog.reason,
            InventoryLog.reference_type,
            InventoryLog.reference_id,
            InventoryLog.user_id,
            InventoryLog.created_at,
            Product.name.label("product_name"),
            Product.unit.label("product_unit"),
        )
        .join(Product, Product.id == InventoryLog.product_id)
        .where(
            InventoryLog.shop_id == user.shop_id,
            InventoryLog.movement.in_(["adjustment", "restock", "waste"]),
            InventoryLog.created_at >= start,
        )
        .order_by(InventoryLog.created_at.desc())
        .limit(500)
    )).all()

    # Aggregate totals by movement type
    totals: dict[str, Decimal] = {}
    items = []
    for r in rows:
        delta = Decimal(r.quantity_delta)
        mv = r.movement
        totals[mv] = totals.get(mv, Decimal("0")) + delta
        items.append({
            "id": str(r.id),
            "product_id": str(r.product_id),
            "product_name": r.product_name,
            "product_unit": r.product_unit,
            "movement": mv,
            "quantity_delta": str(delta),
            "reason": r.reason,
            "reference_type": r.reference_type,
            "reference_id": str(r.reference_id) if r.reference_id else None,
            "user_id": str(r.user_id) if r.user_id else None,
            "created_at": r.created_at.isoformat(),
        })

    return {
        "range": range_,
        "totals_by_movement": {k: str(v) for k, v in totals.items()},
        "count": len(items),
        "items": items,
    }


@router.get("/cashier-performance")
async def cashier_performance(
    range_: Literal["7d", "30d"] = Query("7d", alias="range"),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Per-cashier performance summary: sales, revenue, avg transaction,
    refund rate, and shift variance history."""
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    start = _range_start(range_)

    # Sales stats per user
    sale_rows = (await db.execute(
        select(
            Sale.user_id,
            func.count(Sale.id).label("sale_count"),
            func.coalesce(func.sum(Sale.total), 0).label("revenue"),
            func.coalesce(func.sum(Sale.total - Sale.cost_total), 0).label("gross_profit"),
            func.coalesce(func.avg(Sale.total), 0).label("avg_transaction"),
        )
        .where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None),
            Sale.status == "completed",
            Sale.occurred_at >= start,
        )
        .group_by(Sale.user_id)
    )).all()

    refund_rows = (await db.execute(
        select(
            Sale.user_id,
            func.count(Sale.id).label("refund_count"),
            func.coalesce(func.sum(Sale.total), 0).label("refund_total"),
        )
        .where(
            Sale.shop_id == user.shop_id,
            Sale.status == "refunded",
            Sale.occurred_at >= start,
        )
        .group_by(Sale.user_id)
    )).all()
    refunds_by_user = {str(r.user_id): r for r in refund_rows}

    # Shift variance history — closed shifts only, in range
    # variance = declared_closing_cash - expected_closing_cash (generated column)
    variance_rows = (await db.execute(
        text(
            "SELECT user_id, COUNT(*) AS shift_count, "
            "AVG(declared_closing_cash - expected_closing_cash) AS avg_variance, "
            "MAX(ABS(declared_closing_cash - expected_closing_cash)) AS max_variance_abs "
            "FROM shifts "
            "WHERE shop_id = :shop_id "
            "AND closed_at IS NOT NULL "
            "AND opened_at >= :start "
            "AND expected_closing_cash IS NOT NULL "
            "GROUP BY user_id"
        ),
        {"shop_id": str(user.shop_id), "start": start.isoformat()},
    )).all()
    variance_by_user = {str(r.user_id): r for r in variance_rows}

    cashiers = []
    for r in sale_rows:
        uid = str(r.user_id)
        ref = refunds_by_user.get(uid)
        var = variance_by_user.get(uid)
        revenue = Decimal(r.revenue)
        gross_profit = Decimal(r.gross_profit)
        margin_pct = (
            (gross_profit / revenue * 100).quantize(Decimal("0.1"))
            if revenue else Decimal("0")
        )
        cashiers.append({
            "user_id": uid,
            "sale_count": int(r.sale_count),
            "revenue": str(revenue),
            "gross_profit": str(gross_profit),
            "margin_pct": str(margin_pct),
            "avg_transaction": str(Decimal(r.avg_transaction).quantize(Decimal("0.01"))),
            "refund_count": int(ref.refund_count) if ref else 0,
            "refund_total": str(ref.refund_total) if ref else "0",
            "refund_rate_pct": str(
                (Decimal(ref.refund_count) / Decimal(r.sale_count) * 100).quantize(Decimal("0.1"))
                if ref and r.sale_count else Decimal("0")
            ),
            "shift_count": int(var.shift_count) if var else 0,
            "avg_shift_variance": str(
                Decimal(str(var.avg_variance)).quantize(Decimal("0.01")) if var else Decimal("0")
            ),
            "max_shift_variance_abs": str(
                Decimal(str(var.max_variance_abs)).quantize(Decimal("0.01")) if var else Decimal("0")
            ),
        })

    # Sort by revenue descending
    cashiers.sort(key=lambda c: Decimal(c["revenue"]), reverse=True)

    return {"range": range_, "cashiers": cashiers}


@router.get("/batches")
async def batch_report(
    product_id: UUID | None = Query(None),
    include_closed: bool = Query(False),
    limit: int = Query(100, ge=1, le=500),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Per-batch economics: what each lot cost, what it sold for, what
    spoiled, what's left. This is the answer to "the 10-birr sodas vs the
    13-birr sodas". Owner-only (exposes purchase costs)."""
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    stmt = select(StockLot).where(StockLot.shop_id == user.shop_id)
    if product_id:
        stmt = stmt.where(StockLot.product_id == product_id)
    if not include_closed:
        stmt = stmt.where(StockLot.qty_remaining > 0)
    stmt = stmt.order_by(StockLot.received_at.desc()).limit(limit)
    lots = (await db.execute(stmt)).scalars().all()

    lot_ids = [lot.id for lot in lots]
    sold: dict[UUID, Decimal] = {}
    spoiled: dict[UUID, Decimal] = {}
    revenue: dict[UUID, Decimal] = {}
    if lot_ids:
        # sale + refund_reversal rows net out refunds automatically
        # (reversals carry negative quantities).
        agg = (await db.execute(
            select(
                LotConsumption.lot_id,
                LotConsumption.movement,
                func.sum(LotConsumption.quantity).label("qty"),
            )
            .where(LotConsumption.lot_id.in_(lot_ids))
            .group_by(LotConsumption.lot_id, LotConsumption.movement)
        )).all()
        for row in agg:
            if row.movement in ("sale", "refund_reversal"):
                sold[row.lot_id] = sold.get(row.lot_id, Decimal("0")) + Decimal(row.qty)
            elif row.movement == "spoilage":
                spoiled[row.lot_id] = spoiled.get(row.lot_id, Decimal("0")) + Decimal(row.qty)

        rev = (await db.execute(
            select(
                LotConsumption.lot_id,
                func.sum(LotConsumption.quantity * SaleItem.unit_price).label("revenue"),
            )
            .join(SaleItem, SaleItem.id == LotConsumption.sale_item_id)
            .where(
                LotConsumption.lot_id.in_(lot_ids),
                LotConsumption.movement.in_(["sale", "refund_reversal"]),
            )
            .group_by(LotConsumption.lot_id)
        )).all()
        for row in rev:
            revenue[row.lot_id] = Decimal(row.revenue)

    product_names: dict[UUID, str] = {}
    for lot in lots:
        if lot.product_id not in product_names:
            prod = await db.get(Product, lot.product_id)
            product_names[lot.product_id] = prod.name if prod else "?"

    items = []
    for lot in lots:
        sold_qty = sold.get(lot.id, Decimal("0"))
        spoiled_qty = spoiled.get(lot.id, Decimal("0"))
        rev_amt = revenue.get(lot.id, Decimal("0"))
        cogs = sold_qty * lot.unit_cost
        items.append({
            "lot_id": str(lot.id),
            "product_id": str(lot.product_id),
            "product_name": product_names[lot.product_id],
            "received_at": lot.received_at.isoformat(),
            "expiry_date": lot.expiry_date.isoformat() if lot.expiry_date else None,
            "unit_cost": str(lot.unit_cost),
            "qty_received": str(lot.qty_received),
            "qty_sold": str(sold_qty),
            "qty_spoiled": str(spoiled_qty),
            "qty_remaining": str(lot.qty_remaining),
            "revenue": str(rev_amt),
            "margin": str(rev_amt - cogs),
            "spoilage_cost": str(spoiled_qty * lot.unit_cost),
            "note": lot.note,
        })
    return {"items": items}


@router.get("/expiring")
async def expiring_report(
    days: int = Query(7, ge=0, le=365),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Lots and supplies expiring within N days (or already expired), with
    value at risk. Owner-only; cashiers see expiry badges from local data."""
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    tz = ZoneInfo(settings.timezone)
    today = datetime.now(tz).date()
    horizon = today + timedelta(days=days)

    lots = (await db.execute(
        select(StockLot).where(
            StockLot.shop_id == user.shop_id,
            StockLot.qty_remaining > 0,
            StockLot.expiry_date.is_not(None),
            StockLot.expiry_date <= horizon,
        ).order_by(StockLot.expiry_date.asc())
    )).scalars().all()

    lot_items = []
    for lot in lots:
        prod = await db.get(Product, lot.product_id)
        lot_items.append({
            "lot_id": str(lot.id),
            "product_id": str(lot.product_id),
            "product_name": prod.name if prod else "?",
            "expiry_date": lot.expiry_date.isoformat(),
            "expired": lot.expiry_date < today,
            "qty_remaining": str(lot.qty_remaining),
            "value_at_risk": str(lot.qty_remaining * lot.unit_cost),
        })

    supplies = (await db.execute(
        select(Supply).where(
            Supply.shop_id == user.shop_id,
            Supply.deleted_at.is_(None),
            Supply.expiry_date.is_not(None),
            Supply.expiry_date <= horizon,
        ).order_by(Supply.expiry_date.asc())
    )).scalars().all()

    supply_items = [
        {
            "supply_id": str(s.id),
            "name": s.name,
            "expiry_date": s.expiry_date.isoformat(),
            "expired": s.expiry_date < today,
            "quantity_on_hand": str(s.quantity_on_hand),
            "value_at_risk": str(s.quantity_on_hand * s.cost_per_unit),
        }
        for s in supplies
    ]
    return {"lots": lot_items, "supplies": supply_items, "days": days}
