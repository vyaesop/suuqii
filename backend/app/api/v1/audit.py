from datetime import UTC, datetime, timedelta
from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_user, db_session
from app.models import AuditLog, Product, Shift, User

router = APIRouter(prefix="/audit", tags=["audit"])

# Tunables for anomaly detection. Per docs/11 — defaults chosen as
# "noticeable but not alert fatigue" for a small Ethiopian shop.
LARGE_VARIANCE_ETB = Decimal("500")
SUSPICIOUS_PRICE_DROP_PCT = Decimal("0.40")  # 40%+ drop in selling price


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


@router.post("/scan-anomalies")
async def scan_anomalies(
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Owner-triggered anomaly sweep — writes audit entries for things
    that look wrong but don't outright break the system.

    Detects:
    - `stock.negative`        — a product whose stock went below zero
    - `stock.critical`        — at or below 25% of low-stock threshold
    - `shift.variance.large`  — closed shift with |variance| ≥ 500 ETB
    - `shift.stale`           — still-open shift over 18h old

    Idempotent within a 24h window: if an identical anomaly was already
    recorded today for the same entity, we skip writing a duplicate.
    Returns the list of anomalies written so the UI can show "+N new".
    """
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    now = datetime.now(UTC)
    cutoff = now - timedelta(hours=24)
    written: list[dict] = []

    async def _emit(action: str, entity_type: str, entity_id, payload: dict):
        existing = (await db.execute(
            select(AuditLog).where(
                AuditLog.shop_id == user.shop_id,
                AuditLog.action == action,
                AuditLog.entity_id == entity_id,
                AuditLog.created_at >= cutoff,
            ).limit(1)
        )).scalar_one_or_none()
        if existing:
            return
        db.add(AuditLog(
            shop_id=user.shop_id,
            user_id=user.id,
            action=action,
            entity_type=entity_type,
            entity_id=entity_id,
            new_value=payload,
            note=payload.get("_note"),
            created_at=now,
        ))
        written.append({
            "action": action,
            "entity_id": str(entity_id),
            "payload": payload,
        })

    # 1) Negative stock
    rows = (await db.execute(
        select(Product).where(
            Product.shop_id == user.shop_id,
            Product.deleted_at.is_(None),
            Product.stock < 0,
        )
    )).scalars().all()
    for p in rows:
        await _emit(
            "stock.negative", "product", p.id,
            {"name": p.name, "stock": str(p.stock),
             "_note": f"{p.name} oversold to {p.stock}"},
        )

    # 2) Critical stock (≤ 25% of threshold)
    crit_rows = (await db.execute(
        select(Product).where(
            and_(
                Product.shop_id == user.shop_id,
                Product.deleted_at.is_(None),
                Product.stock >= 0,
                Product.low_stock_threshold > 0,
                Product.stock <= Product.low_stock_threshold * Decimal("0.25"),
            )
        )
    )).scalars().all()
    for p in crit_rows:
        await _emit(
            "stock.critical", "product", p.id,
            {"name": p.name, "stock": str(p.stock),
             "threshold": str(p.low_stock_threshold),
             "_note": f"{p.name} at {p.stock} of "
                      f"{p.low_stock_threshold} threshold"},
        )

    # 3) Large shift variances (recently-closed shifts only)
    shift_rows = (await db.execute(
        select(Shift).where(
            Shift.shop_id == user.shop_id,
            Shift.closed_at.is_not(None),
            Shift.closed_at >= cutoff,
            Shift.declared_closing_cash.is_not(None),
            Shift.expected_closing_cash.is_not(None),
        )
    )).scalars().all()
    for s in shift_rows:
        variance = (s.declared_closing_cash or Decimal(0)) - (
            s.expected_closing_cash or Decimal(0))
        if abs(variance) >= LARGE_VARIANCE_ETB:
            await _emit(
                "shift.variance.large", "shift", s.id,
                {
                    "user_id": str(s.user_id),
                    "expected": str(s.expected_closing_cash),
                    "declared": str(s.declared_closing_cash),
                    "variance": str(variance),
                    "_note": f"Shift variance {variance} ETB "
                             f"exceeds {LARGE_VARIANCE_ETB} ETB threshold",
                },
            )

    # 4) Stale open shifts
    stale_rows = (await db.execute(
        select(Shift).where(
            Shift.shop_id == user.shop_id,
            Shift.closed_at.is_(None),
            Shift.opened_at < (now - timedelta(hours=18)),
        )
    )).scalars().all()
    for s in stale_rows:
        hours = round((now - s.opened_at).total_seconds() / 3600, 1)
        await _emit(
            "shift.stale", "shift", s.id,
            {
                "user_id": str(s.user_id),
                "opened_at": s.opened_at.isoformat(),
                "open_hours": hours,
                "_note": f"Shift open {hours}h without closing",
            },
        )

    await db.commit()
    return {"written": written, "scanned_at": now.isoformat()}
