from datetime import datetime
from decimal import Decimal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1._pagination import decode_time_cursor, encode_cursor
from app.core.capabilities import SELL, VIEW_COSTS, VIEW_REPORTS, can
from app.core.deps import current_user, db_session, require_cap
from app.models import Sale, SaleItem, SaleReturn, SaleReturnItem, User

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


async def _shop_sale(db: AsyncSession, user: User, sale_id: UUID) -> Sale:
    sale = await db.get(Sale, sale_id)
    if sale is None or sale.shop_id != user.shop_id or sale.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "sale not found")
    return sale


async def _returns_for(db: AsyncSession, sale_id: UUID) -> list[dict]:
    returns = (await db.execute(
        select(SaleReturn)
        .where(SaleReturn.sale_id == sale_id)
        .order_by(SaleReturn.occurred_at, SaleReturn.id)
    )).scalars().all()
    items_by_return: dict[UUID, list[dict]] = {r.id: [] for r in returns}
    if returns:
        rows = (await db.execute(
            select(SaleReturnItem)
            .where(SaleReturnItem.return_id.in_([r.id for r in returns]))
            # Deterministic order, so two fetches of the same sale produce
            # byte-identical lists for a client diffing against its cache.
            .order_by(SaleReturnItem.id)
        )).scalars().all()
        for it in rows:
            items_by_return[it.return_id].append({
                # The row's own id. Without it a client caching a fetched
                # sale has no key to dedupe on and mints its own, so two
                # overlapping fetches of the same uncached sale double the
                # return lines — doubling returned quantities and the
                # exchange credit that feeds the credit ratio.
                "id": str(it.id),
                "sale_item_id": str(it.sale_item_id),
                "quantity": str(it.quantity),
                "condition": it.condition,
                "unit_price": str(it.unit_price),
            })
    return [
        {
            "id": str(r.id),
            "occurred_at": r.occurred_at.isoformat(),
            "user_id": str(r.user_id),
            "shift_id": str(r.shift_id) if r.shift_id else None,
            "refund_amount": str(r.refund_amount),
            "refund_method": r.refund_method,
            "exchange_sale_id": str(r.exchange_sale_id) if r.exchange_sale_id else None,
            "reason": r.reason,
            "note": r.note,
            "items": items_by_return[r.id],
        }
        for r in returns
    ]


@router.get("/{sale_id}", dependencies=[Depends(require_cap(SELL))])
async def get_sale(
    sale_id: UUID,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """One sale with its lines and returns (docs/19 §13.4).

    This is the cross-device fallback for the return sheet: a sale rung up on
    phone A is not in phone B's local database, so B fetches the snapshot
    here before queueing a return against it.
    """
    sale = await _shop_sale(db, user, sale_id)
    items = (await db.execute(
        select(SaleItem).where(SaleItem.sale_id == sale.id).order_by(SaleItem.id)
    )).scalars().all()
    returned = dict((await db.execute(
        select(SaleReturnItem.sale_item_id, func.sum(SaleReturnItem.quantity))
        .join(SaleReturn, SaleReturn.id == SaleReturnItem.return_id)
        .where(SaleReturn.sale_id == sale.id)
        .group_by(SaleReturnItem.sale_item_id)
    )).all())
    out = {
        "id": str(sale.id),
        "shift_id": str(sale.shift_id) if sale.shift_id else None,
        "user_id": str(sale.user_id),
        "subtotal": str(sale.subtotal),
        "discount": str(sale.discount),
        "total": str(sale.total),
        "payment_method": sale.payment_method,
        "status": sale.status,
        "occurred_at": sale.occurred_at.isoformat(),
        "items": [
            {
                "id": str(i.id),
                "product_id": str(i.product_id),
                "product_name_snapshot": i.product_name_snapshot,
                "quantity": str(i.quantity),
                "unit_price": str(i.unit_price),
                "list_price": str(i.list_price) if i.list_price is not None else None,
                "returned_quantity": str(returned.get(i.id, Decimal("0"))),
            }
            for i in items
        ],
        "returns": await _returns_for(db, sale.id),
    }
    # Profit reveals purchase cost; restrict to owners.
    if can(user.role, VIEW_COSTS):
        out["profit"] = str(sale.total - sale.cost_total)
    return out


@router.get("/{sale_id}/returns", dependencies=[Depends(require_cap(SELL))])
async def list_sale_returns(
    sale_id: UUID,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    sale = await _shop_sale(db, user, sale_id)
    return {"items": await _returns_for(db, sale.id)}
