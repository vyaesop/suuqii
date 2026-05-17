from collections.abc import AsyncIterator
from uuid import UUID

from fastapi import Depends, Header, HTTPException, Request, status
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.security import decode_token
from app.db.session import AsyncSessionLocal
from app.models.user import User


async def _open_session() -> AsyncIterator[AsyncSession]:
    async with AsyncSessionLocal() as session:
        yield session


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


async def current_user(
    payload: dict = Depends(current_token_payload),
    session: AsyncSession = Depends(db_session),
) -> User:
    user = await session.get(User, UUID(payload["sub"]))
    if user is None or not user.is_active or user.deleted_at is not None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "user not active")
    return user


def require_role(*roles: str):
    async def _dep(payload: dict = Depends(current_token_payload)) -> None:
        if payload.get("role") not in roles:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "role required: " + ",".join(roles))
    return _dep
