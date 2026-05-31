"""
Authentication endpoints — register shop, login, refresh, invite, owner-PIN.

This is a concise reference implementation; review and harden before launch.
"""
import asyncio
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from secrets import token_hex
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import current_user, db_session
from app.core.errors import DomainError
from app.core.rate_limit import limiter
from app.core.security import (
    decode_token,
    hash_password,
    issue_access_token,
    issue_owner_challenge,
    issue_refresh_token,
    verify_password,
)
from app.db.session import AsyncSessionLocal
from app.models import DeviceSession, Invite, Shop, User
from app.schemas.auth import (
    AcceptInviteRequest,
    InviteRequest,
    InviteResponse,
    LoginRequest,
    OwnerPinVerifyRequest,
    RefreshRequest,
    RegisterShopRequest,
    ShopUser,
    ShopUsersResponse,
    TokenBundle,
)

router = APIRouter(prefix="/auth", tags=["auth"])


# --- Owner-PIN rate limiting ---------------------------------------------
# In-memory tracker; per-process state. For multi-worker deployments this
# should be backed by Redis or a DB row. The lock is short-lived (15 min)
# and the consequence of a missed lock under multi-worker is "user gets one
# extra attempt" — acceptable for v1 but flagged for follow-up.
OWNER_PIN_MAX_ATTEMPTS = 5
OWNER_PIN_LOCK_MINUTES = 15
_owner_pin_state: dict[UUID, dict] = {}
_owner_pin_lock = asyncio.Lock()


async def _check_owner_pin_lock(user_id: UUID) -> int | None:
    """Return seconds-remaining if locked, else None."""
    async with _owner_pin_lock:
        st = _owner_pin_state.get(user_id)
        if not st:
            return None
        locked_until = st.get("locked_until")
        if not locked_until:
            return None
        now = datetime.now(UTC)
        if locked_until <= now:
            # Lock expired — reset.
            _owner_pin_state.pop(user_id, None)
            return None
        return int((locked_until - now).total_seconds())


async def _record_owner_pin_failure(user_id: UUID) -> int:
    """Increment failure count. Returns attempts remaining (0 = locked now)."""
    async with _owner_pin_lock:
        st = _owner_pin_state.setdefault(
            user_id, {"attempts": 0, "locked_until": None}
        )
        st["attempts"] += 1
        if st["attempts"] >= OWNER_PIN_MAX_ATTEMPTS:
            st["locked_until"] = datetime.now(UTC) + timedelta(
                minutes=OWNER_PIN_LOCK_MINUTES
            )
            return 0
        return OWNER_PIN_MAX_ATTEMPTS - st["attempts"]


async def _reset_owner_pin_attempts(user_id: UUID) -> None:
    async with _owner_pin_lock:
        _owner_pin_state.pop(user_id, None)


def _fp_hash(fp: str) -> str:
    return sha256(fp.encode()).hexdigest()


async def _issue_token_bundle(
    db: AsyncSession, user: User, device_fingerprint: str, device_label: str | None
) -> TokenBundle:
    access = issue_access_token(
        user_id=user.id, shop_id=user.shop_id, role=user.role, device_id=device_fingerprint
    )
    refresh, jti = issue_refresh_token(user_id=user.id, device_id=device_fingerprint)

    fp_h = _fp_hash(device_fingerprint)
    existing = (await db.execute(
        select(DeviceSession).where(
            DeviceSession.user_id == user.id,
            DeviceSession.device_fingerprint == fp_h,
        )
    )).scalar_one_or_none()
    if existing:
        existing.refresh_token_hash = sha256(refresh.encode()).hexdigest()
        existing.refresh_jti = jti
        existing.revoked_at = None
        existing.last_seen_at = datetime.now(UTC)
        if device_label:
            existing.device_label = device_label
    else:
        db.add(DeviceSession(
            user_id=user.id,
            device_label=device_label,
            device_fingerprint=fp_h,
            refresh_token_hash=sha256(refresh.encode()).hexdigest(),
            refresh_jti=jti,
            last_seen_at=datetime.now(UTC),
            created_at=datetime.now(UTC),
        ))
    return TokenBundle(
        access=access, refresh=refresh,
        user_id=user.id, shop_id=user.shop_id, role=user.role,
    )


@router.post("/register-shop", response_model=TokenBundle, status_code=201)
@limiter.limit("5/minute")
async def register_shop(request: Request, req: RegisterShopRequest) -> TokenBundle:
    async with AsyncSessionLocal() as db:
        # phone must not already exist
        existing = (await db.execute(select(User).where(User.phone == req.phone))).scalar_one_or_none()
        if existing:
            raise DomainError("phone already in use", code="phone_taken", status=409)

        shop = Shop(name=req.shop_name, phone=req.phone, locale=req.locale)
        db.add(shop)
        await db.flush()

        owner = User(
            shop_id=shop.id,
            name=req.owner_name,
            phone=req.phone,
            password_hash=hash_password(req.password),
            role="owner",
            owner_pin_hash=hash_password(req.owner_pin),
        )
        db.add(owner)
        await db.flush()

        bundle = await _issue_token_bundle(
            db,
            owner,
            device_fingerprint=req.device_fingerprint,
            device_label=req.device_label,
        )
        await db.commit()
        return bundle


@router.post("/login", response_model=TokenBundle)
@limiter.limit("10/minute")
async def login(request: Request, req: LoginRequest) -> TokenBundle:
    async with AsyncSessionLocal() as db:
        user = (await db.execute(
            select(User).where(User.phone == req.phone, User.deleted_at.is_(None))
        )).scalar_one_or_none()
        if not user or not user.is_active or not verify_password(req.password, user.password_hash):
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid credentials")
        bundle = await _issue_token_bundle(db, user, req.device_fingerprint, req.device_label)
        await db.commit()
        return bundle


