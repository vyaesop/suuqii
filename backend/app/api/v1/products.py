from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_user, db_session
from app.models import Product, User

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
    stmt = stmt.order_by(Product.name).limit(limit)
    rows = (await db.execute(stmt)).scalars().all()
    is_owner = user.role == "owner"
    return {"items": [_dump(p, is_owner=is_owner) for p in rows]}


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
