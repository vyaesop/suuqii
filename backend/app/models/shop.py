from decimal import Decimal
from uuid import UUID

from sqlalchemy import CHAR, ForeignKey, Integer, Numeric, String
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
    # regular | bakery | boutique — see app/core/shop_features.py. Validated
    # in code, not by a CHECK, so adding a type is a table entry, not a
    # migration.
    shop_type: Mapped[str] = mapped_column(String, default="regular", nullable=False)
    parent_shop_id: Mapped[UUID | None] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shops.id"))
    # Days after a sale within which staff may take a return without the
    # owner's sign-off; a later return by the owner is audited (docs/19 §13.3).
    return_window_days: Mapped[int] = mapped_column(
        Integer, default=7, server_default="7", nullable=False
    )
