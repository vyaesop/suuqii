"""
A style is the thing a boutique owner thinks in — "Slim jeans" — and the
variants (size × colour) are ordinary `products` rows pointing back here via
`products.style_id` (docs/19-boutique-shop-type.md §2, option A).

Everything that already works per product (sales, lots, refunds, reports,
RLS) therefore works per variant with no change. What lives on the style is
the shared part: name, brand, category, image, default prices, the size set
the wizard offered, and the SKU prefix.
"""
from datetime import datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Index, Numeric, String, text
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, SoftDeleteMixin, TimestampMixin, new_uuid

SEGMENTS = ("men", "women", "kids", "unisex")
SIZE_SETS = ("letter", "numeric", "waist", "shoe_eu", "kids_age", "free", "custom")


def _in(values: tuple[str, ...]) -> str:
    return ", ".join(f"'{v}'" for v in values)


class Style(Base, TimestampMixin, SoftDeleteMixin):
    __tablename__ = "styles"
    # Keep in sync with migration 0013. Declared here too because tests build
    # the schema from metadata, not migrations (the lots-wave lesson).
    __table_args__ = (
        CheckConstraint(
            f"segment IS NULL OR segment IN ({_in(SEGMENTS)})",
            name="styles_segment_check",
        ),
        CheckConstraint(
            f"size_set IS NULL OR size_set IN ({_in(SIZE_SETS)})",
            name="styles_size_set_check",
        ),
        Index(
            "styles_shop_idx", "shop_id",
            postgresql_where=text("deleted_at IS NULL"),
        ),
    )

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    shop_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shops.id"), nullable=False)
    name: Mapped[str] = mapped_column(String, nullable=False)
    brand: Mapped[str | None] = mapped_column(String)
    category: Mapped[str | None] = mapped_column(String)
    segment: Mapped[str | None] = mapped_column(String)
    image_url: Mapped[str | None] = mapped_column(String)
    default_selling_price: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    default_purchase_price: Mapped[Decimal] = mapped_column(
        Numeric(12, 2), nullable=False, default=Decimal("0"), server_default="0"
    )
    # Preset key the wizard used, so "add missing sizes" can offer the rest;
    # NULL = custom list.
    size_set: Mapped[str | None] = mapped_column(String)
    sku_prefix: Mapped[str | None] = mapped_column(String(8))
    client_updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
