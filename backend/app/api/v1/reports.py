from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_user, db_session
from app.models import Debt, Expense, Product, Sale, User

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
