from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_user, db_session
from app.models import Expense, User

router = APIRouter(prefix="/expenses", tags=["expenses"])


@router.get("")
async def list_expenses(
    limit: int = Query(200, ge=1, le=500),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    stmt = (
        select(Expense)
        .where(Expense.shop_id == user.shop_id, Expense.deleted_at.is_(None))
        .order_by(Expense.occurred_at.desc())
        .limit(limit)
    )
    rows = (await db.execute(stmt)).scalars().all()
    return {"items": [
        {
            "id": str(e.id),
            "title": e.title,
            "amount": str(e.amount),
            "category": e.category,
            "description": e.description,
            "occurred_at": e.occurred_at.isoformat(),
            "user_id": str(e.user_id),
            "shift_id": str(e.shift_id) if e.shift_id else None,
        }
        for e in rows
    ]}
