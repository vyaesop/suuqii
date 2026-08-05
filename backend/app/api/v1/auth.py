"""
Authentication endpoints — register shop, login, refresh, invite, owner-PIN.

This is a concise reference implementation; review and harden before launch.
"""
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from secrets import token_hex
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.capabilities import BAKER, INVITABLE_ROLES
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
from app.models import AuditLog, DeviceSession, Invite, Shop, ShopMember, User
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


# --- Owner-PIN rate limiting (DB-backed) ---------------------------------
OWNER_PIN_MAX_ATTEMPTS = 5
OWNER_PIN_LOCK_MINUTES = 15


def _lock_seconds_left(locked_until: datetime | None) -> int | None:
    """Return seconds remaining in a lockout, or None if not locked."""
    if not locked_until:
        return None
    now = datetime.now(UTC)
    if locked_until.tzinfo is None:
        locked_until = locked_until.replace(tzinfo=UTC)
    if locked_until <= now:
        return None
    return int((locked_until - now).total_seconds())


def _pin_seconds_left(user: User) -> int | None:
    """Return seconds remaining in lockout, or None if not locked."""
    return _lock_seconds_left(user.owner_pin_locked_until)


async def _record_pin_failure(db: AsyncSession, user: User) -> int:
    """Increment failure count. Returns attempts remaining (0 = just locked)."""
    # If a previous lockout has expired, reset the counter first so the user
    # gets a fresh 5-attempt window rather than re-locking on the very first
    # wrong guess.
    if user.owner_pin_locked_until is not None:
        expiry = user.owner_pin_locked_until
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=UTC)
        if expiry <= datetime.now(UTC):
            user.owner_pin_attempts = 0
            user.owner_pin_locked_until = None

    user.owner_pin_attempts = (user.owner_pin_attempts or 0) + 1
    if user.owner_pin_attempts >= OWNER_PIN_MAX_ATTEMPTS:
        user.owner_pin_locked_until = datetime.now(UTC) + timedelta(minutes=OWNER_PIN_LOCK_MINUTES)
        await db.commit()
        return 0
    await db.commit()
    return OWNER_PIN_MAX_ATTEMPTS - user.owner_pin_attempts


async def _reset_pin_attempts(db: AsyncSession, user: User) -> None:
    user.owner_pin_attempts = 0
    user.owner_pin_locked_until = None
    await db.commit()


# --- Login brute-force lockout (DB-backed, per account) ------------------
# The per-IP slowapi limit is per-instance memory only (useless across
# serverless cold starts); this DB-backed per-account lockout is the real
# defense. Mirrors the owner-PIN pattern above.
LOGIN_MAX_ATTEMPTS = 5
LOGIN_LOCK_MINUTES = 15

# A real argon2 hash of a discarded random secret, verified when the phone
# doesn't match any account so "unknown phone" costs the same as "wrong
# password" — otherwise response time leaks which phones are registered.
_TIMING_DUMMY_HASH = (
    "$argon2id$v=19$m=65536,t=3,p=4$KtekJmzMbniotZuDZH9FcA"
    "$u9ZhqTKOzwhFwnpSjz5dOE8dgBlot1nTRd6zZRtAsCU"
)


async def _record_login_failure(db: AsyncSession, user: User) -> int:
    """Increment failure count. Returns attempts remaining (0 = just locked)."""
    # A previous lockout that has expired grants a fresh attempt window.
    if user.login_locked_until is not None and _lock_seconds_left(user.login_locked_until) is None:
        user.login_attempts = 0
        user.login_locked_until = None

    user.login_attempts = (user.login_attempts or 0) + 1
    if user.login_attempts >= LOGIN_MAX_ATTEMPTS:
        user.login_locked_until = datetime.now(UTC) + timedelta(minutes=LOGIN_LOCK_MINUTES)
        await db.commit()
        return 0
    await db.commit()
    return LOGIN_MAX_ATTEMPTS - user.login_attempts


def _fp_hash(fp: str) -> str:
    return sha256(fp.encode()).hexdigest()


