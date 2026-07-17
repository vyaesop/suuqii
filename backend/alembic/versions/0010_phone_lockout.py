"""Normalize users.phone to canonical local format + login lockout columns.

Two related auth hardening changes:

1. users.phone historically stored whatever the client sent (+2519...,
   2519..., 9..., 09...), so the same person could fail to log in — or
   register twice — depending on how they typed their number. The API now
   normalizes identity phones to `09XXXXXXXX`/`07XXXXXXXX` at the schema
   boundary (app/core/phone.py); this migration brings existing rows to the
   same canonical form. On collision (the normalized value is already used
   by another live row) the row is left unchanged and logged — a human has
   to decide which account wins, a migration must not.

2. login_attempts / login_locked_until columns back the per-account login
   brute-force lockout (5 failures → 15 min), mirroring the owner-PIN
   columns from 0002.

The normalization logic is frozen here (not imported from app.core.phone)
so the migration stays stable if the app's rules evolve.

Revision ID: 0010_phone_lockout
Revises: 0009_widen_movement_check
Create Date: 2026-07-17
"""

import logging
import re
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.engine import Connection

revision: str = "0010_phone_lockout"
down_revision: str | Sequence[str] | None = "0009_widen_movement_check"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

logger = logging.getLogger("alembic.runtime.migration")

_CANONICAL = re.compile(r"^0[97]\d{8}$")
_SEPARATORS = re.compile(r"[\s\-().]")


def _normalize(raw: str) -> str | None:
    """Canonical 09XXXXXXXX/07XXXXXXXX, or None if not normalizable."""
    cleaned = _SEPARATORS.sub("", raw)
    if cleaned.startswith("+251") and len(cleaned) == 13:
        cleaned = cleaned[4:]
    elif cleaned.startswith("251") and len(cleaned) == 12:
        cleaned = cleaned[3:]
    if len(cleaned) == 9 and cleaned[0] in "97":
        cleaned = "0" + cleaned
    return cleaned if _CANONICAL.match(cleaned) else None


def normalize_existing_phones(bind: Connection) -> None:
    """Rewrite live users.phone rows to canonical form, skipping collisions.

    The collision check is conservative: it compares against every existing
    phone (including soft-deleted rows, which still participate in the
    uq_users_shop_phone constraint), so an UPDATE can never violate either
    uniqueness rule.
    """
    all_phones = {
        r.phone for r in bind.execute(sa.text("SELECT phone FROM users"))
    }
    live_rows = bind.execute(
        sa.text("SELECT id, phone FROM users WHERE deleted_at IS NULL")
    ).all()
    for row in live_rows:
        norm = _normalize(row.phone)
        if norm is None:
            logger.warning("users.phone %r (id=%s) not normalizable — left unchanged",
                           row.phone, row.id)
            continue
        if norm == row.phone:
            continue
        if norm in all_phones:
            logger.warning("users.phone %r (id=%s) normalizes to %s which is already "
                           "taken — left unchanged", row.phone, row.id, norm)
            continue
        bind.execute(
            sa.text("UPDATE users SET phone = :phone WHERE id = :id"),
            {"phone": norm, "id": row.id},
        )
        all_phones.add(norm)


def upgrade() -> None:
    op.add_column("users", sa.Column("login_attempts", sa.Integer(), nullable=False, server_default="0"))
    op.add_column("users", sa.Column("login_locked_until", sa.DateTime(timezone=True), nullable=True))
    normalize_existing_phones(op.get_bind())


def downgrade() -> None:
    # Phone normalization is not reversed: the original formatting is gone.
    op.drop_column("users", "login_locked_until")
    op.drop_column("users", "login_attempts")
