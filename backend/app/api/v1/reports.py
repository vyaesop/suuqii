from datetime import UTC, datetime, timedelta
from decimal import ROUND_HALF_UP, Decimal
from typing import Literal
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import and_, case, exists, func, or_, select, text, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1._pagination import decode_time_cursor, encode_cursor
from app.core.capabilities import VIEW_COSTS, VIEW_REPORTS, can
from app.core.config import settings
from app.core.deps import current_user, db_session, require_cap
from app.core.shop_features import features_for
from app.core.size_presets import sort_sizes
from app.models import (
    Debt,
    Expense,
    InventoryLog,
    LotConsumption,
    Product,
    Sale,
    SaleItem,
    SaleReturn,
    SaleReturnItem,
    Shop,
    StockLot,
    Style,
    Supply,
    User,
)
from app.models.sale import SETTLED_STATUSES

router = APIRouter(prefix="/reports", tags=["reports"])

_EXPENSE_CATEGORIES = ("rent", "transport", "utilities", "salary", "supplies", "other")
_CENT = Decimal("0.01")


def _money(value) -> str:
    """Quantity (3 dp) × price (2 dp) comes back from Postgres at 5 dp;
    money on the wire is always cents."""
    return str(Decimal(value).quantize(_CENT))


# Sales that count as revenue. Mirrors ShiftService.expected_cash: a sale
# returned through sale.return stays in at its full total — even once every
# line is back and it reads 'refunded' — and the money that went back out is
# subtracted by _return_adjustments, in the period it actually left. Legacy
# sale.refund sales (no sale_returns row) stay excluded, as they always were.
_HAS_RETURNS = exists().where(SaleReturn.sale_id == Sale.id)
_REVENUE_STATUS = or_(
    Sale.status.in_(SETTLED_STATUSES),
    and_(Sale.status == "refunded", _HAS_RETURNS),
)


async def _return_adjustments(
    db: AsyncSession, shop_id: UUID, start: datetime, end: datetime | None = None, key=None,
) -> dict:
    """Returns in [start, end) → {group: [count, refund_total, resellable_cost]}.

    `key` is an optional grouping expression (a Sale column or an expression
    on SaleReturn); with no key the single group is keyed None. refund_total
    comes off revenue. resellable_cost is the cost of units that went back on
    the shelf and so comes back into gross profit; a damaged unit keeps its
    cost as the loss it is (and shows up in the returns report instead).
    """
    cols = [key] if key is not None else []
    window = [SaleReturn.shop_id == shop_id, SaleReturn.occurred_at >= start]
    if end is not None:
        window.append(SaleReturn.occurred_at < end)
    refunds = (await db.execute(
        select(
            *cols,
            func.count(SaleReturn.id),
            func.coalesce(func.sum(SaleReturn.refund_amount), 0),
        )
        .select_from(SaleReturn)
        .join(Sale, Sale.id == SaleReturn.sale_id)
        .where(*window)
        .group_by(*cols)
    )).all()
    costs = (await db.execute(
        select(*cols, func.coalesce(func.sum(SaleReturnItem.quantity * SaleItem.unit_cost), 0))
        .select_from(SaleReturnItem)
        .join(SaleReturn, SaleReturn.id == SaleReturnItem.return_id)
        .join(Sale, Sale.id == SaleReturn.sale_id)
        .join(SaleItem, SaleItem.id == SaleReturnItem.sale_item_id)
        .where(*window, SaleReturnItem.condition == "resellable")
        .group_by(*cols)
    )).all()
    out: dict = {}
    for row in refunds:
        out[row[0] if cols else None] = [int(row[-2]), Decimal(row[-1]), Decimal("0")]
    for row in costs:
        entry = out.setdefault(row[0] if cols else None, [0, Decimal("0"), Decimal("0")])
        entry[2] = Decimal(row[-1]).quantize(_CENT)
    return out


_NO_RETURNS = (0, Decimal("0"), Decimal("0"))
_NO_LINES = (Decimal("0"), Decimal("0"), Decimal("0"))


