from datetime import date, datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import Date, DateTime, ForeignKey, Index, Numeric, String
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, new_uuid


class StockLot(Base):
    """A batch of stock received at one cost. See docs/16-inventory-lots.md.

    Sales consume lots FEFO (earliest expiry first, NULLs last) then FIFO by
    received_at, so per-batch margins stay separable.
    """
    __tablename__ = "stock_lots"
    __table_args__ = (
        Index("ix_stock_lots_product_open", "product_id", "expiry_date", "received_at"),
        Index("ix_stock_lots_shop_id", "shop_id"),
    )

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    shop_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shops.id"), nullable=False)
    product_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("products.id"), nullable=False)
    qty_received: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)
    qty_remaining: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)
    unit_cost: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    expiry_date: Mapped[date | None] = mapped_column(Date)
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    note: Mapped[str | None] = mapped_column(String)
    created_by: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True), ForeignKey("users.id"))


class LotConsumption(Base):
    """One draw against a lot: a sale, spoilage, adjustment, or refund reversal.

    quantity is positive for consumption; refund reversals are negative
    (stock returns to the lot it came from, keeping batch reports truthful).
    """
    __tablename__ = "lot_consumptions"
    __table_args__ = (
        Index("ix_lot_consumptions_lot_id", "lot_id"),
        Index("ix_lot_consumptions_sale_item", "sale_item_id"),
        Index("ix_lot_consumptions_shop_id", "shop_id"),
    )

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    shop_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shops.id"), nullable=False)
    lot_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("stock_lots.id"), nullable=False)
    sale_item_id: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True))
    movement: Mapped[str] = mapped_column(String, nullable=False)  # sale|spoilage|adjustment|refund_reversal
    quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)
    unit_cost: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    consumed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
