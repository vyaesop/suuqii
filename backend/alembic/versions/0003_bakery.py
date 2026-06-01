"""Add shop_type, supplies, and recipe_items tables.

Revision ID: 0003_bakery
Revises: 0002_owner_pin_rate_limit
Create Date: 2026-06-01
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0003_bakery"
down_revision: str | Sequence[str] | None = "0002_owner_pin_rate_limit"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "shops",
        sa.Column("shop_type", sa.String(), nullable=False, server_default="regular"),
    )

    op.create_table(
        "supplies",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("shop_id", sa.UUID(), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("unit", sa.String(), nullable=False, server_default="piece"),
        sa.Column("quantity_on_hand", sa.Numeric(12, 3), nullable=False, server_default="0"),
        sa.Column("reorder_threshold", sa.Numeric(12, 3), nullable=False, server_default="0"),
        sa.Column("cost_per_unit", sa.Numeric(12, 2), nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["shop_id"], ["shops.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_supplies_shop_id", "supplies", ["shop_id"])

    op.create_table(
        "recipe_items",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("shop_id", sa.UUID(), nullable=False),
        sa.Column("product_id", sa.UUID(), nullable=False),
        sa.Column("supply_id", sa.UUID(), nullable=False),
        sa.Column("quantity", sa.Numeric(12, 3), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["shop_id"], ["shops.id"]),
        sa.ForeignKeyConstraint(["product_id"], ["products.id"]),
        sa.ForeignKeyConstraint(["supply_id"], ["supplies.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_recipe_items_product_id", "recipe_items", ["product_id"])


def downgrade() -> None:
    op.drop_table("recipe_items")
    op.drop_table("supplies")
    op.drop_column("shops", "shop_type")
