"""Allow the new inventory movement types.

0001 constrained inventory_logs.movement to
('sale','restock','adjustment','refund','waste'). The lot engine (0007)
introduced 'receive', 'spoilage' and 'production' movements, which violate
that CHECK — so every stock receive/spoilage/production silently failed with
an integrity error on the real (migrated) schema. Widen the constraint.

Revision ID: 0009_widen_movement_check
Revises: 0008_backfill_opening_lots
Create Date: 2026-07-12
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0009_widen_movement_check"
down_revision: str | Sequence[str] | None = "0008_backfill_opening_lots"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_ALLOWED = (
    "'sale','restock','adjustment','refund','waste',"
    "'receive','spoilage','production'"
)


def upgrade() -> None:
    op.execute("ALTER TABLE inventory_logs DROP CONSTRAINT IF EXISTS inventory_logs_movement_check")
    op.execute(
        "ALTER TABLE inventory_logs ADD CONSTRAINT inventory_logs_movement_check "
        f"CHECK (movement IN ({_ALLOWED}))"
    )


def downgrade() -> None:
    op.execute("ALTER TABLE inventory_logs DROP CONSTRAINT IF EXISTS inventory_logs_movement_check")
    op.execute(
        "ALTER TABLE inventory_logs ADD CONSTRAINT inventory_logs_movement_check "
        "CHECK (movement IN ('sale','restock','adjustment','refund','waste'))"
    )
