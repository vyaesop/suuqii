"""
Baker → counter handover: two independent counts of the same transfer.

A handover moves **no stock**. Production already created the units
(`production.record` bumps product stock and opens a lot); the counter selling
them decrements it. The goods never leave the shop, so a handover that also
moved stock would double-count. What this table exists for is the *control*:
the baker declares what they handed over, whoever is on the counter declares
what they received, and the difference is attributable to two named people and
a shift instead of being absorbed silently into a leftover count.

This mirrors `Shift`, which does the same thing for cash (`opening_cash` /
`declared_closing_cash` / generated `variance`).
"""
from datetime import datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import Computed, DateTime, ForeignKey, Index, Numeric, String
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, new_uuid

STATUS_PENDING = "pending"
STATUS_ACCEPTED = "accepted"
STATUS_DISPUTED = "disputed"


class Handover(Base):
    __tablename__ = "handovers"
    __table_args__ = (
        Index("ix_handovers_shop_occurred", "shop_id", "occurred_at"),
        Index("ix_handovers_status", "shop_id", "status"),
    )

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    shop_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shops.id"), nullable=False)
    # The baker who handed the goods over.
    from_user_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    # Intended recipient, if the baker named one. Whoever actually accepts is
    # recorded separately — the person who counts is the one being held to it.
    to_user_id: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True), ForeignKey("users.id"))
    accepted_by_user_id: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True), ForeignKey("users.id"))
    # Baker's own shift, so an unexplained variance lands on a time window.
    shift_id: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shifts.id"))
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    accepted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # pending → accepted (all lines matched) | disputed (any line differed)
    status: Mapped[str] = mapped_column(String, default=STATUS_PENDING, nullable=False)
    note: Mapped[str | None] = mapped_column(String)
    accept_note: Mapped[str | None] = mapped_column(String)
    device_id: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class HandoverItem(Base):
    __tablename__ = "handover_items"
    __table_args__ = (Index("ix_handover_items_handover", "handover_id"),)

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    shop_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shops.id"), nullable=False)
    handover_id: Mapped[UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("handovers.id", ondelete="CASCADE"), nullable=False
    )
    product_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("products.id"), nullable=False)
    # Snapshot so a later rename/delete doesn't rewrite history — same reason
    # SaleItem carries one.
    product_name_snapshot: Mapped[str] = mapped_column(String, nullable=False)
    qty_handed: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)
    # NULL until the counter accepts.
    qty_received: Mapped[Decimal | None] = mapped_column(Numeric(12, 3))
    # DB-generated so the two counts can never disagree with their own
    # difference. Declared with Computed() so metadata-built schemas (tests)
    # match the migration and SQLAlchemy never tries to write it.
    variance: Mapped[Decimal | None] = mapped_column(
        Numeric(12, 3),
        Computed("qty_received - qty_handed", persisted=True),
    )
