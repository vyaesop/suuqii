from collections.abc import AsyncIterator
from uuid import UUID

from fastapi import Depends, Header, HTTPException, Request, status
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm.attributes import set_committed_value

from app.core.capabilities import can
from app.core.security import decode_token
from app.db.session import AsyncSessionLocal
from app.models.shop_member import ShopMember
from app.models.user import User


async def current_token_payload(
    authorization: str = Header(..., alias="Authorization"),
) -> dict:
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing bearer")
    token = authorization.split(" ", 1)[1]
    try:
        payload = decode_token(token)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid token") from e
    if payload.get("typ") != "access":
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "wrong token type")
    return payload


async def current_device(x_device_id: str = Header(..., alias="X-Device-Id")) -> str:
    return x_device_id


async def db_session(
    request: Request,
    payload: dict = Depends(current_token_payload),
    device_id: str = Depends(current_device),
) -> AsyncIterator[AsyncSession]:
    async with AsyncSessionLocal() as session:
        # Stamp session-local context for RLS + audit triggers.
        # SET LOCAL doesn't accept bind params; set_config(name, value, is_local) does.
        await session.execute(
            text("SELECT set_config('app.current_user_id', :v, true)"),
            {"v": payload["sub"]},
        )
        await session.execute(
            text("SELECT set_config('app.current_shop_id', :v, true)"),
            {"v": payload["shop_id"]},
        )
        await session.execute(
            text("SELECT set_config('app.current_device_id', :v, true)"),
            {"v": device_id},
        )
        request.state.user_id = UUID(payload["sub"])
        request.state.shop_id = UUID(payload["shop_id"])
        request.state.role = payload["role"]
        yield session


async def active_shop_id(payload: dict = Depends(current_token_payload)) -> UUID:
    """The shop this request acts in — from the token, not the user row.

    A user may belong to several shops (see app/models/shop_member.py);
    `users.shop_id` is only their home shop.
    """
    return UUID(payload["shop_id"])


async def current_user(
    payload: dict = Depends(current_token_payload),
    session: AsyncSession = Depends(db_session),
) -> User:
    user = await session.get(User, UUID(payload["sub"]))
    if user is None or not user.is_active or user.deleted_at is not None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "user not active")

    token_shop = UUID(payload["shop_id"])
    if user.shop_id != token_shop:
        # Acting in a shop other than home: prove membership before anything
        # reads `user.shop_id`. A token alone is not enough — membership can be
        # revoked after the token was issued.
        member = (await session.execute(
            select(ShopMember).where(
                ShopMember.user_id == user.id,
                ShopMember.shop_id == token_shop,
            )
        )).scalar_one_or_none()
        if member is None:
            raise HTTPException(
                status.HTTP_403_FORBIDDEN, "not a member of this shop"
            )
        # Present the active shop and its role to every downstream query, which
        # all scope by `user.shop_id`.
        #
        # `set_committed_value` writes the attribute as though it had been
        # loaded from the row, so the instance is NOT marked dirty and a later
        # flush will not UPDATE users.shop_id. Plain assignment would persist
        # the switch permanently; expunging instead would silently break the
        # owner-PIN and login lockout counters, which mutate this same attached
        # object (see api/v1/auth.py `_record_pin_failure`).
        set_committed_value(user, "shop_id", token_shop)
        set_committed_value(user, "role", member.role)
    return user


def require_role(*roles: str):
    async def _dep(payload: dict = Depends(current_token_payload)) -> None:
        if payload.get("role") not in roles:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "role required: " + ",".join(roles))
    return _dep


def require_cap(capability: str):
    """Gate a route on a capability rather than a role name.

    Prefer this over `require_role`/`role != "owner"`: capabilities deny by
    default, so a role added later gets nothing until it is granted something
    explicitly. See app/core/capabilities.py.
    """
    async def _dep(payload: dict = Depends(current_token_payload)) -> None:
        if not can(payload.get("role"), capability):
            raise HTTPException(
                status.HTTP_403_FORBIDDEN,
                f"capability required: {capability}",
            )
    return _dep