async def _returned_lines(
    db: AsyncSession, shop_id: UUID, start: datetime, end: datetime | None = None,
) -> dict[UUID, tuple[Decimal, Decimal, Decimal]]:
    """Returns in [start, end) per product → (qty, revenue, profit) to subtract.

    The line-level counterpart of _return_adjustments: that one nets the
    sale-level refund against revenue, this one nets the units themselves out
    of a per-product ranking. A returned unit is not a unit sold, so it comes
    off the line at the line's own price — these reports are pre-cart-discount,
    so the proportional credit ratio does not apply. A resellable unit gives
    its cost back and only the margin is lost; a damaged one is gone, so the
    whole price is.

    Shared by /top-products, /size-curve and /top-styles so "net of returns"
    means one thing everywhere.
    """
    where = [SaleReturn.shop_id == shop_id, SaleReturn.occurred_at >= start]
    if end is not None:
        where.append(SaleReturn.occurred_at < end)
    rows = (await db.execute(
        select(
            SaleItem.product_id,
            func.coalesce(func.sum(SaleReturnItem.quantity), 0).label("qty"),
            func.coalesce(
                func.sum(SaleReturnItem.quantity * SaleItem.unit_price), 0
            ).label("revenue"),
            func.coalesce(func.sum(case(
                (
                    SaleReturnItem.condition == "resellable",
                    SaleReturnItem.quantity * (SaleItem.unit_price - SaleItem.unit_cost),
                ),
                else_=SaleReturnItem.quantity * SaleItem.unit_price,
            )), 0).label("profit"),
        )
        .select_from(SaleReturnItem)
        .join(SaleReturn, SaleReturn.id == SaleReturnItem.return_id)
        .join(SaleItem, SaleItem.id == SaleReturnItem.sale_item_id)
        .where(*where)
        .group_by(SaleItem.product_id)
    )).all()
    return {
        r.product_id: (Decimal(r.qty), Decimal(r.revenue), Decimal(r.profit))
        for r in rows
    }


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
            _REVENUE_STATUS,
            Sale.occurred_at >= start,
        )
    )).scalar_one()
    # Money handed back through sale.return in the period comes off revenue;
    # the cost of resellable returned units comes back into gross profit.
    _, refund_total, resellable_cost = (
        await _return_adjustments(db, user.shop_id, start)
    ).get(None, _NO_RETURNS)
    billed_revenue = Decimal(billed_revenue) - refund_total

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
            _REVENUE_STATUS,
            Sale.occurred_at >= start,
        )
    )).scalar_one()
    gross_profit = Decimal(gross_profit) - refund_total + resellable_cost

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
    # Damaged returns also write a spoilage consumption (tagged with the sale
    # item they came back from), but their cost is already the loss inside
    # gross_profit above — the refund went out and no cost came back — so
    # they are left out here rather than counted against net profit twice.
    spoilage_cost = (await db.execute(
        select(func.coalesce(func.sum(LotConsumption.quantity * LotConsumption.unit_cost), 0))
        .where(
            LotConsumption.shop_id == user.shop_id,
            LotConsumption.movement == "spoilage",
            LotConsumption.sale_item_id.is_(None),
            LotConsumption.consumed_at >= start,
        )
    )).scalar_one()

    net_profit = Decimal(gross_profit) - total_expenses - Decimal(spoilage_cost)

    # ── Credit sales & outstanding debt ──────────────────────────────────────
    credit_sales = (await db.execute(
        select(func.coalesce(func.sum(Sale.total), 0)).where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None),
            _REVENUE_STATUS,
            Sale.payment_method == "credit",
            Sale.occurred_at >= start,
        )
    )).scalar_one()

    # ── Low stock ─────────────────────────────────────────────────────────────
    shop = await db.get(Shop, user.shop_id)
    features = features_for(shop.shop_type if shop else None)

    if features.has_supplies:
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
    elif features.has_variants:
        # A boutique does not run out of "jeans"; it runs out of size 32. The
        # unit of low stock is therefore the style with a broken size run —
        # one entry per style with ≥1 live variant at/below its threshold —
        # so the count reads as "styles to buy for", not "sizes missing".
        low_stock_rows = (await db.execute(
            select(
                Style.id,
                Style.name,
                func.coalesce(func.sum(Product.stock), 0).label("stock_total"),
                func.count(Product.id).label("sizes_out"),
            )
            .join(Product, Product.style_id == Style.id)
            .where(
                Style.shop_id == user.shop_id,
                Style.deleted_at.is_(None),
                Product.deleted_at.is_(None),
                Product.stock <= Product.low_stock_threshold,
            )
            .group_by(Style.id, Style.name)
            .order_by(Style.name)
            .limit(20)
        )).all()
        low_stock_out = [
            {
                "id": str(r.id),
                "name": r.name,
                "stock": str(r.stock_total),
                "sizes_out": int(r.sizes_out),
            }
            for r in low_stock_rows
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
        # Cash/mobile money handed back through sale.return in the period
        # (already netted out of billed_revenue and gross_profit).
        "refund_total": str(refund_total),
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
            _REVENUE_STATUS,
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

    # Returns land on the day the money went back, which may be a day with
    # no sales at all — such a day still appears, with negative revenue.
    by_day: dict[str, dict] = {}
    for r in rows:
        by_day[r.d.date().isoformat()] = {
            "revenue": Decimal(r.revenue), "profit": Decimal(r.profit), "count": int(r.sale_count),
        }
    adjustments = await _return_adjustments(
        db, user.shop_id, start, key=func.date_trunc("day", SaleReturn.occurred_at),
    )
    for day, (_, refund, resellable_cost) in adjustments.items():
        entry = by_day.setdefault(
            day.date().isoformat(), {"revenue": Decimal("0"), "profit": Decimal("0"), "count": 0}
        )
        entry["revenue"] -= refund
        entry["profit"] += resellable_cost - refund

    series = [
        {
            "date": date_key,
            "revenue": str(entry["revenue"]),
            "profit": str(entry["profit"]),
            "expenses": expenses_by_day.get(date_key, "0"),
            "sale_count": entry["count"],
        }
        for date_key, entry in sorted(by_day.items())
    ]

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
            _REVENUE_STATUS,
            Sale.occurred_at >= start,
        )
        .group_by(SaleItem.product_id, SaleItem.product_name_snapshot)
        .order_by(func.sum(SaleItem.quantity * SaleItem.unit_price).desc())
        .limit(limit)
    )).all()

    returned = await _returned_lines(db, user.shop_id, start)

    items = []
    for r in rows:
        ret_qty, ret_revenue, ret_profit = returned.get(r.product_id, _NO_LINES)
        qty = Decimal(r.qty) - ret_qty
        revenue = Decimal(r.revenue) - ret_revenue
        profit = Decimal(r.profit) - ret_profit
        # Margin % is on line-item revenue before any cart-level discount.
        # Cart discounts live on sale.discount and are not apportioned to items,
        # so true margin may be slightly lower than reported here.
        margin_pct = (profit / revenue * 100).quantize(Decimal("0.1")) if revenue else Decimal("0")
        items.append({
            "product_id": str(r.product_id),
            "name": r.name,
            "qty_sold": str(qty),
            "revenue": str(revenue),
            "profit": str(profit),
            "margin_pct": str(margin_pct),
        })
    # Returns may have reordered the top N.
    items.sort(key=lambda i: Decimal(i["revenue"]), reverse=True)

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
            _REVENUE_STATUS,
            Sale.occurred_at >= start,
        )
        .group_by(Sale.payment_method)
    )).all()
    # A return is netted against how the *sale* was paid, not how the money
    # was handed back — this is a revenue split, not a cash-drawer one.
    adjustments = await _return_adjustments(db, user.shop_id, start, key=Sale.payment_method)

    return {
        "range": range_,
        "methods": [
            {
                "method": r.payment_method,
                "total": str(
                    Decimal(r.total) - adjustments.get(r.payment_method, _NO_RETURNS)[1]
                ),
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
    features = features_for(shop.shop_type if shop else None)

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

    if features.has_supplies:
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
            _REVENUE_STATUS,
            Sale.occurred_at >= start,
        )
        .group_by(Sale.user_id)
    )).all()

    # Legacy full refunds: the whole sale total, against the sale's cashier.
    # Sales returned through sale.return are excluded here and counted below
    # from sale_returns, so neither path is counted twice.
    refund_rows = (await db.execute(
        select(
            Sale.user_id,
            func.count(Sale.id).label("refund_count"),
            func.coalesce(func.sum(Sale.total), 0).label("refund_total"),
        )
        .where(
            Sale.shop_id == user.shop_id,
            Sale.status == "refunded",
            ~_HAS_RETURNS,
            Sale.occurred_at >= start,
        )
        .group_by(Sale.user_id)
    )).all()
    refunds_by_user = {str(r.user_id): r for r in refund_rows}
    # Returns are attributed to the cashier who made the sale (whose revenue
    # they reduce), not to whoever processed the return.
    returns_by_user = {
        str(k): v
        for k, v in (await _return_adjustments(db, user.shop_id, start, key=Sale.user_id)).items()
    }

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
        # asyncpg binds by type: a UUID column wants a UUID and a timestamptz
        # wants a datetime — string forms raise DataError at execute time.
        {"shop_id": user.shop_id, "start": start},
    )).all()
    variance_by_user = {str(r.user_id): r for r in variance_rows}

    cashiers = []
    for r in sale_rows:
        uid = str(r.user_id)
        ref = refunds_by_user.get(uid)
        ret_count, ret_refund, ret_cost = returns_by_user.get(uid, _NO_RETURNS)
        var = variance_by_user.get(uid)
        revenue = Decimal(r.revenue) - ret_refund
        gross_profit = Decimal(r.gross_profit) - ret_refund + ret_cost
        margin_pct = (
            (gross_profit / revenue * 100).quantize(Decimal("0.1"))
            if revenue else Decimal("0")
        )
        refund_count = (int(ref.refund_count) if ref else 0) + ret_count
        refund_total = (Decimal(ref.refund_total) if ref else Decimal("0")) + ret_refund
        cashiers.append({
            "user_id": uid,
            "sale_count": int(r.sale_count),
            "revenue": str(revenue),
            "gross_profit": str(gross_profit),
            "margin_pct": str(margin_pct),
            "avg_transaction": str(Decimal(r.avg_transaction).quantize(Decimal("0.01"))),
            "refund_count": refund_count,
            "refund_total": str(refund_total),
            "refund_rate_pct": str(
                (Decimal(refund_count) / Decimal(r.sale_count) * 100).quantize(Decimal("0.1"))
                if refund_count and r.sale_count else Decimal("0")
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


def _window(from_: datetime | None, to: datetime | None) -> tuple[datetime, datetime]:
    """Explicit [from, to) range, defaulting to the last 30 days."""
    end = to or datetime.now(UTC)
    start = from_ or (end - timedelta(days=30))
    return start, end


@router.get("/returns")
async def returns_report(
    from_: datetime | None = Query(None, alias="from"),
    to: datetime | None = Query(None),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Returns in the period: how many, how much went back, what was lost to
    damage, why, and by whom (docs/19 §13.4). Owner-only."""
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    start, end = _window(from_, to)
    in_range = (
        SaleReturn.shop_id == user.shop_id,
        SaleReturn.occurred_at >= start,
        SaleReturn.occurred_at < end,
    )

    totals = (await db.execute(
        select(
            func.count(SaleReturn.id).label("count"),
            func.coalesce(func.sum(SaleReturn.refund_amount), 0).label("refund_total"),
        ).where(*in_range)
    )).one()

    # Damaged goods are valued at what they cost, not what they sold for —
    # that is the money actually lost.
    damaged_value = (await db.execute(
        select(func.coalesce(func.sum(SaleReturnItem.quantity * SaleItem.unit_cost), 0))
        .join(SaleReturn, SaleReturn.id == SaleReturnItem.return_id)
        .join(SaleItem, SaleItem.id == SaleReturnItem.sale_item_id)
        .where(*in_range, SaleReturnItem.condition == "damaged")
    )).scalar_one()

    by_reason_rows = (await db.execute(
        select(SaleReturn.reason, func.count(SaleReturn.id))
        .where(*in_range)
        .group_by(SaleReturn.reason)
    )).all()
    by_user_rows = (await db.execute(
        select(
            SaleReturn.user_id,
            func.count(SaleReturn.id).label("count"),
            func.coalesce(func.sum(SaleReturn.refund_amount), 0).label("refund_total"),
        )
        .where(*in_range)
        .group_by(SaleReturn.user_id)
        .order_by(func.count(SaleReturn.id).desc())
    )).all()

    return {
        "from": start.isoformat(),
        "to": end.isoformat(),
        "count": int(totals.count),
        "refund_total": _money(totals.refund_total),
        "damaged_value": _money(damaged_value),
        "by_reason": {(r[0] or "unspecified"): int(r[1]) for r in by_reason_rows},
        "by_user": [
            {
                "user_id": str(r.user_id),
                "count": int(r.count),
                "refund_total": _money(r.refund_total),
            }
            for r in by_user_rows
        ],
    }


@router.get("/price-leakage")
async def price_leakage(
    from_: datetime | None = Query(None, alias="from"),
    to: datetime | None = Query(None),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """What haggling is costing: Σ (list_price − unit_price) × qty over lines
    sold under their tag price (docs/19 §13.4), per cashier and per style.

    Only lines that declared a list_price count; a mark-down applied through
    `style.update` changes the tag itself and so does not appear here — see
    the `style.markdown` audit rows for those.
    """
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    start, end = _window(from_, to)

    gap = (SaleItem.list_price - SaleItem.unit_price) * SaleItem.quantity
    base = (
        select(Sale.user_id, SaleItem.product_id, gap.label("leakage"))
        .join(Sale, Sale.id == SaleItem.sale_id)
        .where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None),
            _REVENUE_STATUS,
            Sale.occurred_at >= start,
            Sale.occurred_at < end,
            SaleItem.list_price.is_not(None),
            SaleItem.list_price > SaleItem.unit_price,
        )
        .subquery()
    )

    totals = (await db.execute(
        select(func.count().label("lines"), func.coalesce(func.sum(base.c.leakage), 0).label("total"))
    )).one()
    by_user_rows = (await db.execute(
        select(base.c.user_id, func.count().label("lines"),
               func.coalesce(func.sum(base.c.leakage), 0).label("leakage"))
        .group_by(base.c.user_id)
        .order_by(func.sum(base.c.leakage).desc())
    )).all()
    by_style_rows = (await db.execute(
        select(
            Product.style_id,
            func.min(Style.name).label("name"),
            func.count().label("lines"),
            func.coalesce(func.sum(base.c.leakage), 0).label("leakage"),
        )
        .join(Product, Product.id == base.c.product_id)
        .outerjoin(Style, Style.id == Product.style_id)
        .group_by(Product.style_id)
        .order_by(func.sum(base.c.leakage).desc())
    )).all()

    return {
        "from": start.isoformat(),
        "to": end.isoformat(),
        "leakage_total": _money(totals.total),
        "lines": int(totals.lines),
        "by_user": [
            {"user_id": str(r.user_id), "lines": int(r.lines), "leakage": _money(r.leakage)}
            for r in by_user_rows
        ],
        "by_style": [
            {
                # Unstyled products are grouped under a null style so the
                # totals still reconcile.
                "style_id": str(r.style_id) if r.style_id else None,
                "name": r.name,
                "lines": int(r.lines),
                "leakage": _money(r.leakage),
            }
            for r in by_style_rows
        ],
    }


# ─────────────────────── boutique analytics (docs/19 §14) ───────────────────
#
# Four owner-only reads over data the app already stores, answering the three
# questions a boutique owner actually asks: which sizes to rebuy, what is not
# moving, and which styles earn. They gate on VIEW_REPORTS through
# `require_cap` rather than an inline role test — capabilities deny by default,
# so a role added later gets nothing here until it is granted something.
#
# Quantities go out trimmed ("3", not the Numeric(12,3) "3.000"): a boutique
# variant is a piece (`locks_unit`), so the tail is noise the client would
# have to strip on every row before drawing a bar.

_QTY = Decimal("0.001")
_RATIO = Decimal("0.001")


def _trim(value: Decimal) -> str:
    out = format(value, "f")
    if "." in out:
        out = out.rstrip("0").rstrip(".")
    return out or "0"


def _qty(value) -> str:
    d = Decimal(value or 0).quantize(_QTY)
    return "0" if d == 0 else _trim(d)


def _ratio(num: Decimal, den: Decimal) -> str:
    """Sell-through to 3 dp; "0" when nothing was received (§14.1) — dividing
    by a zero buy would otherwise read as "sold nothing" for stock that was
    never bought."""
    if not den:
        return "0"
    return _trim((Decimal(num) / Decimal(den)).quantize(_RATIO, rounding=ROUND_HALF_UP))


def _local_date(moment: datetime | None) -> str | None:
    """Wire dates are the shop's calendar day, not UTC's: a 23:30 sale in
    Addis (UTC+3) happened *yesterday* in UTC and the owner would not
    recognise the date."""
    if moment is None:
        return None
    return moment.astimezone(ZoneInfo(settings.timezone)).date().isoformat()


@router.get("/size-curve", dependencies=[Depends(require_cap(VIEW_REPORTS))])
async def size_curve(
    style_id: UUID = Query(...),
    from_: datetime | None = Query(None, alias="from"),
    to: datetime | None = Query(None),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """The buying grid for one style: bought, sold, left — per size and per
    colour (docs/19 §14.1).

    `received` is deliberately all-time while `sold`/`revenue` are windowed:
    sell-through only means anything against the whole buy. Comparing a
    month's sales to that month's receipts would flatter a style that was
    bought once and has been selling down ever since.
    """
    style = await db.get(Style, style_id)
    if style is None or style.shop_id != user.shop_id or style.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "style not found")
    start, end = _window(from_, to)

    variants = (await db.execute(
        select(Product.id, Product.size, Product.color, Product.stock).where(
            Product.shop_id == user.shop_id,
            Product.style_id == style.id,
            Product.deleted_at.is_(None),
        )
    )).all()
    ids = [v.id for v in variants]

    received: dict[UUID, Decimal] = {}
    sold: dict[UUID, Decimal] = {}
    revenue: dict[UUID, Decimal] = {}
    if ids:
        for row in (await db.execute(
            select(
                StockLot.product_id,
                func.coalesce(func.sum(StockLot.qty_received), 0).label("qty"),
            )
            .where(StockLot.shop_id == user.shop_id, StockLot.product_id.in_(ids))
            .group_by(StockLot.product_id)
        )).all():
            received[row.product_id] = Decimal(row.qty)
        for row in (await db.execute(
            select(
                SaleItem.product_id,
                func.coalesce(func.sum(SaleItem.quantity), 0).label("qty"),
                func.coalesce(
                    func.sum(SaleItem.quantity * SaleItem.unit_price), 0
                ).label("revenue"),
            )
            .join(Sale, Sale.id == SaleItem.sale_id)
            .where(
                Sale.shop_id == user.shop_id,
                Sale.deleted_at.is_(None),
                _REVENUE_STATUS,
                Sale.occurred_at >= start,
                Sale.occurred_at < end,
                SaleItem.product_id.in_(ids),
            )
            .group_by(SaleItem.product_id)
        )).all():
            sold[row.product_id] = Decimal(row.qty)
            revenue[row.product_id] = Decimal(row.revenue)
    returned = await _returned_lines(db, user.shop_id, start, end)

    # Both views are built in one pass so they can never disagree with each
    # other or with `totals`.
    by_size: dict[str | None, list[Decimal]] = {}
    by_color: dict[str | None, list[Decimal]] = {}
    totals = [Decimal("0")] * 4
    for v in variants:
        ret_qty, ret_revenue, _ = returned.get(v.id, _NO_LINES)
        cell = [
            received.get(v.id, Decimal("0")),
            sold.get(v.id, Decimal("0")) - ret_qty,
            Decimal(v.stock),
            revenue.get(v.id, Decimal("0")) - ret_revenue,
        ]
        for bucket, key in ((by_size, v.size), (by_color, v.color)):
            acc = bucket.setdefault(key, [Decimal("0")] * 4)
            for i in range(4):
                acc[i] += cell[i]
        for i in range(4):
            totals[i] += cell[i]

    def _row(label_key: str, label: str | None, acc: list[Decimal]) -> dict:
        got, went, left, money = acc
        return {
            label_key: label,
            "received": _qty(got),
            "sold": _qty(went),
            "on_hand": _qty(left),
            "sell_through": _ratio(went, got),
            "revenue": _money(money),
        }

    return {
        "style": {"id": str(style.id), "name": style.name, "brand": style.brand},
        "sizes": [
            _row("size", s, by_size[s])
            for s in sort_sizes(list(by_size), style.size_set)
        ],
        "colors": [_row("color", c, by_color[c]) for c in sort_sizes(list(by_color))],
        "totals": {
            "received": _qty(totals[0]),
            "sold": _qty(totals[1]),
            "on_hand": _qty(totals[2]),
            "revenue": _money(totals[3]),
        },
    }


@router.get("/dead-stock", dependencies=[Depends(require_cap(VIEW_REPORTS))])
async def dead_stock(
    days: int = Query(60, ge=1, le=365),
    limit: int = Query(100, ge=1, le=500),
    cursor: str | None = Query(None),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Stock on the shelf that nothing has sold for `days` days (docs/19 §14.2).

    Age comes from the oldest *open* lot, not the first ever receipt: a style
    that sold out and was rebought last week is not dead stock, even though
    its first carton arrived a year ago.
    """
    now = datetime.now(UTC)
    cutoff = now - timedelta(days=days)

    open_lots = (
        select(
            StockLot.product_id.label("product_id"),
            func.min(StockLot.received_at).label("oldest_open"),
            func.sum(StockLot.qty_remaining).label("qty_open"),
            func.sum(StockLot.qty_remaining * StockLot.unit_cost).label("cost_open"),
        )
        .where(StockLot.shop_id == user.shop_id, StockLot.qty_remaining > 0)
        .group_by(StockLot.product_id)
        .subquery()
    )
    last_sale = (
        select(
            SaleItem.product_id.label("product_id"),
            func.max(Sale.occurred_at).label("last_sold_at"),
        )
        .join(Sale, Sale.id == SaleItem.sale_id)
        .where(Sale.shop_id == user.shop_id, Sale.deleted_at.is_(None), _REVENUE_STATUS)
        .group_by(SaleItem.product_id)
        .subquery()
    )
    # Stock received before lots existed (a CSV import, an early
    # product.create) has no lot to date it, so the row's own age stands in —
    # better than claiming it arrived today and sorting it to the bottom.
    age_key = func.coalesce(open_lots.c.oldest_open, Product.created_at)
    unit_cost = case(
        (open_lots.c.qty_open > 0, open_lots.c.cost_open / open_lots.c.qty_open),
        else_=Product.purchase_price,
    )
    value = Product.stock * unit_cost

    base = (
        select(
            Product.id,
            Product.name,
            Product.style_id,
            Product.size,
            Product.color,
            Product.stock,
            age_key.label("age_from"),
            last_sale.c.last_sold_at,
            unit_cost.label("unit_cost"),
            value.label("value"),
        )
        .outerjoin(open_lots, open_lots.c.product_id == Product.id)
        .outerjoin(last_sale, last_sale.c.product_id == Product.id)
        .where(
            Product.shop_id == user.shop_id,
            Product.deleted_at.is_(None),
            Product.stock > 0,
            or_(last_sale.c.last_sold_at.is_(None), last_sale.c.last_sold_at < cutoff),
        )
    )

    # The headline total covers everything that qualifies, not just this page:
    # it is the "money asleep on the shelf" number and would be meaningless if
    # it shrank as the owner scrolled.
    total_value = (await db.execute(
        select(func.coalesce(func.sum(base.subquery().c.value), 0))
    )).scalar_one()

    stmt = base
    decoded = decode_time_cursor(cursor)
    if decoded:
        stmt = stmt.where(tuple_(age_key, Product.id) > decoded)
    # Oldest first, then the biggest money asleep. The keyset runs on
    # (age_from, id); age_from is a microsecond timestamp, so a tie that the
    # value ordering would have to break cannot straddle a page in practice.
    stmt = stmt.order_by(age_key.asc(), value.desc(), Product.id.asc()).limit(limit + 1)
    rows = (await db.execute(stmt)).all()
    has_more = len(rows) > limit
    rows = rows[:limit]

    show_costs = can(user.role, VIEW_COSTS)
    return {
        "days": days,
        "items": [
            {
                "product_id": str(r.id),
                "name": r.name,
                "style_id": str(r.style_id) if r.style_id else None,
                "size": r.size,
                "color": r.color,
                "stock": _qty(r.stock),
                "age_days": (now - r.age_from).days,
                "last_sold_at": _local_date(r.last_sold_at),
                "unit_cost": _money(r.unit_cost) if show_costs else "0",
                "value": _money(r.value) if show_costs else "0",
            }
            for r in rows
        ],
        "total_value": _money(total_value) if show_costs else "0",
        "next_cursor": encode_cursor(rows[-1].age_from, rows[-1].id) if has_more else None,
        "has_more": has_more,
    }


@router.get("/broken-runs", dependencies=[Depends(require_cap(VIEW_REPORTS))])
async def broken_runs(
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """The rebuy list: styles where some sizes have run out while others are
    still selling (docs/19 §14.3).

    A style whose every variant is depleted is *not* listed: it is gone, not
    broken, and there is no run left to complete. Listing those would bury the
    rows the owner can act on today.
    """
    start = datetime.now(UTC) - timedelta(days=30)

    variants = (await db.execute(
        select(
            Product.id,
            Product.style_id,
            Product.size,
            Product.color,
            Product.stock,
            Product.low_stock_threshold,
            Style.name,
            Style.brand,
            Style.image_url,
            Style.size_set,
        )
        .join(Style, Style.id == Product.style_id)
        .where(
            Product.shop_id == user.shop_id,
            Product.deleted_at.is_(None),
            Style.deleted_at.is_(None),
        )
    )).all()
    if not variants:
        return {"items": []}

    sold_30d = {
        row.product_id: Decimal(row.qty)
        for row in (await db.execute(
            select(
                SaleItem.product_id,
                func.coalesce(func.sum(SaleItem.quantity), 0).label("qty"),
            )
            .join(Sale, Sale.id == SaleItem.sale_id)
            .where(
                Sale.shop_id == user.shop_id,
                Sale.deleted_at.is_(None),
                _REVENUE_STATUS,
                Sale.occurred_at >= start,
            )
            .group_by(SaleItem.product_id)
        )).all()
    }
    returned = await _returned_lines(db, user.shop_id, start)

    styles: dict[UUID, dict] = {}
    for v in variants:
        s = styles.setdefault(v.style_id, {
            "style_id": str(v.style_id), "name": v.name, "brand": v.brand,
            "image_url": v.image_url, "size_set": v.size_set,
            "variant_count": 0, "in_stock_count": 0, "stock_total": Decimal("0"),
            "missing": [],
        })
        s["variant_count"] += 1
        s["stock_total"] += Decimal(v.stock)
        if Decimal(v.stock) > Decimal(v.low_stock_threshold):
            s["in_stock_count"] += 1
        else:
            moved = sold_30d.get(v.id, Decimal("0")) - returned.get(v.id, _NO_LINES)[0]
            s["missing"].append({"size": v.size, "color": v.color, "sold_30d": moved})

    items = []
    for s in styles.values():
        # Both halves are required: nothing depleted is a healthy run, nothing
        # left in stock is a dead style, and neither is a rebuy decision.
        if not s["missing"] or s["in_stock_count"] == 0:
            continue
        # Rebuy what moves: inside a style the depleted variants rank by their
        # own 30-day sales, ties resolved along the size run so the order is
        # stable between calls.
        rank = {
            size: i for i, size in enumerate(sort_sizes(
                [m["size"] for m in s["missing"]], s["size_set"],
            ))
        }
        s["missing"].sort(key=lambda m: (-m["sold_30d"], rank[m["size"]], m["color"] or ""))
        items.append({
            "style_id": s["style_id"],
            "name": s["name"],
            "brand": s["brand"],
            "image_url": s["image_url"],
            "variant_count": s["variant_count"],
            "in_stock_count": s["in_stock_count"],
            "stock_total": _qty(s["stock_total"]),
            "missing": [
                {"size": m["size"], "color": m["color"], "sold_30d": _qty(m["sold_30d"])}
                for m in s["missing"]
            ],
            "_demand": sum((m["sold_30d"] for m in s["missing"]), Decimal("0")),
        })

    items.sort(key=lambda i: (-i["_demand"], i["name"]))
    for i in items:
        del i["_demand"]
    return {"items": items}


@router.get("/top-styles", dependencies=[Depends(require_cap(VIEW_REPORTS))])
async def top_styles(
    from_: datetime | None = Query(None, alias="from"),
    to: datetime | None = Query(None),
    limit: int = Query(10, ge=1, le=50),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Best sellers rolled up to the style (docs/19 §14.4).

    An owner thinks "Slim jeans", not eight rows of the same jeans, so
    /top-products reads as noise in a boutique. Products with no live style
    roll up as themselves under a null style_id, so a shop that mixes plain
    stock in with its styles still sees all of it.
    """
    start, end = _window(from_, to)

    # Group on the live style, falling back to the product itself. Both sides
    # of the COALESCE are UUIDs, so one grouping key covers both cases and the
    # ranking stays a single sort.
    grp = func.coalesce(Style.id, SaleItem.product_id)
    rows = (await db.execute(
        select(
            grp.label("grp"),
            Style.id.label("style_id"),
            Style.name.label("style_name"),
            Style.brand,
            Style.image_url,
            func.min(SaleItem.product_name_snapshot).label("snapshot"),
            func.coalesce(func.sum(SaleItem.quantity), 0).label("qty"),
            func.coalesce(
                func.sum(SaleItem.quantity * SaleItem.unit_price), 0
            ).label("revenue"),
            func.coalesce(
                func.sum(SaleItem.quantity * (SaleItem.unit_price - SaleItem.unit_cost)), 0
            ).label("profit"),
        )
        .join(Sale, Sale.id == SaleItem.sale_id)
        .outerjoin(
            Product,
            and_(Product.id == SaleItem.product_id, Product.deleted_at.is_(None)),
        )
        .outerjoin(
            Style,
            and_(Style.id == Product.style_id, Style.deleted_at.is_(None)),
        )
        .where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None),
            _REVENUE_STATUS,
            Sale.occurred_at >= start,
            Sale.occurred_at < end,
        )
        .group_by(grp, Style.id, Style.name, Style.brand, Style.image_url)
    )).all()
    if not rows:
        return {"items": []}

    live_styles = {
        pid: sid
        for pid, sid in (await db.execute(
            select(Product.id, Product.style_id)
            .join(Style, Style.id == Product.style_id)
            .where(
                Product.shop_id == user.shop_id,
                Product.deleted_at.is_(None),
                Style.deleted_at.is_(None),
            )
        )).all()
    }
    variant_counts = {
        sid: int(n)
        for sid, n in (await db.execute(
            select(Product.style_id, func.count(Product.id))
            .join(Style, Style.id == Product.style_id)
            .where(
                Product.shop_id == user.shop_id,
                Product.deleted_at.is_(None),
                Style.deleted_at.is_(None),
            )
            .group_by(Product.style_id)
        )).all()
    }

    # Returns land on the product; fold them onto the group that product
    # belongs to so a returned variant cools its whole style's ranking.
    returned = await _returned_lines(db, user.shop_id, start, end)
    net: dict[UUID, list[Decimal]] = {}
    for pid, (qty, revenue, profit) in returned.items():
        acc = net.setdefault(live_styles.get(pid) or pid, [Decimal("0")] * 3)
        acc[0] += qty
        acc[1] += revenue
        acc[2] += profit

    show_costs = can(user.role, VIEW_COSTS)
    items = []
    for r in rows:
        ret = net.get(r.grp, [Decimal("0")] * 3)
        items.append({
            "style_id": str(r.style_id) if r.style_id else None,
            "name": r.style_name or r.snapshot,
            "brand": r.brand,
            "image_url": r.image_url,
            "quantity": Decimal(r.qty) - ret[0],
            "revenue": Decimal(r.revenue) - ret[1],
            "profit": Decimal(r.profit) - ret[2],
            "variant_count": variant_counts.get(r.style_id, 1) if r.style_id else 1,
        })
    # Rank after netting: a style whose sales mostly came back must not keep a
    # top slot it no longer earns.
    items.sort(key=lambda i: (-i["revenue"], i["name"]))
    return {
        "items": [
            {
                **i,
                "quantity": _qty(i["quantity"]),
                "revenue": _money(i["revenue"]),
                # Cost is owner-only, like every other margin on this surface.
                "profit": _money(i["profit"]) if show_costs else "0",
            }
            for i in items[:limit]
        ]
    }
