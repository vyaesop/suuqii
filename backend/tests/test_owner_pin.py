"""Owner-PIN approval is typed on the device that needs it — usually a
cashier's (docs/07-authentication.md §E). The endpoint therefore checks the
PIN against the shop's owner, not the caller, and charges wrong guesses to
the owner's lockout counter.

register/invite/verify open their own sessions via AsyncSessionLocal;
conftest repoints DATABASE_URL at the scratch database.
"""
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.core.rate_limit import limiter
from app.core.security import decode_token
from app.main import app
from app.models import User

OWNER_PHONE = "0912345678"
CASHIER_PHONE = "0923456789"
PASSWORD = "s3cret-pass!"
OWNER_DEVICE = {"X-Device-Id": "fp-test-1"}
CASHIER_DEVICE = {"X-Device-Id": "fp-test-2"}


@pytest.fixture
async def client(db):
    limiter.reset()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c
    # Same reason as test_auth_login: the endpoints use the app's own engine.
    from app.db.session import engine as app_engine
    await app_engine.dispose()


async def _shop_with_cashier(client):
    """Registers a shop (owner PIN 4321) and onboards one cashier.
    Returns (owner token bundle, cashier auth headers)."""
    r = await client.post("/v1/auth/register-shop", json={
        "shop_name": "Suq", "owner_name": "Abdi", "phone": OWNER_PHONE,
        "password": PASSWORD, "owner_pin": "4321",
        "device_fingerprint": OWNER_DEVICE["X-Device-Id"],
    })
    assert r.status_code == 201, r.text
    owner = r.json()
    owner_headers = {"Authorization": f"Bearer {owner['access']}", **OWNER_DEVICE}

    r = await client.post("/v1/auth/invite",
                          json={"name": "Sara", "phone": CASHIER_PHONE},
                          headers=owner_headers)
    assert r.status_code == 201, r.text
    r = await client.post("/v1/auth/accept-invite", json={
        "invite_code": r.json()["invite_code"], "phone": CASHIER_PHONE,
        "password": PASSWORD, "device_fingerprint": CASHIER_DEVICE["X-Device-Id"],
    })
    assert r.status_code in (200, 201), r.text
    cashier = r.json()
    assert cashier["role"] == "cashier"
    return owner, {"Authorization": f"Bearer {cashier['access']}", **CASHIER_DEVICE}


async def test_cashier_gets_a_challenge_with_the_owners_pin(client, db):
    owner, cashier_headers = await _shop_with_cashier(client)
    r = await client.post("/v1/auth/owner-pin/verify", json={"pin": "4321"},
                          headers=cashier_headers)
    assert r.status_code == 200, r.text
    claims = decode_token(r.json()["challenge_token"])
    assert claims["purpose"] == "owner_pin"
    # The approver goes on record, not the cashier who typed for them.
    assert claims["sub"] == owner["user_id"]
    assert claims["shop_id"] == owner["shop_id"]


async def test_wrong_pin_from_a_cashier_counts_against_the_owner(client, db):
    _, cashier_headers = await _shop_with_cashier(client)
    r = await client.post("/v1/auth/owner-pin/verify", json={"pin": "0000"},
                          headers=cashier_headers)
    assert r.status_code == 401
    assert r.json()["detail"].startswith("wrong pin")
    owner_row = (await db.execute(
        select(User).where(User.phone == OWNER_PHONE)
    )).scalar_one()
    assert owner_row.owner_pin_attempts == 1


async def test_owner_still_verifies_their_own_pin(client, db):
    owner, _ = await _shop_with_cashier(client)
    r = await client.post("/v1/auth/owner-pin/verify", json={"pin": "4321"},
                          headers={"Authorization": f"Bearer {owner['access']}",
                                   **OWNER_DEVICE})
    assert r.status_code == 200, r.text
    assert decode_token(r.json()["challenge_token"])["sub"] == owner["user_id"]
