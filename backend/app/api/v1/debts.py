from fastapi import APIRouter, Depends, Query
from sqlalchemy import select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1._pagination import decode_time_cursor, encode_cursor
from app.core.capabilities import MANAGE_DEBT
from app.core.deps import current_user, db_session, require_cap
from app.models import Debt, User

router = APIRouter(prefix="/debts", tags=["debts"])


@router.get("", dependencies=[Depends(require_cap(MANAGE_DEBT))])
async def list_debts(
    status: str | None = Query(None),
    limit: int = Query(200, ge=1, le=500),
    cursor: str | None = Query(None),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    stmt = select(Debt).where(Debt.shop_id == user.shop_id, Debt.deleted_at.is_(None))
    if status:
        stmt = stmt.where(Debt.status == status)
    decoded = decode_time_cursor(cursor)
    if decoded:
        stmt = stmt.where(tuple_(Debt.created_at, Debt.id) < decoded)
    stmt = stmt.order_by(Debt.created_at.desc(), Debt.id.desc()).limit(limit + 1)
    rows = (await db.execute(stmt)).scalars().all()
    has_more = len(rows) > limit
    rows = rows[:limit]
    return {
        "items": [
            {
                "id": str(d.id),
                "customer_name": d.customer_name,
                "customer_phone": d.customer_phone,
                "amount_owed": str(d.amount_owed),
                "amount_paid": str(d.amount_paid),
                "remaining": str(d.amount_owed - d.amount_paid),
                "due_date": d.due_date.isoformat() if d.due_date else None,
                "status": d.status,
            }
            for d in rows
        ],
        "next_cursor": encode_cursor(rows[-1].created_at, rows[-1].id) if has_more else None,
        "has_more": has_more,
    }
