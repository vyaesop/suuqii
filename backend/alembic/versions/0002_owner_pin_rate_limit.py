"""Move owner-PIN rate limiting from in-memory to DB columns.

Revision ID: 0002_owner_pin_rate_limit
Revises: 0001_initial
Create Date: 2026-05-31
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0002_owner_pin_rate_limit"
down_revision: str | Sequence[str] | None = "0001_initial"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("users", sa.Column("owner_pin_attempts", sa.Integer(), nullable=False, server_default="0"))
    op.add_column("users", sa.Column("owner_pin_locked_until", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "owner_pin_locked_until")
    op.drop_column("users", "owner_pin_attempts")
