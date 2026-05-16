from datetime import datetime

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_user, db_session
from app.models import Sale, User

router = APIRouter(prefix="/sales", tags=["sales"])


@router.get("")
async def list_sales(
    from_: datetime | None = Query(None, alias="from"),
    to: datetime | None = Query(None),
    payment_method: str | None = Query(None),
    limit: int = Query(100, ge=1, le=500),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    stmt = select(Sale).where(Sale.shop_id == user.shop_id, Sale.deleted_at.is_(None))
    if from_:
        stmt = stmt.where(Sale.occurred_at >= from_)
    if to:
        stmt = stmt.where(Sale.occurred_at < to)
    if payment_method:
        stmt = stmt.where(Sale.payment_method == payment_method)
    stmt = stmt.order_by(Sale.occurred_at.desc()).limit(limit)
    rows = (await db.execute(stmt)).scalars().all()
    return {"items": [
        {
            "id": str(s.id),
            "total": str(s.total),
            "profit": str(s.total - s.cost_total),  # generated column not auto-mapped here
            "payment_method": s.payment_method,
            "status": s.status,
            "occurred_at": s.occurred_at.isoformat(),
            "user_id": str(s.user_id),
            "shift_id": str(s.shift_id) if s.shift_id else None,
        }
        for s in rows
    ]}
