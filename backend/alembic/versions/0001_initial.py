"""Initial schema bootstrap marker.

Revision ID: 0001_initial
Revises:
Create Date: 2026-05-16
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0001_initial"
down_revision: str | Sequence[str] | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # The fresh-database bootstrap is applied from 0001_initial.sql in env.py.
    pass


def downgrade() -> None:
    op.drop_table("sync_events")
    op.drop_table("audit_logs")
    op.drop_table("expenses")
    op.drop_table("debt_payments")
    op.drop_table("debts")
    op.drop_table("inventory_logs")
    op.drop_table("sale_items")
    op.drop_table("sales")
    op.drop_table("shifts")
    op.drop_table("products")
    op.drop_table("invites")
    op.drop_table("device_sessions")
    op.drop_table("users")
    op.drop_table("shops")
