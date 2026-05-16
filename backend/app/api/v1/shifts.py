from datetime import datetime

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_user, db_session
from app.models import Shift, User

router = APIRouter(prefix="/shifts", tags=["shifts"])


@router.get("")
async def list_shifts(
    from_: datetime | None = Query(None, alias="from"),
    to: datetime | None = Query(None),
    user_id: str | None = Query(None),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    stmt = select(Shift).where(Shift.shop_id == user.shop_id)
    # Cashiers see only their own shifts
    if user.role != "owner":
        stmt = stmt.where(Shift.user_id == user.id)
    elif user_id:
        stmt = stmt.where(Shift.user_id == user_id)
    if from_:
        stmt = stmt.where(Shift.opened_at >= from_)
    if to:
        stmt = stmt.where(Shift.opened_at < to)
    stmt = stmt.order_by(Shift.opened_at.desc()).limit(200)
    rows = (await db.execute(stmt)).scalars().all()
    return {"items": [
        {
            "id": str(s.id),
            "user_id": str(s.user_id),
            "opened_at": s.opened_at.isoformat(),
            "closed_at": s.closed_at.isoformat() if s.closed_at else None,
            "opening_cash": str(s.opening_cash),
            "declared_closing_cash": str(s.declared_closing_cash) if s.declared_closing_cash is not None else None,
            "expected_closing_cash": str(s.expected_closing_cash) if s.expected_closing_cash is not None else None,
            "note": s.note,
        }
        for s in rows
    ]}
