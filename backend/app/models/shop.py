from decimal import Decimal
from uuid import UUID

from sqlalchemy import CHAR, ForeignKey, Numeric, String
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, SoftDeleteMixin, TimestampMixin, new_uuid


class Shop(Base, TimestampMixin, SoftDeleteMixin):
    __tablename__ = "shops"

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    name: Mapped[str] = mapped_column(String, nullable=False)
    phone: Mapped[str | None] = mapped_column(String)
    currency: Mapped[str] = mapped_column(CHAR(3), default="ETB", nullable=False)
    debt_threshold: Mapped[Decimal] = mapped_column(Numeric(12, 2), default=Decimal("500.00"), server_default="500.00")
    expense_approval_threshold: Mapped[Decimal] = mapped_column(Numeric(12, 2), default=Decimal("500.00"), server_default="500.00")
    locale: Mapped[str] = mapped_column(String, default="en", nullable=False)
    shop_type: Mapped[str] = mapped_column(String, default="regular", nullable=False)
    parent_shop_id: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shops.id"))
