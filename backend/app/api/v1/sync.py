from fastapi import APIRouter, Depends, Header, Query, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_device, current_user, db_session
from app.core.rate_limit import limiter
from app.models import SyncEvent, User
from app.schemas.sync import (
    SyncEventOut,
    SyncPullResponse,
    SyncPushRequest,
    SyncPushResponse,
)
from app.services.sync_service import SyncService

router = APIRouter(prefix="/sync", tags=["sync"])


@router.post("/push", response_model=SyncPushResponse)
@limiter.limit("60/minute")
async def push(
    request: Request,
    req: SyncPushRequest,
    db: AsyncSession = Depends(db_session),
    user: User = Depends(current_user),
    device_id: str = Depends(current_device),
    owner_challenge: str | None = Header(default=None, alias="X-Owner-Challenge"),
) -> SyncPushResponse:
    svc = SyncService(db, shop_id=user.shop_id, user=user, device_id=device_id,
                      owner_challenge=owner_challenge)
    results = [await svc.apply(ev) for ev in req.events]
    # Cursor is computed before commit: the applied events are already
    # flushed, and after commit the transaction-local RLS context
    # (app.current_shop_id) is gone.
    cursor = await svc.current_cursor()
    await db.commit()
    return SyncPushResponse(results=results, server_cursor=cursor)


@router.get("/pull", response_model=SyncPullResponse)
@limiter.limit("120/minute")
async def pull(
    request: Request,
    cursor: int = Query(0, ge=0),
    limit: int = Query(200, ge=1, le=500),
    device_id: str = Depends(current_device),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
) -> SyncPullResponse:
    q = (
        select(SyncEvent)
        .where(
            SyncEvent.shop_id == user.shop_id,
            SyncEvent.id > cursor,
            SyncEvent.device_id != device_id,   # don't echo own events
        )
        .order_by(SyncEvent.id.asc())
        .limit(limit + 1)
    )
    rows = (await db.execute(q)).scalars().all()
    has_more = len(rows) > limit
    rows = rows[:limit]
    events = [
        SyncEventOut(server_id=r.id, op=r.op, payload=r.payload, applied_at=r.applied_at)
        for r in rows
    ]
    next_cursor = rows[-1].id if rows else cursor
    return SyncPullResponse(events=events, next_cursor=next_cursor, has_more=has_more)
