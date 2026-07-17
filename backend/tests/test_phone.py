"""Phone normalization: the pure util and the 0010 data-migration logic."""
import importlib.util
from datetime import UTC, datetime
from pathlib import Path
from uuid import uuid4

import pytest
from sqlalchemy import select

from app.core.phone import InvalidPhoneError, normalize_phone
from app.models import Shop, User


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("+251912345678", "0912345678"),
        ("251912345678", "0912345678"),
        ("912345678", "0912345678"),
        ("+251712345678", "0712345678"),
        ("251712345678", "0712345678"),
        ("712345678", "0712345678"),
        ("0912345678", "0912345678"),
        ("0712345678", "0712345678"),
        # Separators: spaces, dashes, parens, dots.
        ("+251 91-234-5678", "0912345678"),
        ("(091) 234.56.78", "0912345678"),
        ("09 12 34 56 78", "0912345678"),
    ],
)
def test_normalize_valid(raw, expected):
    assert normalize_phone(raw) == expected


@pytest.mark.parametrize(
    "raw",
    [
        "",
        "abc",
        "0812345678",       # not a 9/7 mobile prefix
        "091234567",        # 9 digits starting 0
        "09123456789",      # 11 digits
        "12345",
        "+25191234567",     # +251 + 8 digits
        "+2519123456789",   # +251 + 10 digits
        "+251812345678",    # +251 + non-mobile prefix
        "00912345678",
        "2519123456",       # 251 prefix but wrong total length
        "+1 555 0100",
    ],
)
def test_normalize_invalid(raw):
    with pytest.raises(InvalidPhoneError):
        normalize_phone(raw)


# --- Migration 0010 data-fix logic ----------------------------------------

def _load_migration_0010():
    path = (
        Path(__file__).resolve().parents[1]
        / "alembic" / "versions" / "0010_phone_lockout.py"
    )
    spec = importlib.util.spec_from_file_location("migration_0010", path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


async def test_migration_normalizes_and_skips_collisions(db):
    mod = _load_migration_0010()
    shop = Shop(id=uuid4(), name="S")
    db.add(shop)
    await db.flush()

    def user(phone, deleted=False):
        return User(
            id=uuid4(), shop_id=shop.id, name="U", phone=phone,
            password_hash="x", role="cashier", is_active=True,
            deleted_at=datetime.now(UTC) if deleted else None,
        )

    plain = user("+251977777777")            # → 0977777777
    collider = user("+251912345678")         # collides with `taken` — skipped
    taken = user("0912345678")               # already canonical — unchanged
    dead = user("0966666666", deleted=True)  # soft-deleted rows are respected
    dead_twin = user("+251966666666")        # collides with deleted row — skipped
    garbage = user("not-a-phone")            # unnormalizable — left unchanged
    db.add_all([plain, collider, taken, dead, dead_twin, garbage])
    await db.flush()

    conn = await db.connection()
    await conn.run_sync(mod.normalize_existing_phones)

    # The migration UPDATEs raw SQL — expire the identity map so the
    # re-query below reads the new values instead of cached attributes.
    db.expire_all()
    phones = {
        u.id: u.phone
        for u in (await db.execute(select(User))).scalars()
    }
    assert phones[plain.id] == "0977777777"
    assert phones[collider.id] == "+251912345678"
    assert phones[taken.id] == "0912345678"
    assert phones[dead.id] == "0966666666"
    assert phones[dead_twin.id] == "+251966666666"
    assert phones[garbage.id] == "not-a-phone"
