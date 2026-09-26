from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID, uuid4

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import Argon2Error, InvalidHashError

from app.core.config import settings

_ph = PasswordHasher(time_cost=3, memory_cost=64 * 1024, parallelism=4)


def hash_password(plain: str) -> str:
    return _ph.hash(plain)


def verify_password(plain: str, hashed: str) -> bool:
    # A malformed/legacy hash must read as "wrong password", not a 500.
    try:
        return _ph.verify(hashed, plain)
    except (Argon2Error, InvalidHashError, ValueError):
        return False


def issue_access_token(*, user_id: UUID, shop_id: UUID, role: str, device_id: str) -> str:
    now = datetime.now(UTC)
    payload = {
        "sub": str(user_id),
        "shop_id": str(shop_id),
        "role": role,
        "device_id": device_id,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=settings.jwt_access_ttl_min)).timestamp()),
        "typ": "access",
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm="HS256")


def issue_refresh_token(*, user_id: UUID, device_id: str) -> tuple[str, str]:
    """Returns (token, jti). Caller persists the jti hash."""
    now = datetime.now(UTC)
    jti = uuid4().hex
    payload = {
        "sub": str(user_id),
        "device_id": device_id,
        "jti": jti,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(days=settings.jwt_refresh_ttl_days)).timestamp()),
        "typ": "refresh",
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm="HS256"), jti


def issue_owner_challenge(*, user_id: UUID, shop_id: UUID) -> str:
    now = datetime.now(UTC)
    payload = {
        "sub": str(user_id),
        "shop_id": str(shop_id),
        "purpose": "owner_pin",
        "nonce": uuid4().hex,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=settings.jwt_owner_challenge_ttl_min)).timestamp()),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm="HS256")


def decode_token(token: str, *, verify_exp: bool = True) -> dict[str, Any]:
    """Try current then previous secret to support rotation windows.

    `verify_exp=False` still checks the signature; the caller then judges
    `exp` itself (the sync path accepts an owner challenge that was valid when
    the queued action happened).
    """
    secrets = [settings.jwt_secret]
    if settings.jwt_secret_previous:
        secrets.append(settings.jwt_secret_previous)
    last_err: Exception | None = None
    for s in secrets:
        try:
            return jwt.decode(
                token, s, algorithms=["HS256"], leeway=60,
                options={"verify_exp": verify_exp},
            )
        except jwt.PyJWTError as e:
            last_err = e
    raise last_err  # type: ignore[misc]
