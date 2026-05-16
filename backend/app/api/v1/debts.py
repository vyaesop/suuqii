from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_user, db_session
from app.models import Debt, User

router = APIRouter(prefix="/debts", tags=["debts"])


@router.get("")
async def list_debts(
    status: str | None = Query(None),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    stmt = select(Debt).where(Debt.shop_id == user.shop_id, Debt.deleted_at.is_(None))
    if status:
        stmt = stmt.where(Debt.status == status)
    stmt = stmt.order_by(Debt.created_at.desc()).limit(500)
    rows = (await db.execute(stmt)).scalars().all()
    return {"items": [
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
    ]}
