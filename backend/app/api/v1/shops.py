"""Shop settings — the owner-tunable knobs (docs/17-roles.md).

Only the thresholds and display fields are editable; shop_type is fixed at
registration (switching regular↔bakery changes inventory semantics and is
deliberately not a settings toggle).
"""
from datetime import UTC, datetime
from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_user, db_session
from app.models import AuditLog, Shop, User

router = APIRouter(prefix="/shops", tags=["shops"])

_MAX_THRESHOLD = Decimal("1000000")


class ShopSettingsOut(BaseModel):
    name: str
    currency: str
    locale: str
    shop_type: str
    debt_threshold: str
    expense_approval_threshold: str


class ShopSettingsPatch(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=120)
    locale: str | None = Field(None, pattern="^(en|om)$")
    debt_threshold: Decimal | None = Field(None, ge=0, le=_MAX_THRESHOLD)
    expense_approval_threshold: Decimal | None = Field(None, ge=0, le=_MAX_THRESHOLD)


def _serialize(shop: Shop) -> ShopSettingsOut:
    return ShopSettingsOut(
        name=shop.name,
        currency=shop.currency,
        locale=shop.locale,
        shop_type=shop.shop_type,
        debt_threshold=str(shop.debt_threshold),
        expense_approval_threshold=str(shop.expense_approval_threshold),
    )


@router.get("/settings", response_model=ShopSettingsOut)
async def get_settings(
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
) -> ShopSettingsOut:
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    shop = await db.get(Shop, user.shop_id)
    if shop is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "shop not found")
    return _serialize(shop)


@router.patch("/settings", response_model=ShopSettingsOut)
async def update_settings(
    patch: ShopSettingsPatch,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
) -> ShopSettingsOut:
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    shop = await db.get(Shop, user.shop_id)
    if shop is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "shop not found")

    changes: dict[str, dict[str, str]] = {}
    for field in ("name", "locale", "debt_threshold", "expense_approval_threshold"):
        value = getattr(patch, field)
        if value is not None and value != getattr(shop, field):
            changes[field] = {"old": str(getattr(shop, field)), "new": str(value)}
            setattr(shop, field, value)

    if changes:
        db.add(AuditLog(
            shop_id=user.shop_id,
            user_id=user.id,
            action="shop.settings_update",
            entity_type="shop",
            entity_id=shop.id,
            old_value={k: v["old"] for k, v in changes.items()},
            new_value={k: v["new"] for k, v in changes.items()},
            created_at=datetime.now(UTC),
        ))
    await db.commit()
    return _serialize(shop)
