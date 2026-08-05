"""
Which shops a person may act in, and as what.

`users.shop_id` remains the account's *home* shop (it is what registration
creates and what every existing query scopes by). A membership row grants a
user access to an additional shop — the case this exists for is one owner who
runs a bakery and a regular shop and wants to switch between them without a
second login.

The active shop lives in the access token, not on the user row, so switching is
"re-issue a token for another shop you are a member of". Tenant isolation is
unchanged: RLS still keys on `app.current_shop_id`, which `db_session` stamps
from the token.
"""
from datetime import datetime
from uuid import UUID

from sqlalchemy import DateTime, ForeignKey, Index, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, new_uuid


class ShopMember(Base):
    __tablename__ = "shop_members"
    __table_args__ = (
        UniqueConstraint("user_id", "shop_id", name="uq_shop_members_user_shop"),
        Index("ix_shop_members_user", "user_id"),
        Index("ix_shop_members_shop", "shop_id"),
    )

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    user_id: Mapped[UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    shop_id: Mapped[UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("shops.id", ondelete="CASCADE"), nullable=False
    )
    # Role *in this shop*. A person could in principle be owner of one and
    # cashier in another; the token carries the role for the active shop.
    role: Mapped[str] = mapped_column(String, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
