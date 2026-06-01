from datetime import UTC, datetime, timedelta
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_user, db_session
from app.models import AuditLog, Shift, User
from app.services.shift_service import ShiftService

router = APIRouter(prefix="/shifts", tags=["shifts"])

# Per docs/13: shifts must be force-closeable by owner once they've been
# open longer than this. Cashiers should normally close their own shift;
# the force-close path is a recovery tool, not a routine action.
SHIFT_MAX_HOURS = 18


@router.get("")
async def list_shifts(
    from_: datetime | None = Query(None, alias="from"),
    to: datetime | None = Query(None),
    user_id: str | None = Query(None),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    stmt = select(Shift).where(Shift.shop_id == user.shop_id)
    if user.role != "owner":
        # Cashiers see only their own shifts. Attempting to query another
        # user's shifts is forbidden — explicit 403 rather than silent filter.
        if user_id and user_id != str(user.id):
            raise HTTPException(status.HTTP_403_FORBIDDEN, "cannot view another user's shifts")
        stmt = stmt.where(Shift.user_id == user.id)
    elif user_id:
        stmt = stmt.where(Shift.user_id == user_id)
    if from_:
        stmt = stmt.where(Shift.opened_at >= from_)
    if to:
        stmt = stmt.where(Shift.opened_at < to)
    stmt = stmt.order_by(Shift.opened_at.desc()).limit(200)
    rows = (await db.execute(stmt)).scalars().all()
    return {"items": [_serialize(s) for s in rows]}


def _serialize(s: Shift) -> dict:
    return {
        "id": str(s.id),
        "user_id": str(s.user_id),
        "opened_at": s.opened_at.isoformat(),
        "closed_at": s.closed_at.isoformat() if s.closed_at else None,
        "opening_cash": str(s.opening_cash),
        "declared_closing_cash": str(s.declared_closing_cash)
            if s.declared_closing_cash is not None else None,
        "expected_closing_cash": str(s.expected_closing_cash)
            if s.expected_closing_cash is not None else None,
        "note": s.note,
    }


@router.get("/open")
async def list_open_shifts(
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """All currently-open shifts in the shop. Owner-only.

    Used by the Owner's "Open shifts" screen to spot cashiers who forgot
    to close out at the end of their day.
    """
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    rows = (await db.execute(
        select(Shift).where(
            Shift.shop_id == user.shop_id,
            Shift.closed_at.is_(None),
        ).order_by(Shift.opened_at.asc())
    )).scalars().all()
    now = datetime.now(UTC)
    return {
        "items": [
            {
                **_serialize(s),
                "open_hours": round(
                    (now - s.opened_at).total_seconds() / 3600, 1
                ),
                "force_closeable": (now - s.opened_at)
                    >= timedelta(hours=SHIFT_MAX_HOURS),
            }
            for s in rows
        ],
        "force_close_threshold_hours": SHIFT_MAX_HOURS,
    }


@router.post("/{shift_id}/force-close")
async def force_close_shift(
    shift_id: UUID,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Owner-only recovery. Closes a shift the cashier didn't close.

    Sets declared = expected (zero variance — the cash count is unknown)
    and writes an audit entry so the action is traceable.
    """
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    shift = await db.get(Shift, shift_id)
    if not shift or shift.shop_id != user.shop_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "shift not found")
    if shift.closed_at is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "shift already closed")

    now = datetime.now(UTC)
    if (now - shift.opened_at) < timedelta(hours=SHIFT_MAX_HOURS):
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"shift open less than {SHIFT_MAX_HOURS}h — ask the cashier to close it",
        )

    svc = ShiftService(db, user.shop_id)
    expected = await svc.expected_cash(shift.id, shift.opening_cash)
    shift.expected_closing_cash = expected
    shift.declared_closing_cash = expected  # unknown — best we can do
    shift.closed_at = now
    shift.note = (shift.note or "") + " [force-closed by owner]"

    db.add(AuditLog(
        shop_id=user.shop_id,
        user_id=user.id,
        action="shift.force_close",
        entity_type="shift",
        entity_id=shift.id,
        old_value={"opened_at": shift.opened_at.isoformat()},
        new_value={
            "closed_at": now.isoformat(),
            "expected_closing_cash": str(expected),
            "open_hours": round(
                (now - shift.opened_at).total_seconds() / 3600, 1
            ),
        },
        note=f"Owner force-closed shift after "
             f"{round((now - shift.opened_at).total_seconds() / 3600, 1)}h",
        created_at=now,
    ))
    await db.commit()
    return _serialize(shift)
