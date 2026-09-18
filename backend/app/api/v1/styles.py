"""
Styles — the boutique pull domain (docs/19-boutique-shop-type.md §13.4).

Read-only: styles are created and edited through the sync engine
(`style.*` ops) like products. The list is paginated exactly like
`/v1/products` (keyset on `(name, id)`), carries the per-style aggregates the
grouped POS grid and the buying list need (`variant_count`, `stock_total`,
`sizes_out`), and masks cost the same way `products._dump` does.
"""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import case, func, or_, select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1._pagination import decode_cursor, encode_cursor
from app.api.v1.products import _dump as _dump_product
from app.core.capabilities import VIEW_COSTS, VIEW_PRODUCTS, can
from app.core.deps import current_user, db_session, require_cap
from app.models import Product, Style, User

router = APIRouter(prefix="/styles", tags=["styles"])


def _variant_aggregates():
    """Per-style counts over *live* variants, as a subquery to join on."""
    return (
        select(
            Product.style_id.label("style_id"),
            func.count(Product.id).label("variant_count"),
            func.coalesce(func.sum(Product.stock), 0).label("stock_total"),
            # A size run is "broken" when any variant is at/below its
            # threshold; this is the count of such variants.
            func.coalesce(
                func.sum(case((Product.stock <= Product.low_stock_threshold, 1), else_=0)), 0
            ).label("sizes_out"),
        )
        .where(Product.deleted_at.is_(None), Product.style_id.is_not(None))
        .group_by(Product.style_id)
        .subquery()
    )


def _dump(s: Style, *, show_costs: bool, variant_count=0, stock_total=0, sizes_out=0) -> dict:
    return {
        "id": str(s.id),
        "name": s.name,
        "brand": s.brand,
        "category": s.category,
        "segment": s.segment,
        "image_url": s.image_url,
        "default_selling_price": str(s.default_selling_price),
        # Cost is owner-only, like products.purchase_price.
        "default_purchase_price": str(s.default_purchase_price) if show_costs else "0",
        "size_set": s.size_set,
        "sku_prefix": s.sku_prefix,
        "client_updated_at": s.client_updated_at.isoformat() if s.client_updated_at else None,
        "variant_count": int(variant_count or 0),
        "stock_total": str(stock_total if stock_total is not None else 0),
        "sizes_out": int(sizes_out or 0),
    }


@router.get("", dependencies=[Depends(require_cap(VIEW_PRODUCTS))])
async def list_styles(
    q: str | None = Query(None),
    category: str | None = Query(None),
    segment: str | None = Query(None),
    limit: int = Query(200, ge=1, le=500),
    cursor: str | None = Query(None),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    agg = _variant_aggregates()
    stmt = (
        select(Style, agg.c.variant_count, agg.c.stock_total, agg.c.sizes_out)
        .outerjoin(agg, agg.c.style_id == Style.id)
        .where(Style.shop_id == user.shop_id, Style.deleted_at.is_(None))
    )
    if q:
        stmt = stmt.where(or_(Style.name.ilike(f"%{q}%"), Style.brand.ilike(f"%{q}%")))
    if category:
        stmt = stmt.where(Style.category == category)
    if segment:
        stmt = stmt.where(Style.segment == segment)
    decoded = decode_cursor(cursor)
    if decoded:
        stmt = stmt.where(tuple_(Style.name, Style.id) > decoded)
    stmt = stmt.order_by(Style.name, Style.id).limit(limit + 1)
    rows = (await db.execute(stmt)).all()
    has_more = len(rows) > limit
    rows = rows[:limit]
    show_costs = can(user.role, VIEW_COSTS)
    return {
        "items": [
            _dump(s, show_costs=show_costs, variant_count=vc, stock_total=st, sizes_out=so)
            for s, vc, st, so in rows
        ],
        "next_cursor": encode_cursor(rows[-1][0].name, rows[-1][0].id) if has_more else None,
        "has_more": has_more,
    }


@router.get("/{style_id}", dependencies=[Depends(require_cap(VIEW_PRODUCTS))])
async def get_style(
    style_id: UUID,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Style plus its variant matrix — the picker's fallback when the local
    mirror is stale."""
    style = await db.get(Style, style_id)
    if style is None or style.shop_id != user.shop_id or style.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "style not found")
    variants = (await db.execute(
        select(Product)
        .where(Product.style_id == style.id, Product.deleted_at.is_(None))
        .order_by(Product.color, Product.size, Product.id)
    )).scalars().all()
    show_costs = can(user.role, VIEW_COSTS)
    out = _dump(
        style, show_costs=show_costs,
        variant_count=len(variants),
        stock_total=sum((v.stock for v in variants), 0),
        sizes_out=sum(1 for v in variants if v.stock <= v.low_stock_threshold),
    )
    out["variants"] = [_dump_product(v, is_owner=show_costs) for v in variants]
    return out
