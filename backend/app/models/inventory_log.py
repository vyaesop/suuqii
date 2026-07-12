from datetime import datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Numeric, String
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, new_uuid

# Keep in sync with migration 0009. Declared on the model too so schema built
# from metadata (tests) matches the migrated production schema — otherwise a
# movement the CHECK rejects passes tests and fails only in production.
_MOVEMENTS = (
    "sale", "restock", "adjustment", "refund", "waste",
    "receive", "spoilage", "production",
)


class InventoryLog(Base):
    __tablename__ = "inventory_logs"
    __table_args__ = (
        CheckConstraint(
            "movement IN (" + ", ".join(f"'{m}'" for m in _MOVEMENTS) + ")",
            name="inventory_logs_movement_check",
        ),
    )

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    shop_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shops.id"), nullable=False)
    product_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("products.id"), nullable=False)
    movement: Mapped[str] = mapped_column(String, nullable=False)
    quantity_delta: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)
    reason: Mapped[str | None] = mapped_column(String)
    reference_type: Mapped[str | None] = mapped_column(String)
    reference_id: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True))
    user_id: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True), ForeignKey("users.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
