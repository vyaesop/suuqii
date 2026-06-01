from decimal import Decimal
from uuid import UUID

from sqlalchemy import ForeignKey, Numeric
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TimestampMixin, new_uuid


class RecipeItem(Base, TimestampMixin):
    """One ingredient line in a bakery product's recipe.

    `quantity` is how much of `supply_id` is consumed to produce one unit
    of `product_id`.  Deleting a product's recipe is done by removing all
    RecipeItem rows for that product_id.
    """

    __tablename__ = "recipe_items"

    id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), primary_key=True, default=new_uuid)
    shop_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("shops.id"), nullable=False)
    product_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("products.id"), nullable=False)
    supply_id: Mapped[UUID] = mapped_column(PgUUID(as_uuid=True), ForeignKey("supplies.id"), nullable=False)
    quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3), nullable=False)