@router.post("/refresh", response_model=TokenBundle)
@limiter.limit("30/minute")
async def refresh(request: Request, req: RefreshRequest) -> TokenBundle:
    try:
        payload = decode_token(req.refresh)
    except Exception as e:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid refresh") from e
    if payload.get("typ") != "refresh":
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "wrong token type")

    async with AsyncSessionLocal() as db:
        user = await db.get(User, payload["sub"])
        if not user or not user.is_active:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "user not active")

        fp_h = _fp_hash(req.device_fingerprint)
        sess = (await db.execute(
            select(DeviceSession).where(
                DeviceSession.user_id == user.id,
                DeviceSession.device_fingerprint == fp_h,
            )
        )).scalar_one_or_none()
        if not sess or sess.revoked_at is not None or sess.refresh_jti != payload["jti"]:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "session revoked or rotated")

        bundle = await _issue_token_bundle(db, user, req.device_fingerprint, sess.device_label)
        await db.commit()
        return bundle


@router.post("/invite", response_model=InviteResponse, status_code=201)
@limiter.limit("10/minute")
async def invite(
    request: Request,
    req: InviteRequest,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
) -> InviteResponse:
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    if req.role not in {"cashier"}:
        raise DomainError("unsupported role", code="bad_role")

    code = f"{uuid4().int % 100_000_000:08d}"
    placeholder = User(
        shop_id=user.shop_id, name=req.name, phone=req.phone,
        password_hash=hash_password(token_hex(16)),
        role=req.role, is_active=False,
    )
    db.add(placeholder)
    await db.flush()
    expires = datetime.now(UTC) + timedelta(minutes=30)
    db.add(Invite(
        shop_id=user.shop_id, user_id=placeholder.id,
        code_hash=hash_password(code), expires_at=expires,
        created_at=datetime.now(UTC),
    ))
    await db.commit()
    return InviteResponse(invite_code=code, expires_at=expires.isoformat())


@router.post("/accept-invite", response_model=TokenBundle)
@limiter.limit("10/minute")
async def accept_invite(request: Request, req: AcceptInviteRequest) -> TokenBundle:
    async with AsyncSessionLocal() as db:
        user = (await db.execute(
            select(User).where(User.phone == req.phone, User.is_active.is_(False))
        )).scalar_one_or_none()
        if not user:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no pending invite for this phone")
        invite_row = (await db.execute(
            select(Invite).where(Invite.user_id == user.id, Invite.used_at.is_(None))
            .order_by(Invite.created_at.desc()).limit(1)
        )).scalar_one_or_none()
        if not invite_row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "invite not found")
        if invite_row.expires_at < datetime.now(UTC):
            raise DomainError("invite expired", code="expired", status=410)
        if not verify_password(req.invite_code, invite_row.code_hash):
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "wrong code")

        user.password_hash = hash_password(req.password)
        user.is_active = True
        invite_row.used_at = datetime.now(UTC)

        bundle = await _issue_token_bundle(db, user, req.device_fingerprint, req.device_label)
        await db.commit()
        return bundle


@router.post("/owner-pin/verify")
@limiter.limit("5/minute")
async def verify_owner_pin(
    request: Request,
    req: OwnerPinVerifyRequest,
    response: Response,
    user: User = Depends(current_user),
):
    if user.role != "owner" or not user.owner_pin_hash:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner pin not set")

    # Refuse early if currently locked out.
    seconds_left = await _check_owner_pin_lock(user.id)
    if seconds_left is not None:
        response.headers["Retry-After"] = str(seconds_left)
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            f"too many attempts — try again in "
            f"{seconds_left // 60}m {seconds_left % 60}s",
        )

    if not verify_password(req.pin, user.owner_pin_hash):
        remaining = await _record_owner_pin_failure(user.id)
        if remaining == 0:
            response.headers["Retry-After"] = str(OWNER_PIN_LOCK_MINUTES * 60)
            raise HTTPException(
                status.HTTP_429_TOO_MANY_REQUESTS,
                f"too many wrong PINs — locked for {OWNER_PIN_LOCK_MINUTES} min",
            )
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            f"wrong pin — {remaining} attempt{'s' if remaining != 1 else ''} left",
        )

    # Success — clear any prior failures.
    await _reset_owner_pin_attempts(user.id)
    return {"ok": True, "challenge_token": issue_owner_challenge(user_id=user.id)}


@router.get("/users", response_model=ShopUsersResponse)
async def list_shop_users(
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
) -> ShopUsersResponse:
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    rows = (await db.execute(
        select(User).where(
            User.shop_id == user.shop_id,
            User.deleted_at.is_(None),
        ).order_by(User.created_at.asc())
    )).scalars().all()
    return ShopUsersResponse(
        users=[
            ShopUser(
                id=u.id,
                name=u.name,
                phone=u.phone,
                role=u.role,
                is_active=u.is_active,
                created_at=u.created_at.isoformat() if u.created_at else "",
            )
            for u in rows
        ],
    )


@router.post("/devices/{session_id}/revoke")
async def revoke_device(
    session_id: str,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    sess = await db.get(DeviceSession, session_id)
    if not sess:
        raise HTTPException(status.HTTP_404_NOT_FOUND)
    sess.revoked_at = datetime.now(UTC)
    await db.commit()
    return {"ok": True}
