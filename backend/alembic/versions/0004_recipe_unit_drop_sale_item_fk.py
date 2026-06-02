"""Add recipe_item.unit column; drop sale_items.product_id FK for offline-first.

Dropping the product_id FK is safe because sale_items.product_name_snapshot
already preserves the product name. The product_id column is kept as a soft
analytics reference — it just no longer prevents inserting a sale item whose
product hasn't synced to the server yet.

Revision ID: 0004_recipe_unit_drop_sale_item_fk
Revises: 0003_bakery
Create Date: 2026-06-01
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0004_recipe_unit_drop_sale_item_fk"
down_revision: str | Sequence[str] | None = "0003_bakery"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Recipe unit — allows recipe quantities to be expressed in a different
    # unit than the supply (e.g. supply in kg, recipe in g).
    op.add_column(
        "recipe_items",
        sa.Column("recipe_unit", sa.String(), nullable=True),
    )

    # Drop the FK so sales can sync even when the referenced product hasn't
    # reached the server yet (common during the first offline-then-online sync).
    op.drop_constraint(
        "sale_items_product_id_fkey",
        "sale_items",
        type_="foreignkey",
    )


def downgrade() -> None:
    op.drop_column("recipe_items", "recipe_unit")
    op.create_foreign_key(
        "sale_items_product_id_fkey",
        "sale_items",
        "products",
        ["product_id"],
        ["id"],
    )
