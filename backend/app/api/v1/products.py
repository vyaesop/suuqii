from uuid import UUID

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1._pagination import decode_cursor, encode_cursor
from app.core.deps import current_user, db_session
from app.models import Product, StockLot, User

router = APIRouter(prefix="/products", tags=["products"])


@router.get("")
async def list_products(
    q: str | None = Query(None),
    category: str | None = Query(None),
    low_stock: bool = Query(False),
    limit: int = Query(200, ge=1, le=500),
    cursor: str | None = Query(None),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    stmt = select(Product).where(
        Product.shop_id == user.shop_id, Product.deleted_at.is_(None)
    )
    if q:
        stmt = stmt.where(Product.name.ilike(f"%{q}%"))
    if category:
        stmt = stmt.where(Product.category == category)
    if low_stock:
        stmt = stmt.where(Product.stock <= Product.low_stock_threshold)
    decoded = decode_cursor(cursor)
    if decoded:
        stmt = stmt.where(tuple_(Product.name, Product.id) > decoded)
    stmt = stmt.order_by(Product.name, Product.id).limit(limit + 1)
    rows = (await db.execute(stmt)).scalars().all()
    has_more = len(rows) > limit
    rows = rows[:limit]
    is_owner = user.role == "owner"
    return {
        "items": [_dump(p, is_owner=is_owner) for p in rows],
        "next_cursor": encode_cursor(rows[-1].name, rows[-1].id) if has_more else None,
        "has_more": has_more,
    }


def _dump(p: Product, *, is_owner: bool = True) -> dict:
    d: dict = {
        "id": str(p.id),
        "name": p.name,
        "category": p.category,
        "selling_price": str(p.selling_price),
        "stock": str(p.stock),
        "low_stock_threshold": str(p.low_stock_threshold),
        "unit": p.unit,
        "barcode": p.barcode,
        "image_url": p.image_url,
        "client_updated_at": p.client_updated_at.isoformat() if p.client_updated_at else None,
    }
    # Purchase price is financially sensitive; only owners see the real value.
    d["purchase_price"] = str(p.purchase_price) if is_owner else "0"
    return d


@router.get("/lots")
async def list_lots(
    product_id: UUID | None = Query(None),
    include_closed: bool = Query(False),
    limit: int = Query(500, ge=1, le=1000),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Open stock lots for local mirroring by devices (expiry badges + FEFO).

    unit_cost is financially sensitive and masked for cashiers, same as
    products.purchase_price.
    """
    stmt = select(StockLot).where(StockLot.shop_id == user.shop_id)
    if product_id:
        stmt = stmt.where(StockLot.product_id == product_id)
    if not include_closed:
        stmt = stmt.where(StockLot.qty_remaining > 0)
    stmt = stmt.order_by(StockLot.received_at.desc()).limit(limit)
    rows = (await db.execute(stmt)).scalars().all()
    is_owner = user.role == "owner"
    return {"items": [
        {
            "id": str(lot.id),
            "product_id": str(lot.product_id),
            "qty_received": str(lot.qty_received),
            "qty_remaining": str(lot.qty_remaining),
            "unit_cost": str(lot.unit_cost) if is_owner else "0",
            "expiry_date": lot.expiry_date.isoformat() if lot.expiry_date else None,
            "received_at": lot.received_at.isoformat(),
            "note": lot.note,
        }
        for lot in rows
    ]}
