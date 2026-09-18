from datetime import datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Numeric, String
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, SoftDeleteMixin, new_uuid

# Keep in sync with migration 0013 (which widened the 0001 CHECK for
# 'partially_returned'). Declared on the model so the metadata-built test
# schema enforces the same set as production.
SALE_STATUSES = ("completed", "refunded", "voided", "partially_returned")

# Statuses whose money is (still) in the till / in revenue: a partially
# returned sale was paid in full and only the returned part left again, and
# that part is accounted for by sale_returns, not by dropping the sale.
SETTLED_STATUSES = ("completed", "partially_returned")


class Sale(Base, SoftDeleteMixin):
    __tablename__ = "sales"
    __table_args__ = (
        CheckConstraint(
            "status IN (" + ", ".join(f"'{s}'" for s in SALE_STATUSES) + ")",
            name="sales_status_check",
        ),
    )

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    shop_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shops.id"), nullable=False)
    shift_id: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shifts.id"))
    user_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    customer_id: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True))
    subtotal: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    discount: Mapped[Decimal] = mapped_column(Numeric(12, 2), default=Decimal("0"), nullable=False)
    total: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    cost_total: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    payment_method: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[str] = mapped_column(String, default="completed", nullable=False)
    device_id: Mapped[str | None] = mapped_column(String)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class SaleItem(Base):
    __tablename__ = "sale_items"

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    sale_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("sales.id", ondelete="CASCADE"), nullable=False)
    product_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("products.id"), nullable=False)
    product_name_snapshot: Mapped[str] = mapped_column(String, nullable=False)
    quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)
    unit_price: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    unit_cost: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    # Price on the tag when the line was rung up; unit_price is what was
    # charged. NULL = no discount was declared (same as unit_price). The gap
    # is what the price-leakage report measures (docs/19 §13.4).
    list_price: Mapped[Decimal | None] = mapped_column(Numeric(12, 2))
