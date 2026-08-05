"""Shop settings and multi-shop membership (docs/17-roles.md, docs/19-multi-shop.md).

Only the thresholds and display fields are editable; shop_type is fixed at
registration (switching regular↔bakery changes inventory semantics and is
deliberately not a settings toggle) — an owner who runs both keeps two shops and
switches between them instead.
"""
from datetime import UTC, datetime
from decimal import Decimal
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.capabilities import ADMIN, OWNER, can
from app.core.deps import current_user, db_session
from app.models import AuditLog, Shop, ShopMember, User

router = APIRouter(prefix="/shops", tags=["shops"])

_MAX_THRESHOLD = Decimal("1000000")

# One person running a handful of outlets is the case this supports; a chain is
# not. The cap keeps the switcher a short list and bounds the blast radius if an
# account is ever compromised.
_MAX_SHOPS_PER_OWNER = 10


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


class ShopSummary(BaseModel):
    id: str
    name: str
    shop_type: str
    currency: str
    role: str
    is_active: bool


class MyShopsResponse(BaseModel):
    active_shop_id: str
    shops: list[ShopSummary]


class CreateShopRequest(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    shop_type: str = Field("regular", pattern="^(regular|bakery)$")
    locale: str = Field("en", pattern="^(en|am|om)$")


@router.get("/mine", response_model=MyShopsResponse)
async def my_shops(
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
) -> MyShopsResponse:
    """Shops this account may act in, for the switcher.

    Available to every role — a cashier simply sees one entry. `is_active`
    marks the shop the current token is scoped to.
    """
    rows = (await db.execute(
        select(ShopMember, Shop)
        .join(Shop, Shop.id == ShopMember.shop_id)
        .where(ShopMember.user_id == user.id, Shop.deleted_at.is_(None))
        .order_by(Shop.name)
    )).all()
    return MyShopsResponse(
        active_shop_id=str(user.shop_id),
        shops=[
            ShopSummary(
                id=str(shop.id),
                name=shop.name,
                shop_type=shop.shop_type,
                currency=shop.currency,
                role=member.role,
                is_active=shop.id == user.shop_id,
            )
            for member, shop in rows
        ],
    )


@router.post("", response_model=ShopSummary, status_code=201)
async def create_shop(
    req: CreateShopRequest,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
) -> ShopSummary:
    """Open a second shop under the same account — e.g. a bakery alongside a
    regular shop.

    Owner-only, and the caller becomes owner of the new shop. Nothing is copied
    across: products, staff and stock are per-shop, which is the point.
    """
    if not can(user.role, ADMIN):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    owned = (await db.execute(
        select(func.count())
        .select_from(ShopMember)
        .where(ShopMember.user_id == user.id, ShopMember.role == OWNER)
    )).scalar_one()
    if owned >= _MAX_SHOPS_PER_OWNER:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"an account may own at most {_MAX_SHOPS_PER_OWNER} shops",
        )

    shop = Shop(
        id=uuid4(),
        name=req.name,
        phone=None,
        locale=req.locale,
        shop_type=req.shop_type,
        debt_threshold=Decimal("500.00"),
        expense_approval_threshold=Decimal("500.00"),
    )
    db.add(shop)
    await db.flush()
    db.add(ShopMember(
        id=uuid4(),
        user_id=user.id,
        shop_id=shop.id,
        role=OWNER,
        created_at=datetime.now(UTC),
    ))
    # Logged against the shop the owner was acting in, not the new one: that is
    # where the action happened, and audit_logs' RLS WITH CHECK would reject a
    # row for a shop that is not the request's active tenant anyway.
    db.add(AuditLog(
        shop_id=user.shop_id,
        user_id=user.id,
        action="shop.create",
        entity_type="shop",
        entity_id=shop.id,
        new_value={"name": shop.name, "shop_type": shop.shop_type},
        created_at=datetime.now(UTC),
    ))
    await db.commit()
    return ShopSummary(
        id=str(shop.id),
        name=shop.name,
        shop_type=shop.shop_type,
        currency=shop.currency,
        role=OWNER,
        is_active=False,
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
