from datetime import datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import DateTime, ForeignKey, Index, Numeric, String, func, text
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, SoftDeleteMixin, TimestampMixin, new_uuid


class Product(Base, TimestampMixin, SoftDeleteMixin):
    __tablename__ = "products"
    # Keep in sync with migration 0013. Partial unique indexes are declared on
    # the model too so the metadata-built test schema rejects the same
    # duplicates production does (a duplicate (style, size, colour) variant
    # must fail in tests, not only in prod). products_variant_uq is declared
    # below the class: it needs bound columns for its COALESCE expressions.
    __table_args__ = (
        Index(
            "products_style_idx", "style_id",
            postgresql_where=text("deleted_at IS NULL"),
        ),
        Index(
            "products_sku_uq", "shop_id", "sku", unique=True,
            postgresql_where=text("deleted_at IS NULL AND sku IS NOT NULL"),
        ),
    )

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    shop_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shops.id"), nullable=False)
    name: Mapped[str] = mapped_column(String, nullable=False)
    category: Mapped[str | None] = mapped_column(String)
    purchase_price: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    selling_price: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    stock: Mapped[Decimal] = mapped_column(Numeric(12, 3), default=Decimal("0"), nullable=False)
    low_stock_threshold: Mapped[Decimal] = mapped_column(Numeric(12, 3), default=Decimal("0"), nullable=False)
    unit: Mapped[str] = mapped_column(String, default="piece", nullable=False)
    barcode: Mapped[str | None] = mapped_column(String)
    image_url: Mapped[str | None] = mapped_column(String)
    client_updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    # Boutique variants (docs/19 §3.1). All nullable: a regular product simply
    # has no style. `name` stays the composed display name so receipts,
    # snapshots and search need no change.
    style_id: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True), ForeignKey("styles.id"))
    size: Mapped[str | None] = mapped_column(String)
    color: Mapped[str | None] = mapped_column(String)
    sku: Mapped[str | None] = mapped_column(String)
    # Haggling floor. NULL = no floor set (see the sale.create floor rule).
    min_selling_price: Mapped[Decimal | None] = mapped_column(Numeric(12, 2))


# One live variant per (style, size, colour). NULLs are distinct to a plain
# unique index, which would let two "M / no colour" variants coexist, so the
# nullable parts are coalesced to '' — the same normalisation the handlers use.
Index(
    "products_variant_uq",
    Product.style_id,
    func.coalesce(Product.size, ""),
    func.coalesce(Product.color, ""),
    unique=True,
    postgresql_where=text("deleted_at IS NULL AND style_id IS NOT NULL"),
)
