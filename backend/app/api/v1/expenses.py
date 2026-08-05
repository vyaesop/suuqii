from fastapi import APIRouter, Depends, Query
from sqlalchemy import select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1._pagination import decode_time_cursor, encode_cursor
from app.core.capabilities import RECORD_EXPENSE
from app.core.deps import current_user, db_session, require_cap
from app.models import Expense, User

router = APIRouter(prefix="/expenses", tags=["expenses"])


@router.get("", dependencies=[Depends(require_cap(RECORD_EXPENSE))])
async def list_expenses(
    limit: int = Query(200, ge=1, le=500),
    cursor: str | None = Query(None),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    stmt = select(Expense).where(
        Expense.shop_id == user.shop_id, Expense.deleted_at.is_(None)
    )
    decoded = decode_time_cursor(cursor)
    if decoded:
        stmt = stmt.where(tuple_(Expense.occurred_at, Expense.id) < decoded)
    stmt = stmt.order_by(Expense.occurred_at.desc(), Expense.id.desc()).limit(limit + 1)
    rows = (await db.execute(stmt)).scalars().all()
    has_more = len(rows) > limit
    rows = rows[:limit]
    return {
        "items": [
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
        ],
        "next_cursor": encode_cursor(rows[-1].occurred_at, rows[-1].id) if has_more else None,
        "has_more": has_more,
    }
