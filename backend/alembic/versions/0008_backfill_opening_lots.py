"""Backfill an opening-balance lot for pre-existing product stock.

0007 created the lot tables but did not convert existing inventory into
lots. Without this, a shop's current stock is invisible in the batch view
and FEFO would cost it at the latest purchase price instead of what was
actually paid. Create one lot per in-stock product at its current
purchase_price so existing inventory becomes "batch 1" — after which a
restock at a new price is correctly separated as "batch 2".

Idempotent: only inserts for products with stock > 0 that have no lot yet,
so re-running (or running after some lots already exist) is safe.

The tenant RLS policies allow writes when app.current_shop_id is unset
(migrations run as the table owner with no request context), so this
cross-shop INSERT..SELECT is permitted.

Revision ID: 0008_backfill_opening_lots
Revises: 0007_stock_lots
Create Date: 2026-07-12
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0008_backfill_opening_lots"
down_revision: str | Sequence[str] | None = "0007_stock_lots"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute(
        """
        INSERT INTO stock_lots
            (id, shop_id, product_id, qty_received, qty_remaining,
             unit_cost, expiry_date, received_at, note, created_by)
        SELECT gen_random_uuid(), p.shop_id, p.id, p.stock, p.stock,
               p.purchase_price, NULL, COALESCE(p.created_at, now()),
               'Opening balance', NULL
        FROM products p
        WHERE p.stock > 0
          AND p.deleted_at IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM stock_lots l WHERE l.product_id = p.id
          )
        """
    )


def downgrade() -> None:
    op.execute("DELETE FROM stock_lots WHERE note = 'Opening balance'")