async def _issue_token_bundle(
    db: AsyncSession, user: User, device_fingerprint: str, device_label: str | None,
    shop: Shop | None = None,
    active_shop_id: UUID | None = None,
    active_role: str | None = None,
) -> TokenBundle:
    """Mint an access/refresh pair.

    [active_shop_id]/[active_role] override the user's home shop for accounts
    that belong to more than one (see /auth/switch-shop). The token — not the
    user row — is what scopes a request.
    """
    scope_shop_id = active_shop_id or user.shop_id
    scope_role = active_role or user.role
    access = issue_access_token(
        user_id=user.id, shop_id=scope_shop_id, role=scope_role,
        device_id=device_fingerprint,
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
        existing.active_shop_id = scope_shop_id
        if device_label:
            existing.device_label = device_label
    else:
        db.add(DeviceSession(
            user_id=user.id,
            device_label=device_label,
            device_fingerprint=fp_h,
            refresh_token_hash=sha256(refresh.encode()).hexdigest(),
            refresh_jti=jti,
            active_shop_id=scope_shop_id,
            last_seen_at=datetime.now(UTC),
            created_at=datetime.now(UTC),
        ))

    # Resolve shop_type: use passed shop object, or load from DB if needed.
    resolved_shop = shop
    if resolved_shop is None:
        resolved_shop = await db.get(Shop, scope_shop_id)

    return TokenBundle(
        access=access, refresh=refresh,
        user_id=user.id, shop_id=scope_shop_id, role=scope_role,
        shop_type=resolved_shop.shop_type if resolved_shop else "regular",
        shop_name=resolved_shop.name if resolved_shop else "",
        debt_threshold=str(resolved_shop.debt_threshold)
            if resolved_shop and resolved_shop.debt_threshold is not None else "500.00",
        expense_approval_threshold=str(resolved_shop.expense_approval_threshold)
            if resolved_shop and resolved_shop.expense_approval_threshold is not None else "500.00",
    )


@router.post("/register-shop", response_model=TokenBundle, status_code=201)
@limiter.limit("5/minute")
async def register_shop(request: Request, req: RegisterShopRequest) -> TokenBundle:
    async with AsyncSessionLocal() as db:
        # phone must not already exist
        existing = (await db.execute(select(User).where(User.phone == req.phone))).scalar_one_or_none()
        if existing:
            raise DomainError("phone already in use", code="phone_taken", status=409)

        shop = Shop(name=req.shop_name, phone=req.phone, locale=req.locale, shop_type=req.shop_type)
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
        try:
            await db.flush()
        except IntegrityError as e:
            # Race with a concurrent registration using the same phone.
            raise DomainError("phone already in use", code="phone_taken", status=409) from e

        # Home shop membership. `current_user` only consults shop_members when
        # acting away from home, but the switcher lists memberships, so every
        # account needs its own row from the start.
        db.add(ShopMember(
            user_id=owner.id, shop_id=shop.id, role="owner",
            created_at=datetime.now(UTC),
        ))

        bundle = await _issue_token_bundle(
            db,
            owner,
            device_fingerprint=req.device_fingerprint,
            device_label=req.device_label,
            shop=shop,
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
        if not user or not user.is_active:
            # Burn the same argon2 work as a real verification so an
            # attacker can't tell "unknown phone" from "wrong password"
            # by timing. The 401 shape is identical too.
            verify_password(req.password, _TIMING_DUMMY_HASH)
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid credentials")

        seconds_left = _lock_seconds_left(user.login_locked_until)
        if seconds_left is not None:
            raise HTTPException(
                status.HTTP_429_TOO_MANY_REQUESTS,
                f"too many failed logins — try again in {seconds_left // 60}m {seconds_left % 60}s",
                headers={"Retry-After": str(seconds_left)},
            )

        if not verify_password(req.password, user.password_hash):
            remaining = await _record_login_failure(db, user)
            if remaining == 0:
                raise HTTPException(
                    status.HTTP_429_TOO_MANY_REQUESTS,
                    f"too many failed logins — locked for {LOGIN_LOCK_MINUTES} min",
                    headers={"Retry-After": str(LOGIN_LOCK_MINUTES * 60)},
                )
            # Don't reveal remaining attempts: unlike the PIN endpoint the
            # caller is unauthenticated, and a countdown confirms the
            # account exists.
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid credentials")

        user.login_attempts = 0
        user.login_locked_until = None
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

        # Keep the device in whichever shop it was switched to. Membership is
        # re-checked here, so revoking someone's access to a shop takes effect
        # at the next refresh rather than lingering for the token's lifetime.
        active_shop_id: UUID | None = None
        active_role: str | None = None
        if sess.active_shop_id is not None and sess.active_shop_id != user.shop_id:
            member = (await db.execute(
                select(ShopMember).where(
                    ShopMember.user_id == user.id,
                    ShopMember.shop_id == sess.active_shop_id,
                )
            )).scalar_one_or_none()
            if member is not None:
                active_shop_id = member.shop_id
                active_role = member.role

        bundle = await _issue_token_bundle(
            db, user, req.device_fingerprint, sess.device_label,
            active_shop_id=active_shop_id, active_role=active_role,
        )
        await db.commit()
        return bundle


class SwitchShopRequest(BaseModel):
    shop_id: UUID
    device_fingerprint: str


@router.post("/switch-shop", response_model=TokenBundle)
@limiter.limit("20/minute")
async def switch_shop(
    request: Request,
    req: SwitchShopRequest,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
) -> TokenBundle:
    """Re-issue this device's tokens scoped to another shop the caller belongs to.

    The client must wipe its local database afterwards: the on-device store
    holds one shop's data at a time, and mixing two shops' products and sales
    would corrupt both.
    """
    member = (await db.execute(
        select(ShopMember).where(
            ShopMember.user_id == user.id,
            ShopMember.shop_id == req.shop_id,
        )
    )).scalar_one_or_none()
    if member is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "not a member of that shop")

    shop = await db.get(Shop, req.shop_id)
    if shop is None or shop.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "shop not found")

    bundle = await _issue_token_bundle(
        db, user, req.device_fingerprint, None,
        shop=shop,
        active_shop_id=shop.id,
        active_role=member.role,
    )
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
    if req.role not in INVITABLE_ROLES:
        raise DomainError("unsupported role", code="bad_role")
    # Bakers only make sense where there is production to hand over.
    if req.role == BAKER:
        shop = await db.get(Shop, user.shop_id)
        if shop is None or shop.shop_type != "bakery":
            raise DomainError(
                "baker accounts require a bakery shop", code="bad_shop_type"
            )

    # Phone numbers are globally unique (idx_users_phone_global); surface a
    # clean 409 instead of an IntegrityError 500.
    existing_phone = (await db.execute(
        select(User).where(User.phone == req.phone)
    )).scalar_one_or_none()
    if existing_phone:
        raise DomainError("phone already in use", code="phone_taken", status=409)

    code = f"{uuid4().int % 100_000_000:08d}"
    placeholder = User(
        shop_id=user.shop_id, name=req.name, phone=req.phone,
        password_hash=hash_password(token_hex(16)),
        role=req.role, is_active=False,
    )
    db.add(placeholder)
    try:
        await db.flush()
    except IntegrityError as e:
        raise DomainError("phone already in use", code="phone_taken", status=409) from e
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
        # The invite created a placeholder user row but no membership; add it
        # now that the account is real.
        if (await db.execute(
            select(ShopMember).where(
                ShopMember.user_id == user.id, ShopMember.shop_id == user.shop_id
            )
        )).scalar_one_or_none() is None:
            db.add(ShopMember(
                user_id=user.id, shop_id=user.shop_id, role=user.role,
                created_at=datetime.now(UTC),
            ))

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
    db: AsyncSession = Depends(db_session),
):
    if user.role != "owner" or not user.owner_pin_hash:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner pin not set")

    seconds_left = _pin_seconds_left(user)
    if seconds_left is not None:
        response.headers["Retry-After"] = str(seconds_left)
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            f"too many attempts — try again in {seconds_left // 60}m {seconds_left % 60}s",
        )

    if not verify_password(req.pin, user.owner_pin_hash):
        remaining = await _record_pin_failure(db, user)
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

    await _reset_pin_attempts(db, user)
    return {"ok": True, "challenge_token": issue_owner_challenge(user_id=user.id, shop_id=user.shop_id)}


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


