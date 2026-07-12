"""Stock lots: batch costing, spoilage, expiry (docs/16-inventory-lots.md).

- stock_lots: one row per stock receipt (quantity, unit cost, expiry).
- lot_consumptions: every draw against a lot (sale/spoilage/adjustment/
  refund reversal) so per-batch margin is exact.
- supplies.expiry_date: ingredients expire too.

Both new tables get the same forced tenant RLS as 0006.

Revision ID: 0007_stock_lots
Revises: 0006_rls_enforce
Create Date: 2026-07-11
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0007_stock_lots"
down_revision: str | Sequence[str] | None = "0006_rls_enforce"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_CTX = "NULLIF(current_setting('app.current_shop_id', true), '')"
_TENANT_PRED = f"({_CTX} IS NULL OR shop_id = {_CTX}::uuid)"


def upgrade() -> None:
    op.create_table(
        "stock_lots",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("shop_id", UUID(as_uuid=True), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("product_id", UUID(as_uuid=True), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("qty_received", sa.Numeric(12, 3), nullable=False),
        sa.Column("qty_remaining", sa.Numeric(12, 3), nullable=False),
        sa.Column("unit_cost", sa.Numeric(12, 2), nullable=False),
        sa.Column("expiry_date", sa.Date(), nullable=True),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("note", sa.String(), nullable=True),
        sa.Column("created_by", UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=True),
    )
    op.create_index(
        "ix_stock_lots_product_open", "stock_lots",
        ["product_id", "expiry_date", "received_at"],
    )
    op.create_index("ix_stock_lots_shop_id", "stock_lots", ["shop_id"])

    op.create_table(
        "lot_consumptions",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("shop_id", UUID(as_uuid=True), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("lot_id", UUID(as_uuid=True), sa.ForeignKey("stock_lots.id"), nullable=False),
        sa.Column("sale_item_id", UUID(as_uuid=True), nullable=True),
        sa.Column("movement", sa.String(), nullable=False),
        sa.Column("quantity", sa.Numeric(12, 3), nullable=False),
        sa.Column("unit_cost", sa.Numeric(12, 2), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_lot_consumptions_lot_id", "lot_consumptions", ["lot_id"])
    op.create_index("ix_lot_consumptions_sale_item", "lot_consumptions", ["sale_item_id"])
    op.create_index("ix_lot_consumptions_shop_id", "lot_consumptions", ["shop_id"])

    op.add_column("supplies", sa.Column("expiry_date", sa.Date(), nullable=True))

    for t in ("stock_lots", "lot_consumptions"):
        op.execute(f"ALTER TABLE {t} ENABLE ROW LEVEL SECURITY")
        op.execute(f"ALTER TABLE {t} FORCE ROW LEVEL SECURITY")
        op.execute(
            f"CREATE POLICY tenant_isolation ON {t} "
            f"USING {_TENANT_PRED} WITH CHECK {_TENANT_PRED}"
        )


def downgrade() -> None:
    op.drop_column("supplies", "expiry_date")
    op.drop_table("lot_consumptions")
    op.drop_table("stock_lots")
