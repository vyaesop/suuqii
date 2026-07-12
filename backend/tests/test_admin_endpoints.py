"""Employee management + shop settings endpoints (the roles-audit gap fill).

Exercises the HTTP layer with dependency overrides so no tokens are needed.
"""
from datetime import UTC, datetime
from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.core.deps import current_user, db_session
from app.main import app
from app.models import AuditLog, DeviceSession, Shop, User


@pytest.fixture
async def client(db):
    """HTTP client with the test session injected; caller sets _as_user."""
    holder = {}

    async def _db():
        yield db

    async def _user():
        return holder["user"]

    app.dependency_overrides[db_session] = _db
    app.dependency_overrides[current_user] = _user
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        c.as_user = lambda u: holder.__setitem__("user", u)  # type: ignore[attr-defined]
        yield c
    app.dependency_overrides.clear()


async def _add_session(db, user, label="Phone"):
    sess = DeviceSession(
        id=uuid4(), user_id=user.id, device_label=label,
        device_fingerprint=uuid4().hex, refresh_token_hash="h",
        refresh_jti="j", last_seen_at=datetime.now(UTC),
        created_at=datetime.now(UTC),
    )
    db.add(sess)
    await db.flush()
    return sess


async def test_owner_lists_shop_devices(client, db, shop, owner, cashier):
    await _add_session(db, cashier, "Cashier phone")
    client.as_user(owner)
    r = await client.get("/v1/auth/devices")
    assert r.status_code == 200
    items = r.json()["items"]
    assert len(items) == 1
    assert items[0]["user_name"] == "Cashier"
    assert items[0]["device_label"] == "Cashier phone"
    assert items[0]["revoked"] is False


async def test_cashier_cannot_list_devices(client, db, shop, owner, cashier):
    client.as_user(cashier)
    r = await client.get("/v1/auth/devices")
    assert r.status_code == 403


async def test_deactivate_revokes_sessions_and_audits(client, db, shop, owner, cashier):
    await _add_session(db, cashier)
    client.as_user(owner)
    r = await client.post(f"/v1/auth/users/{cashier.id}/deactivate")
    assert r.status_code == 200
    assert r.json() == {"ok": True, "sessions_revoked": 1}

    await db.refresh(cashier)
    assert cashier.is_active is False
    sess = (await db.execute(select(DeviceSession))).scalar_one()
    assert sess.revoked_at is not None
    audit = (await db.execute(
        select(AuditLog).where(AuditLog.action == "user.deactivate")
    )).scalar_one()
    assert audit.entity_id == cashier.id

    # And back again.
    r = await client.post(f"/v1/auth/users/{cashier.id}/activate")
    assert r.status_code == 200
    await db.refresh(cashier)
    assert cashier.is_active is True


async def test_deactivate_guards(client, db, shop, owner, cashier):
    # Cashier cannot deactivate anyone.
    client.as_user(cashier)
    r = await client.post(f"/v1/auth/users/{owner.id}/deactivate")
    assert r.status_code == 403

    client.as_user(owner)
    # An owner account cannot be deactivated.
    r = await client.post(f"/v1/auth/users/{owner.id}/deactivate")
    assert r.status_code == 403
    # A user from another shop is invisible (404, not 403 — no existence leak).
    other_shop = Shop(id=uuid4(), name="Other")
    db.add(other_shop)
    await db.flush()
    outsider = User(id=uuid4(), shop_id=other_shop.id, name="X", phone="+2519999",
                    password_hash="x", role="cashier", is_active=True)
    db.add(outsider)
    await db.flush()
    r = await client.post(f"/v1/auth/users/{outsider.id}/deactivate")
    assert r.status_code == 404


async def test_shop_settings_get_and_patch(client, db, shop, owner, cashier):
    client.as_user(owner)
    r = await client.get("/v1/shops/settings")
    assert r.status_code == 200
    assert r.json()["debt_threshold"] == "500.00"

    r = await client.patch("/v1/shops/settings", json={
        "debt_threshold": "1200.00",
        "expense_approval_threshold": "300.00",
    })
    assert r.status_code == 200
    body = r.json()
    assert body["debt_threshold"] == "1200.00"
    assert body["expense_approval_threshold"] == "300.00"

    audit = (await db.execute(
        select(AuditLog).where(AuditLog.action == "shop.settings_update")
    )).scalar_one()
    assert audit.new_value["debt_threshold"] == "1200.00"

    # Cashiers: read and write both forbidden.
    client.as_user(cashier)
    assert (await client.get("/v1/shops/settings")).status_code == 403
    assert (await client.patch("/v1/shops/settings", json={"debt_threshold": "1"})).status_code == 403

    # Bad values rejected.
    client.as_user(owner)
    assert (await client.patch("/v1/shops/settings", json={"debt_threshold": "-5"})).status_code == 422


async def test_token_bundle_carries_thresholds(db, shop, owner):
    from decimal import Decimal

    from app.api.v1.auth import _issue_token_bundle

    shop.debt_threshold = Decimal("750.00")
    await db.flush()
    bundle = await _issue_token_bundle(db, owner, "fp-1", "Test phone", shop=shop)
    assert bundle.debt_threshold == "750.00"
    assert bundle.expense_approval_threshold == "500.00"
