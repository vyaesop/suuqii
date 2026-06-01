"""
Supplies (ingredient inventory) endpoints — bakery shops only.
"""
from decimal import Decimal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_user, db_session
from app.models import Supply, User

router = APIRouter(prefix="/supplies", tags=["supplies"])


class SupplyOut(BaseModel):
    id: UUID
    shop_id: UUID
    name: str
    unit: str
    quantity_on_hand: Decimal
    reorder_threshold: Decimal
    cost_per_unit: Decimal

    model_config = {"from_attributes": True}


class SuppliesListOut(BaseModel):
    items: list[SupplyOut]


@router.get("", response_model=SuppliesListOut)
async def list_supplies(
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
) -> SuppliesListOut:
    rows = (await db.execute(
        select(Supply)
        .where(Supply.shop_id == user.shop_id, Supply.deleted_at.is_(None))
        .order_by(Supply.name)
    )).scalars().all()
    return SuppliesListOut(items=[SupplyOut.model_validate(r) for r in rows])