@router.get("/devices")
async def list_devices(
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """All device sessions for this shop's users. Owner-only — feeds the
    employees screen so stolen/old phones can be spotted and revoked."""
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    rows = (await db.execute(
        select(DeviceSession, User)
        .join(User, User.id == DeviceSession.user_id)
        .where(User.shop_id == user.shop_id)
        .order_by(DeviceSession.last_seen_at.desc().nulls_last())
    )).all()
    return {"items": [
        {
            "session_id": str(sess.id),
            "user_id": str(u.id),
            "user_name": u.name,
            "user_role": u.role,
            "device_label": sess.device_label,
            "last_seen_at": sess.last_seen_at.isoformat() if sess.last_seen_at else None,
            "created_at": sess.created_at.isoformat() if sess.created_at else None,
            "revoked": sess.revoked_at is not None,
        }
        for sess, u in rows
    ]}


async def _get_shop_employee(db: AsyncSession, owner: User, user_id: UUID) -> User:
    """Load a non-owner user of the caller's shop or raise."""
    target = await db.get(User, user_id)
    if not target or target.shop_id != owner.shop_id or target.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "user not found")
    if target.role == "owner":
        raise DomainError("cannot modify an owner account", code="forbidden", status=403)
    return target


@router.post("/users/{user_id}/deactivate")
async def deactivate_user(
    user_id: UUID,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Deactivate an employee: blocks login and all API access on the next
    request, and revokes their device sessions so refresh tokens die too."""
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    target = await _get_shop_employee(db, user, user_id)

    target.is_active = False
    now = datetime.now(UTC)
    sessions = (await db.execute(
        select(DeviceSession).where(
            DeviceSession.user_id == target.id,
            DeviceSession.revoked_at.is_(None),
        )
    )).scalars().all()
    for sess in sessions:
        sess.revoked_at = now

    db.add(AuditLog(
        shop_id=user.shop_id,
        user_id=user.id,
        action="user.deactivate",
        entity_type="user",
        entity_id=target.id,
        old_value={"is_active": True},
        new_value={"is_active": False, "sessions_revoked": len(sessions)},
        created_at=now,
    ))
    await db.commit()
    return {"ok": True, "sessions_revoked": len(sessions)}


@router.post("/users/{user_id}/activate")
async def activate_user(
    user_id: UUID,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """Reactivate a previously deactivated employee (they log in fresh)."""
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    target = await _get_shop_employee(db, user, user_id)

    target.is_active = True
    db.add(AuditLog(
        shop_id=user.shop_id,
        user_id=user.id,
        action="user.activate",
        entity_type="user",
        entity_id=target.id,
        old_value={"is_active": False},
        new_value={"is_active": True},
        created_at=datetime.now(UTC),
    ))
    await db.commit()
    return {"ok": True}


@router.post("/devices/{session_id}/revoke")
async def revoke_device(
    session_id: str,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    if user.role != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    # Scope to the caller's shop: an owner must not be able to revoke
    # device sessions belonging to users of other shops.
    sess = (await db.execute(
        select(DeviceSession)
        .join(User, User.id == DeviceSession.user_id)
        .where(
            DeviceSession.id == session_id,
            User.shop_id == user.shop_id,
        )
    )).scalar_one_or_none()
    if not sess:
        raise HTTPException(status.HTTP_404_NOT_FOUND)
    sess.revoked_at = datetime.now(UTC)
    await db.commit()
    return {"ok": True}
