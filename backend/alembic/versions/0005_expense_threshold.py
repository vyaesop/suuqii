"""Add expense_approval_threshold to shops.

Cashiers can create expenses below this threshold without owner PIN.
Above it, owner PIN is required — same model as debt_threshold for credit sales.

Revision ID: 0005_expense_threshold
Revises: 0004_recipe_unit_drop_sale_item_fk
Create Date: 2026-06-07
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0005_expense_threshold"
down_revision: str | Sequence[str] | None = "0004_recipe_unit_drop_sale_item_fk"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "shops",
        sa.Column(
            "expense_approval_threshold",
            sa.Numeric(12, 2),
            nullable=False,
            server_default="500.00",
        ),
    )


def downgrade() -> None:
    op.drop_column("shops", "expense_approval_threshold")
