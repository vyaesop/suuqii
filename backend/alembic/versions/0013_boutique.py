"""Boutique shop type: styles, variants, partial returns, line pricing.

docs/19-boutique-shop-type.md. Four changes:

1. `styles` — the shared half of a variant family. A variant itself is an
   ordinary `products` row (new nullable columns `style_id`, `size`, `color`,
   `sku`, `min_selling_price`), so sales, lots, refunds, reports and RLS keep
   working per variant with no change. Two partial unique indexes: one SKU per
   shop, one (style, COALESCE(size,''), COALESCE(colour,'')) per style — both
   over live rows only, so a soft-deleted variant does not block re-creating
   the same size, and NULL size/colour cannot be duplicated either.

2. `sale_items.list_price` — the tag price when the line was rung up;
   `unit_price` is what was charged. The gap feeds the price-leakage report.

3. `sale_returns` / `sale_return_items` — partial returns and exchanges.
   `sales.status` gains 'partially_returned'; 0001 constrained it with an
   inline CHECK (auto-named `sales_status_check`), the same landmine
   `inventory_logs.movement` was in 0009, so the CHECK is widened here.

4. `shops.return_window_days` — days after a sale within which staff may
   take a return without the owner signing off (default 7).

RLS: `styles` and `sale_returns` get the forced tenant policy from 0006.
`sale_return_items` has no shop_id and gets the join-through-parent policy
`sale_items` got in 0006.

`shop_type` itself is validated in code (app/core/shop_features.py), not by a
CHECK, so 'boutique' needs no DDL.

Revision ID: 0013_boutique
Revises: 0012_shop_members
Create Date: 2026-09-16
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

from alembic import op

revision: str = "0013_boutique"
down_revision: str | Sequence[str] | None = "0012_shop_members"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_CTX = "NULLIF(current_setting('app.current_shop_id', true), '')"
_TENANT_PRED = f"({_CTX} IS NULL OR shop_id = {_CTX}::uuid)"
_RETURN_ITEMS_PRED = (
    f"({_CTX} IS NULL OR EXISTS ("
    "SELECT 1 FROM sale_returns WHERE sale_returns.id = sale_return_items.return_id "
    f"AND sale_returns.shop_id = {_CTX}::uuid))"
)

_SALE_STATUS_CHECK = "sales_status_check"
_OLD_STATUSES = "'completed','refunded','voided'"
_NEW_STATUSES = _OLD_STATUSES + ",'partially_returned'"


def upgrade() -> None:
    # ---- 1. styles + variant columns ----
    op.create_table(
        "styles",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("shop_id", UUID(as_uuid=True), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("brand", sa.String(), nullable=True),
        sa.Column("category", sa.String(), nullable=True),
        sa.Column("segment", sa.String(), nullable=True),
        sa.Column("image_url", sa.String(), nullable=True),
        sa.Column("default_selling_price", sa.Numeric(12, 2), nullable=False),
        sa.Column(
            "default_purchase_price", sa.Numeric(12, 2), nullable=False, server_default="0",
        ),
        sa.Column("size_set", sa.String(), nullable=True),
        sa.Column("sku_prefix", sa.String(8), nullable=True),
        sa.Column("client_updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "segment IS NULL OR segment IN ('men', 'women', 'kids', 'unisex')",
            name="styles_segment_check",
        ),
        sa.CheckConstraint(
            "size_set IS NULL OR size_set IN "
            "('letter', 'numeric', 'waist', 'shoe_eu', 'kids_age', 'free', 'custom')",
            name="styles_size_set_check",
        ),
    )
    op.create_index(
        "styles_shop_idx", "styles", ["shop_id"],
        postgresql_where=sa.text("deleted_at IS NULL"),
    )

    op.add_column(
        "products",
        sa.Column("style_id", UUID(as_uuid=True), sa.ForeignKey("styles.id"), nullable=True),
    )
    op.add_column("products", sa.Column("size", sa.String(), nullable=True))
    op.add_column("products", sa.Column("color", sa.String(), nullable=True))
    op.add_column("products", sa.Column("sku", sa.String(), nullable=True))
    op.add_column("products", sa.Column("min_selling_price", sa.Numeric(12, 2), nullable=True))
    op.create_index(
        "products_style_idx", "products", ["style_id"],
        postgresql_where=sa.text("deleted_at IS NULL"),
    )
    op.create_index(
        "products_sku_uq", "products", ["shop_id", "sku"], unique=True,
        postgresql_where=sa.text("deleted_at IS NULL AND sku IS NOT NULL"),
    )
    # NULL size/colour would be distinct to a plain unique index; coalesce so
    # two "M / no colour" variants of one style cannot both be live.
    op.create_index(
        "products_variant_uq", "products",
        ["style_id", sa.text("COALESCE(size, '')"), sa.text("COALESCE(color, '')")],
        unique=True,
        postgresql_where=sa.text("deleted_at IS NULL AND style_id IS NOT NULL"),
    )

    # ---- 2. line pricing ----
    op.add_column("sale_items", sa.Column("list_price", sa.Numeric(12, 2), nullable=True))

    # ---- 3. returns ----
    op.execute(f"ALTER TABLE sales DROP CONSTRAINT IF EXISTS {_SALE_STATUS_CHECK}")
    op.create_check_constraint(
        _SALE_STATUS_CHECK, "sales", f"status IN ({_NEW_STATUSES})"
    )

    op.create_table(
        "sale_returns",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("shop_id", UUID(as_uuid=True), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("sale_id", UUID(as_uuid=True), sa.ForeignKey("sales.id"), nullable=False),
        sa.Column("user_id", UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("shift_id", UUID(as_uuid=True), sa.ForeignKey("shifts.id"), nullable=True),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("refund_amount", sa.Numeric(12, 2), nullable=False),
        sa.Column("refund_method", sa.String(), nullable=True),
        sa.Column(
            "exchange_sale_id", UUID(as_uuid=True), sa.ForeignKey("sales.id"), nullable=True,
        ),
        sa.Column("reason", sa.String(), nullable=True),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("refund_amount >= 0", name="sale_returns_refund_amount_check"),
        sa.CheckConstraint(
            "refund_method IS NULL OR refund_method IN ('cash', 'mobile_money')",
            name="sale_returns_refund_method_check",
        ),
        sa.CheckConstraint(
            "reason IS NULL OR reason IN ('wrong_size', 'defect', 'changed_mind', 'other')",
            name="sale_returns_reason_check",
        ),
    )
    op.create_index("ix_sale_returns_shop_occurred", "sale_returns", ["shop_id", "occurred_at"])
    op.create_index("ix_sale_returns_sale", "sale_returns", ["sale_id"])
    op.create_index("ix_sale_returns_shift", "sale_returns", ["shift_id"])

    op.create_table(
        "sale_return_items",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "return_id", UUID(as_uuid=True),
            sa.ForeignKey("sale_returns.id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column(
            "sale_item_id", UUID(as_uuid=True), sa.ForeignKey("sale_items.id"), nullable=False,
        ),
        sa.Column("quantity", sa.Numeric(12, 3), nullable=False),
        sa.Column("condition", sa.String(), nullable=False),
        sa.Column("unit_price", sa.Numeric(12, 2), nullable=False),
        sa.CheckConstraint("quantity > 0", name="sale_return_items_quantity_check"),
        sa.CheckConstraint(
            "condition IN ('resellable', 'damaged')",
            name="sale_return_items_condition_check",
        ),
    )
    op.create_index("ix_sale_return_items_return", "sale_return_items", ["return_id"])
    op.create_index("ix_sale_return_items_sale_item", "sale_return_items", ["sale_item_id"])

    # ---- 4. return window ----
    op.add_column(
        "shops",
        sa.Column("return_window_days", sa.Integer(), nullable=False, server_default="7"),
    )

    # ---- RLS (0006 shape) ----
    for t in ("styles", "sale_returns"):
        op.execute(f"ALTER TABLE {t} ENABLE ROW LEVEL SECURITY")
        op.execute(f"ALTER TABLE {t} FORCE ROW LEVEL SECURITY")
        op.execute(
            f"CREATE POLICY tenant_isolation ON {t} "
            f"USING {_TENANT_PRED} WITH CHECK {_TENANT_PRED}"
        )
    op.execute("ALTER TABLE sale_return_items ENABLE ROW LEVEL SECURITY")
    op.execute("ALTER TABLE sale_return_items FORCE ROW LEVEL SECURITY")
    op.execute(
        "CREATE POLICY tenant_isolation ON sale_return_items "
        f"USING {_RETURN_ITEMS_PRED} WITH CHECK {_RETURN_ITEMS_PRED}"
    )


def downgrade() -> None:
    op.drop_column("shops", "return_window_days")
    op.drop_table("sale_return_items")
    op.drop_table("sale_returns")
    # A partially returned sale was paid in full; 'completed' is the closest
    # meaning the narrower CHECK can express.
    op.execute("UPDATE sales SET status = 'completed' WHERE status = 'partially_returned'")
    op.execute(f"ALTER TABLE sales DROP CONSTRAINT IF EXISTS {_SALE_STATUS_CHECK}")
    op.create_check_constraint(
        _SALE_STATUS_CHECK, "sales", f"status IN ({_OLD_STATUSES})"
    )
    op.drop_column("sale_items", "list_price")
    op.drop_index("products_variant_uq", table_name="products")
    op.drop_index("products_sku_uq", table_name="products")
    op.drop_index("products_style_idx", table_name="products")
    op.drop_column("products", "min_selling_price")
    op.drop_column("products", "sku")
    op.drop_column("products", "color")
    op.drop_column("products", "size")
    op.drop_column("products", "style_id")
    op.drop_table("styles")
