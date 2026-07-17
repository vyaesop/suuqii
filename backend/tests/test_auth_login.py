"""Login/register hardening: phone-format equivalence, brute-force lockout,
and the uniform 401 for unknown phones.

register/login open their own sessions via AsyncSessionLocal (no dependency
to override) — conftest repoints DATABASE_URL at the scratch database, so
these tests exercise the real endpoint transaction paths and must commit
fixture rows for the endpoints to see them.
"""
from datetime import UTC, datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.core.deps import current_user, db_session
from app.core.rate_limit import limiter
from app.main import app
from app.models import User

PHONE = "0912345678"
PASSWORD = "s3cret-pass!"


@pytest.fixture
async def client(db):
    # Reset the per-IP slowapi counters: every test shares the ASGI test
    # client address, and the lockout tests alone need 8+ login calls.
    limiter.reset()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c
    # The endpoints use the app's own engine; drop its pooled connections
    # while this test's event loop is still alive, or the next test's loop
    # trips over them ("Event loop is closed").
    from app.db.session import engine as app_engine
    await app_engine.dispose()


def _register_payload(phone=PHONE, **overrides):
    payload = {
        "shop_name": "Suq",
        "owner_name": "Abdi",
        "phone": phone,
        "password": PASSWORD,
        "owner_pin": "4321",
        "device_fingerprint": "fp-test-1",
    }
    payload.update(overrides)
    return payload


def _login_payload(phone=PHONE, password=PASSWORD):
    return {"phone": phone, "password": password, "device_fingerprint": "fp-test-1"}


async def _get_user(db, phone=PHONE) -> User:
    return (await db.execute(select(User).where(User.phone == phone))).scalar_one()


async def test_register_normalizes_phone(client, db):
    r = await client.post("/v1/auth/register-shop",
                          json=_register_payload(phone="+251 91-234-5678"))
    assert r.status_code == 201
    user = await _get_user(db)
    assert user.phone == PHONE

    # The same number in another format is the same identity → 409.
    r = await client.post("/v1/auth/register-shop",
                          json=_register_payload(phone="251912345678"))
    assert r.status_code == 409
    assert r.json()["code"] == "phone_taken"


async def test_login_accepts_any_phone_format(client, db):
    assert (await client.post("/v1/auth/register-shop",
                              json=_register_payload())).status_code == 201
    for phone in ("+251912345678", "251912345678", "912345678", "09 1234 5678"):
        r = await client.post("/v1/auth/login", json=_login_payload(phone=phone))
        assert r.status_code == 200, phone
        assert r.json()["shop_name"] == "Suq"


@pytest.mark.parametrize("phone", ["0812345678", "12345", "abc", "+15550100"])
async def test_unnormalizable_phone_is_422(client, db, phone):
    assert (await client.post("/v1/auth/login",
                              json=_login_payload(phone=phone))).status_code == 422
    assert (await client.post("/v1/auth/register-shop",
                              json=_register_payload(phone=phone))).status_code == 422


async def test_unknown_phone_401_matches_wrong_password_shape(client, db):
    assert (await client.post("/v1/auth/register-shop",
                              json=_register_payload())).status_code == 201
    unknown = await client.post("/v1/auth/login",
                                json=_login_payload(phone="0977777777"))
    wrong = await client.post("/v1/auth/login",
                              json=_login_payload(password="not-the-password"))
    assert unknown.status_code == wrong.status_code == 401
    # Identical problem+json body: no signal about which phones exist.
    assert unknown.json() == wrong.json()
    assert unknown.json()["detail"] == "invalid credentials"


async def test_login_lockout_after_five_failures(client, db):
    assert (await client.post("/v1/auth/register-shop",
                              json=_register_payload())).status_code == 201
    bad = _login_payload(password="not-the-password")

    for _ in range(4):
        assert (await client.post("/v1/auth/login", json=bad)).status_code == 401

    r = await client.post("/v1/auth/login", json=bad)
    assert r.status_code == 429
    assert r.headers["Retry-After"] == "900"

    # Even the correct password is rejected while locked.
    r = await client.post("/v1/auth/login", json=_login_payload())
    assert r.status_code == 429
    assert "Retry-After" in r.headers

    # Expire the lock → correct login works and fully resets the counter.
    user = await _get_user(db)
    user.login_locked_until = datetime.now(UTC) - timedelta(seconds=1)
    await db.commit()
    r = await client.post("/v1/auth/login", json=_login_payload())
    assert r.status_code == 200
    await db.refresh(user)
    assert user.login_attempts == 0
    assert user.login_locked_until is None


async def test_login_success_resets_failure_counter(client, db):
    assert (await client.post("/v1/auth/register-shop",
                              json=_register_payload())).status_code == 201
    bad = _login_payload(password="not-the-password")
    for _ in range(2):
        assert (await client.post("/v1/auth/login", json=bad)).status_code == 401
    user = await _get_user(db)
    await db.refresh(user)
    assert user.login_attempts == 2

    assert (await client.post("/v1/auth/login", json=_login_payload())).status_code == 200
    await db.refresh(user)
    assert user.login_attempts == 0


async def test_expired_lock_grants_fresh_attempt_window(client, db):
    assert (await client.post("/v1/auth/register-shop",
                              json=_register_payload())).status_code == 201
    bad = _login_payload(password="not-the-password")
    for _ in range(4):
        await client.post("/v1/auth/login", json=bad)
    assert (await client.post("/v1/auth/login", json=bad)).status_code == 429

    user = await _get_user(db)
    user.login_locked_until = datetime.now(UTC) - timedelta(seconds=1)
    await db.commit()

    # First failure after an expired lock is 401 (fresh window), not re-lock.
    assert (await client.post("/v1/auth/login", json=bad)).status_code == 401
    await db.refresh(user)
    assert user.login_attempts == 1


async def test_invite_normalizes_phone(db, shop, owner):
    async def _db():
        yield db

    async def _user():
        return owner

    app.dependency_overrides[db_session] = _db
    app.dependency_overrides[current_user] = _user
    try:
        limiter.reset()
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            r = await c.post("/v1/auth/invite",
                             json={"name": "Chaltu", "phone": "+251 95-555-5555"})
            assert r.status_code == 201
            placeholder = (await db.execute(
                select(User).where(User.name == "Chaltu")
            )).scalar_one()
            assert placeholder.phone == "0955555555"
    finally:
        app.dependency_overrides.clear()
