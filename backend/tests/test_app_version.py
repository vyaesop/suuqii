"""Forced-upgrade gate: X-App-Version vs settings.min_app_version on /v1."""
import pytest
from httpx import ASGITransport, AsyncClient

from app.core.app_version import parse_semver
from app.core.config import settings
from app.core.rate_limit import limiter
from app.main import app


def test_parse_semver():
    assert parse_semver("1.2.3") == (1, 2, 3)
    assert parse_semver(" 1.2.3 ") == (1, 2, 3)
    assert parse_semver("0.0.0") == (0, 0, 0)
    for bad in ("1.2", "1.2.3.4", "a.b.c", "1.2.x", "", "-1.2.3"):
        assert parse_semver(bad) is None
    # Numeric, not lexical: 1.10.0 > 1.9.9.
    assert parse_semver("1.10.0") > parse_semver("1.9.9")


@pytest.fixture
async def client():
    limiter.reset()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c
    # /readyz touches the app's own engine; dispose its pool inside this
    # test's event loop so later tests don't inherit dead connections.
    from app.db.session import engine as app_engine
    await app_engine.dispose()


async def test_disabled_by_default(client):
    assert settings.min_app_version == ""
    r = await client.get("/v1/auth/users")
    assert r.status_code != 426  # falls through to auth (missing header → 422)


async def test_missing_or_old_version_gets_426(client, monkeypatch):
    monkeypatch.setattr(settings, "min_app_version", "1.2.3")

    r = await client.get("/v1/auth/users")
    assert r.status_code == 426
    body = r.json()
    assert body["code"] == "app_update_required"
    assert body["title"] == "UpgradeRequired"
    assert body["status"] == 426
    assert body["min_app_version"] == "1.2.3"

    for below in ("1.2.2", "1.1.9", "0.9.9"):
        r = await client.get("/v1/auth/users", headers={"X-App-Version": below})
        assert r.status_code == 426, below

    # Unparseable client version can't be trusted → 426 too.
    r = await client.get("/v1/auth/users", headers={"X-App-Version": "abc"})
    assert r.status_code == 426


async def test_equal_or_newer_version_passes(client, monkeypatch):
    monkeypatch.setattr(settings, "min_app_version", "1.9.0")
    for ok in ("1.9.0", "1.9.1", "2.0.0", "1.10.0"):  # 1.10.0 > 1.9.0 numerically
        r = await client.get("/v1/auth/users", headers={"X-App-Version": ok})
        assert r.status_code != 426, ok


async def test_health_endpoints_exempt(client, monkeypatch):
    monkeypatch.setattr(settings, "min_app_version", "1.2.3")
    assert (await client.get("/healthz")).status_code == 200
    assert (await client.get("/readyz")).status_code != 426


async def test_misconfigured_minimum_fails_open(client, monkeypatch):
    monkeypatch.setattr(settings, "min_app_version", "banana")
    r = await client.get("/v1/auth/users")
    assert r.status_code != 426
