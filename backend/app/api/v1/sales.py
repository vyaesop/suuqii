from datetime import datetime

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1._pagination import decode_time_cursor, encode_cursor
from app.core.capabilities import SELL, VIEW_REPORTS, can
from app.core.deps import current_user, db_session, require_cap
from app.models import Sale, User

router = APIRouter(prefix="/sales", tags=["sales"])


@router.get("", dependencies=[Depends(require_cap(SELL))])
async def list_sales(
    from_: datetime | None = Query(None, alias="from"),
    to: datetime | None = Query(None),
    payment_method: str | None = Query(None),
    limit: int = Query(100, ge=1, le=500),
    cursor: str | None = Query(None),
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
    decoded = decode_time_cursor(cursor)
    if decoded:
        stmt = stmt.where(tuple_(Sale.occurred_at, Sale.id) < decoded)
    stmt = stmt.order_by(Sale.occurred_at.desc(), Sale.id.desc()).limit(limit + 1)
    rows = (await db.execute(stmt)).scalars().all()
    has_more = len(rows) > limit
    rows = rows[:limit]
    show_profit = can(user.role, VIEW_REPORTS)
    return {
        "items": [
            {
                "id": str(s.id),
                "total": str(s.total),
                # Profit reveals purchase cost; restrict to owners.
                **({"profit": str(s.total - s.cost_total)} if show_profit else {}),
                "payment_method": s.payment_method,
                "status": s.status,
                "occurred_at": s.occurred_at.isoformat(),
                "user_id": str(s.user_id),
                "shift_id": str(s.shift_id) if s.shift_id else None,
            }
            for s in rows
        ],
        "next_cursor": encode_cursor(rows[-1].occurred_at, rows[-1].id) if has_more else None,
        "has_more": has_more,
    }
