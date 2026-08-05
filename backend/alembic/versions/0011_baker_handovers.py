"""Baker role + baker→counter handovers.

Three changes:

1. `users.role` CHECK widens to include 'baker'. The role model was binary
   ('owner','cashier') and every non-owner was effectively a cashier; roles now
   declare capabilities explicitly in app/core/capabilities.py.

2. `handovers` / `handover_items`: two independent counts of the same transfer.
   `handover_items.variance` is a STORED generated column so the two counts can
   never disagree with their own difference — same approach as
   `shifts.variance` for cash.

3. Ingredient consumption for bakery shops moves from sale time to production
   time (see 0011's companion change in sync_service._production_record).
   Flour is consumed when the dough is mixed, not when the bread sells; under
   the old timing a tray that sat unsold for a week kept its ingredients on the
   books as unused stock for that week. No data migration is possible here —
   past events were applied under the old rule — so this only affects events
   applied from here on, and `settings.min_app_version` must be raised in the
   same deploy so older clients stop sending sale-time `supply_deductions`.

Both new tables get the same forced tenant RLS as 0006.

Revision ID: 0011_baker_handovers
Revises: 0010_phone_lockout
Create Date: 2026-08-05
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0011_baker_handovers"
down_revision: str | Sequence[str] | None = "0010_phone_lockout"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_CTX = "NULLIF(current_setting('app.current_shop_id', true), '')"
_TENANT_PRED = f"({_CTX} IS NULL OR shop_id = {_CTX}::uuid)"

_ROLE_CHECK = "users_role_check"


def upgrade() -> None:
    # ---- 1. widen the role CHECK ----
    op.execute(f"ALTER TABLE users DROP CONSTRAINT IF EXISTS {_ROLE_CHECK}")
    op.create_check_constraint(
        _ROLE_CHECK, "users", "role IN ('owner','cashier','baker')"
    )

    # ---- 2. handovers ----
    op.create_table(
        "handovers",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("shop_id", UUID(as_uuid=True), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("from_user_id", UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("to_user_id", UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=True),
        sa.Column("accepted_by_user_id", UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=True),
        sa.Column("shift_id", UUID(as_uuid=True), sa.ForeignKey("shifts.id"), nullable=True),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("status", sa.String(), nullable=False, server_default="pending"),
        sa.Column("note", sa.String(), nullable=True),
        sa.Column("accept_note", sa.String(), nullable=True),
        sa.Column("device_id", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "status IN ('pending','accepted','disputed')",
            name="handovers_status_check",
        ),
    )
    op.create_index("ix_handovers_shop_occurred", "handovers", ["shop_id", "occurred_at"])
    op.create_index("ix_handovers_status", "handovers", ["shop_id", "status"])

    op.create_table(
        "handover_items",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("shop_id", UUID(as_uuid=True), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column(
            "handover_id", UUID(as_uuid=True),
            sa.ForeignKey("handovers.id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("product_id", UUID(as_uuid=True), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("product_name_snapshot", sa.String(), nullable=False),
        sa.Column("qty_handed", sa.Numeric(12, 3), nullable=False),
        sa.Column("qty_received", sa.Numeric(12, 3), nullable=True),
        sa.Column(
            "variance", sa.Numeric(12, 3),
            sa.Computed("qty_received - qty_handed", persisted=True),
        ),
        sa.CheckConstraint("qty_handed >= 0", name="handover_items_handed_check"),
        sa.CheckConstraint(
            "qty_received IS NULL OR qty_received >= 0",
            name="handover_items_received_check",
        ),
    )
    op.create_index("ix_handover_items_handover", "handover_items", ["handover_id"])
    op.create_index("ix_handover_items_shop_id", "handover_items", ["shop_id"])

    for t in ("handovers", "handover_items"):
        op.execute(f"ALTER TABLE {t} ENABLE ROW LEVEL SECURITY")
        op.execute(f"ALTER TABLE {t} FORCE ROW LEVEL SECURITY")
        op.execute(
            f"CREATE POLICY tenant_isolation ON {t} "
            f"USING {_TENANT_PRED} WITH CHECK {_TENANT_PRED}"
        )


def downgrade() -> None:
    op.drop_table("handover_items")
    op.drop_table("handovers")
    # Any baker accounts must go before the narrower CHECK can be restored.
    op.execute("UPDATE users SET is_active = false WHERE role = 'baker'")
    op.execute("UPDATE users SET role = 'cashier' WHERE role = 'baker'")
    op.execute(f"ALTER TABLE users DROP CONSTRAINT IF EXISTS {_ROLE_CHECK}")
    op.create_check_constraint(_ROLE_CHECK, "users", "role IN ('owner','cashier')")
