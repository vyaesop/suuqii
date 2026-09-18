"""
Partial returns and exchanges (docs/19-boutique-shop-type.md §13.3
`sale.return`).

`sale.refund` reverses a whole sale and is kept as-is for compatibility. A
return is the per-line version: which sale items, how many, in what condition,
and how much money went back. An exchange is a return whose credit was spent
on a new sale (`exchange_sale_id`); the new sale's `discount` carries the
credit so `sales.total` stays "what the customer actually paid".

`sale_return_items` carries no shop_id — like `sale_items`, its RLS policy
joins through the parent (see migration 0013).
"""
from datetime import datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Index, Numeric, String, Text
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, new_uuid

CONDITIONS = ("resellable", "damaged")
REASONS = ("wrong_size", "defect", "changed_mind", "other")
REFUND_METHODS = ("cash", "mobile_money")


def _in(values: tuple[str, ...]) -> str:
    return ", ".join(f"'{v}'" for v in values)


class SaleReturn(Base):
    __tablename__ = "sale_returns"
    # Keep in sync with migration 0013 (tests build the schema from metadata).
    __table_args__ = (
        CheckConstraint("refund_amount >= 0", name="sale_returns_refund_amount_check"),
        CheckConstraint(
            f"refund_method IS NULL OR refund_method IN ({_in(REFUND_METHODS)})",
            name="sale_returns_refund_method_check",
        ),
        CheckConstraint(
            f"reason IS NULL OR reason IN ({_in(REASONS)})",
            name="sale_returns_reason_check",
        ),
        Index("ix_sale_returns_shop_occurred", "shop_id", "occurred_at"),
        Index("ix_sale_returns_sale", "sale_id"),
        Index("ix_sale_returns_shift", "shift_id"),
    )

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    shop_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shops.id"), nullable=False)
    sale_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("sales.id"), nullable=False)
    user_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    # The shift the cash left the till in — the *return's* shift, not the
    # original sale's, because that is whose drawer is short.
    shift_id: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shifts.id"))
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    # Money handed back. 0 for an even exchange; less than the credit when the
    # rest was spent on the replacement sale.
    refund_amount: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    refund_method: Mapped[str | None] = mapped_column(String)
    exchange_sale_id: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True), ForeignKey("sales.id"))
    reason: Mapped[str | None] = mapped_column(String)
    note: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class SaleReturnItem(Base):
    __tablename__ = "sale_return_items"
    __table_args__ = (
        CheckConstraint("quantity > 0", name="sale_return_items_quantity_check"),
        CheckConstraint(
            f"condition IN ({_in(CONDITIONS)})",
            name="sale_return_items_condition_check",
        ),
        Index("ix_sale_return_items_return", "return_id"),
        Index("ix_sale_return_items_sale_item", "sale_item_id"),
    )

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    return_id: Mapped[UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("sale_returns.id", ondelete="CASCADE"), nullable=False
    )
    sale_item_id: Mapped[UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("sale_items.id"), nullable=False
    )
    quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)
    condition: Mapped[str] = mapped_column(String, nullable=False)
    # Credited per unit: the line's unit_price with the sale-level discount
    # shared proportionally (docs/19 §13.3), quantized to cents.
    unit_price: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
