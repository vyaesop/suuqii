"""Test fixtures.

Tests need a real Postgres (the schema uses JSONB/UUID and the sync engine's
savepoint semantics are Postgres-specific). Point TEST_DATABASE_URL at a
disposable database, e.g.:

    docker compose up -d postgres
    TEST_DATABASE_URL=postgresql+asyncpg://suuqii:suuqii@localhost:5432/suuqii pytest

Never point this at a real deployment: the schema is dropped and recreated.
"""
import os

# Must be set before anything imports app.core.config: the app's
# migration-on-first-request gate would otherwise run against whatever
# DATABASE_URL is in .env (potentially a real deployment).
os.environ.setdefault("MIGRATE_ON_START", "false")

# Point the app's own engine (app.db.session) at the scratch database too:
# the auth endpoints open sessions via AsyncSessionLocal directly (no
# dependency override possible), and .env may hold a live deployment URL —
# tests must never be able to touch it.
_test_url = os.environ.get("TEST_DATABASE_URL")
if _test_url:
    os.environ["DATABASE_URL"] = _test_url
    os.environ["DATABASE_URL_SYNC"] = _test_url.replace("+asyncpg", "")

from decimal import Decimal
from uuid import uuid4

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.db.base import Base
from app.models import Product, RecipeItem, Shop, Supply, User

TEST_DATABASE_URL = os.environ.get("TEST_DATABASE_URL")

_schema_ready = False


def pytest_collection_modifyitems(config, items):  # noqa: ARG001
    """Skip only the tests that actually need Postgres.

    Keyed on the `db` fixture rather than skipping everything, so pure unit
    tests (the capability matrix, phone normalization, semver parsing) still
    run — and still catch regressions — on a machine with no scratch database.
    """
    if TEST_DATABASE_URL is None:
        skip = pytest.mark.skip(reason="TEST_DATABASE_URL not set")
        for item in items:
            if "db" in getattr(item, "fixturenames", ()):
                item.add_marker(skip)


@pytest.fixture
async def db():
    """A session on a fresh schema; truncates all tables after each test."""
    global _schema_ready  # noqa: PLW0603
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as conn:
        if not _schema_ready:
            await conn.run_sync(Base.metadata.drop_all)
            await conn.run_sync(Base.metadata.create_all)
            _schema_ready = True

    maker = async_sessionmaker(bind=engine, expire_on_commit=False, autoflush=False)
    async with maker() as session:
        yield session
        await session.rollback()

    async with engine.begin() as conn:
        tables = ", ".join(t.name for t in reversed(Base.metadata.sorted_tables))
        await conn.execute(text(f"TRUNCATE {tables} CASCADE"))
    await engine.dispose()


@pytest.fixture
async def shop(db):
    shop = Shop(
        id=uuid4(),
        name="Test Shop",
        phone="+251900000001",
        debt_threshold=Decimal("500.00"),
        expense_approval_threshold=Decimal("500.00"),
    )
    db.add(shop)
    await db.flush()
    return shop


@pytest.fixture
async def owner(db, shop):
    user = User(
        id=uuid4(),
        shop_id=shop.id,
        name="Owner",
        phone="+251900000002",
        password_hash="x",
        role="owner",
        is_active=True,
    )
    db.add(user)
    await db.flush()
    return user


@pytest.fixture
async def cashier(db, shop):
    user = User(
        id=uuid4(),
        shop_id=shop.id,
        name="Cashier",
        phone="+251900000003",
        password_hash="x",
        role="cashier",
        is_active=True,
    )
    db.add(user)
    await db.flush()
    return user


@pytest.fixture
async def owner_bakery(db):
    """(db, bakery shop, owner, bread product, flour supply) with a recipe of
    0.5 kg flour per bread at 40/kg → 20.00 recipe cost per unit."""
    shop = Shop(id=uuid4(), name="Bakery", phone="+251900000010",
                shop_type="bakery", debt_threshold=Decimal("500.00"),
                expense_approval_threshold=Decimal("500.00"))
    db.add(shop)
    await db.flush()
    owner = User(id=uuid4(), shop_id=shop.id, name="Baker", phone="+251900000011",
                 password_hash="x", role="owner", is_active=True)
    bread = Product(id=uuid4(), shop_id=shop.id, name="Bread",
                    purchase_price=Decimal("0"), selling_price=Decimal("25.00"),
                    stock=Decimal("0"), low_stock_threshold=Decimal("0"), unit="piece")
    flour = Supply(id=uuid4(), shop_id=shop.id, name="Flour", unit="kg",
                   quantity_on_hand=Decimal("100"), reorder_threshold=Decimal("10"),
                   cost_per_unit=Decimal("40.00"))
    db.add_all([owner, bread, flour])
    await db.flush()
    db.add(RecipeItem(id=uuid4(), shop_id=shop.id, product_id=bread.id,
                      supply_id=flour.id, quantity=Decimal("0.5")))
    await db.flush()
    return db, shop, owner, bread, flour


@pytest.fixture
async def product(db, shop):
    prod = Product(
        id=uuid4(),
        shop_id=shop.id,
        name="Sugar 1kg",
        purchase_price=Decimal("80.00"),
        selling_price=Decimal("100.00"),
        stock=Decimal("50"),
        low_stock_threshold=Decimal("5"),
        unit="piece",
    )
    db.add(prod)
    await db.flush()
    return prod
