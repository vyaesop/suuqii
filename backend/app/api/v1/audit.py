from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_user, db_session
from app.models import AuditLog, User

router = APIRouter(prefix="/audit", tags=["audit"])


@router.get("")
async def list_audit(
    from_: datetime | None = Query(None, alias="from"),
    to: datetime | None = Query(None),
    action: str | None = Query(None),
    actor: str | None = Query(None, alias="user_id"),
    entity_id: str | None = Query(None),
    limit: int = Query(100, ge=1, le=500),
    cursor: int = Query(0, ge=0),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    stmt = select(AuditLog).where(AuditLog.shop_id == user.shop_id)
    if from_:
        stmt = stmt.where(AuditLog.created_at >= from_)
    if to:
        stmt = stmt.where(AuditLog.created_at < to)
    if action:
        stmt = stmt.where(AuditLog.action == action)
    if actor:
        stmt = stmt.where(AuditLog.user_id == actor)
    if entity_id:
        stmt = stmt.where(AuditLog.entity_id == entity_id)
    stmt = stmt.order_by(AuditLog.created_at.desc()).limit(limit)
    rows = (await db.execute(stmt)).scalars().all()
    return {"items": [
        {
            "id": str(r.id),
            "action": r.action,
            "entity_type": r.entity_type,
            "entity_id": str(r.entity_id),
            "user_id": str(r.user_id) if r.user_id else None,
            "device_id": r.device_id,
            "old": r.old_value,
            "new": r.new_value,
            "created_at": r.created_at.isoformat(),
        }
        for r in rows
    ]}
