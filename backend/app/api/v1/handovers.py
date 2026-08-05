"""
Handover reads (docs/18-handovers.md). Writes go through the sync engine
(`handover.create` / `handover.accept`) so they work offline.

Two audiences:
- the counter needs the pending list to know what to count;
- the owner needs the variance report to see where two staff counts disagreed.
"""
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.capabilities import HANDOVER_ACCEPT, VIEW_REPORTS, can
from app.core.deps import current_user, db_session
from app.models import Handover, HandoverItem, User
from app.models.handover import STATUS_DISPUTED, STATUS_PENDING

router = APIRouter(prefix="/handovers", tags=["handovers"])


async def _items_by_handover(
    db: AsyncSession, shop_id: UUID, handover_ids: list[UUID]
) -> dict[UUID, list[dict]]:
    if not handover_ids:
        return {}
    rows = (await db.execute(
        select(HandoverItem)
        .where(
            HandoverItem.shop_id == shop_id,
            HandoverItem.handover_id.in_(handover_ids),
        )
        .order_by(HandoverItem.product_name_snapshot)
    )).scalars().all()
    out: dict[UUID, list[dict]] = {}
    for r in rows:
        out.setdefault(r.handover_id, []).append({
            "id": str(r.id),
            "product_id": str(r.product_id),
            "product_name": r.product_name_snapshot,
            "qty_handed": str(r.qty_handed),
            "qty_received": str(r.qty_received) if r.qty_received is not None else None,
            "variance": str(r.variance) if r.variance is not None else None,
        })
    return out


def _serialize(h: Handover, items: list[dict]) -> dict:
    return {
        "id": str(h.id),
        "from_user_id": str(h.from_user_id),
        "to_user_id": str(h.to_user_id) if h.to_user_id else None,
        "accepted_by_user_id": str(h.accepted_by_user_id) if h.accepted_by_user_id else None,
        "shift_id": str(h.shift_id) if h.shift_id else None,
        "status": h.status,
        "occurred_at": h.occurred_at.isoformat(),
        "accepted_at": h.accepted_at.isoformat() if h.accepted_at else None,
        "note": h.note,
        "accept_note": h.accept_note,
        "items": items,
    }


@router.get("")
async def list_handovers(
    status_: Literal["pending", "accepted", "disputed", "all"] = Query(
        "pending", alias="status"
    ),
    limit: int = Query(50, ge=1, le=200),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Handovers for this shop, newest first.

    Anyone who can accept a handover can list them — the counter needs to see
    what is waiting. Owners can read any status; a cashier asking for `all`
    gets the same list, since nothing here is cost or revenue data.
    """
    if not (can(user.role, HANDOVER_ACCEPT) or can(user.role, VIEW_REPORTS)):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "not permitted")

    stmt = select(Handover).where(Handover.shop_id == user.shop_id)
    if status_ != "all":
        stmt = stmt.where(Handover.status == status_)
    rows = (await db.execute(
        stmt.order_by(Handover.occurred_at.desc()).limit(limit)
    )).scalars().all()

    items = await _items_by_handover(db, user.shop_id, [h.id for h in rows])
    return {
        "count": len(rows),
        "items": [_serialize(h, items.get(h.id, [])) for h in rows],
    }


@router.get("/variance-report")
async def variance_report(
    range_: Literal["7d", "30d"] = Query("30d", alias="range"),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Owner view: where the baker's count and the counter's count disagreed.

    `by_user` attributes the gap to the baker who declared it, which is the
    number that makes the control worth having — a single bad day is noise, the
    same name every week is not.
    """
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    start = datetime.now(UTC) - timedelta(days=7 if range_ == "7d" else 30)

    counts = dict((await db.execute(
        select(Handover.status, func.count())
        .where(Handover.shop_id == user.shop_id, Handover.occurred_at >= start)
        .group_by(Handover.status)
    )).all())

    # Per-baker: lines that disagreed, and the net + absolute unit gap. Net can
    # cancel out (over one day, under the next); absolute cannot, so it is the
    # honest measure of how sloppy the counting is.
    rows = (await db.execute(
        select(
            Handover.from_user_id,
            func.count(HandoverItem.id).label("lines"),
            func.coalesce(func.sum(HandoverItem.variance), 0).label("net"),
            func.coalesce(func.sum(func.abs(HandoverItem.variance)), 0).label("gross"),
        )
        .join(HandoverItem, HandoverItem.handover_id == Handover.id)
        .where(
            Handover.shop_id == user.shop_id,
            Handover.occurred_at >= start,
            HandoverItem.variance.is_not(None),
            HandoverItem.variance != 0,
        )
        .group_by(Handover.from_user_id)
        .order_by(func.coalesce(func.sum(func.abs(HandoverItem.variance)), 0).desc())
    )).all()

    disputed = (await db.execute(
        select(Handover)
        .where(
            Handover.shop_id == user.shop_id,
            Handover.occurred_at >= start,
            Handover.status == STATUS_DISPUTED,
        )
        .order_by(Handover.occurred_at.desc())
        .limit(50)
    )).scalars().all()
    disputed_items = await _items_by_handover(db, user.shop_id, [h.id for h in disputed])

    return {
        "range": range_,
        "counts_by_status": {k: v for k, v in counts.items()},
        "pending": counts.get(STATUS_PENDING, 0),
        "by_user": [
            {
                "user_id": str(r.from_user_id),
                "lines_with_variance": r.lines,
                "net_units": str(Decimal(r.net)),
                "gross_units": str(Decimal(r.gross)),
            }
            for r in rows
        ],
        "disputed": [
            _serialize(
                h,
                [
                    i for i in disputed_items.get(h.id, [])
                    if i["variance"] not in (None, "0", "0.000")
                ],
            )
            for h in disputed
        ],
    }
