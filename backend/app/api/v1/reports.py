from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_user, db_session
from app.models import Debt, Expense, Product, Sale, SaleItem, User

router = APIRouter(prefix="/reports", tags=["reports"])


@router.get("/dashboard")
async def dashboard(
    range_: Literal["today", "7d", "30d"] = Query("today", alias="range"),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    now = datetime.now(UTC)
    if range_ == "today":
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    elif range_ == "7d":
        start = now - timedelta(days=7)
    else:
        start = now - timedelta(days=30)

    revenue = (await db.execute(
        select(func.coalesce(func.sum(Sale.total), 0)).where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None), Sale.status == "completed",
            Sale.occurred_at >= start,
        )
    )).scalar_one()
    profit = (await db.execute(
        select(func.coalesce(func.sum(Sale.total - Sale.cost_total), 0)).where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None), Sale.status == "completed",
            Sale.occurred_at >= start,
        )
    )).scalar_one()
    expenses = (await db.execute(
        select(func.coalesce(func.sum(Expense.amount), 0)).where(
            Expense.shop_id == user.shop_id,
            Expense.deleted_at.is_(None),
            Expense.occurred_at >= start,
        )
    )).scalar_one()
    credit_sales = (await db.execute(
        select(func.coalesce(func.sum(Sale.total), 0)).where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None), Sale.status == "completed",
            Sale.payment_method == "credit",
            Sale.occurred_at >= start,
        )
    )).scalar_one()
    outstanding_debt = (await db.execute(
        select(func.coalesce(func.sum(Debt.amount_owed - Debt.amount_paid), 0)).where(
            Debt.shop_id == user.shop_id,
            Debt.deleted_at.is_(None),
            Debt.status.in_(["open", "partial"]),
        )
    )).scalar_one()

    low_stock = (await db.execute(
        select(Product).where(
            Product.shop_id == user.shop_id,
            Product.deleted_at.is_(None),
            Product.stock <= Product.low_stock_threshold,
        ).limit(20)
    )).scalars().all()

    return {
        "range": range_,
        "revenue": str(revenue),
        "profit": str(profit),
        "expenses": str(expenses),
        "net_profit": str(Decimal(profit) - Decimal(expenses)),
        "credit_sales": str(credit_sales),
        "outstanding_debt": str(outstanding_debt),
        "low_stock": [
            {"id": str(p.id), "name": p.name, "stock": str(p.stock)} for p in low_stock
        ],
    }


def _range_start(range_: str) -> datetime:
    now = datetime.now(UTC)
    if range_ == "today":
        return now.replace(hour=0, minute=0, second=0, microsecond=0)
    if range_ == "7d":
        return now - timedelta(days=7)
    return now - timedelta(days=30)


@router.get("/sales-series")
async def sales_series(
    range_: Literal["7d", "30d"] = Query("7d", alias="range"),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """
    Per-day sales / profit / expense totals for the requested range.
    Used by the Reports screen drill-down.
    """
    if user.role != "owner":
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
    """
    Best-selling products in the requested range, ranked by revenue.
    """
    if user.role != "owner":
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

    return {
        "range": range_,
        "items": [
            {
                "product_id": str(r.product_id),
                "name": r.name,
                "qty_sold": str(r.qty),
                "revenue": str(r.revenue),
                "profit": str(r.profit),
            }
            for r in rows
        ],
    }


@router.get("/payment-mix")
async def payment_mix(
    range_: Literal["today", "7d", "30d"] = Query("7d", alias="range"),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Revenue split by payment method (cash / mobile / credit)."""
    if user.role != "owner":
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
