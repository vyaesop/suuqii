"""Multi-shop membership: one owner, several shops.

`users.shop_id` stays the account's home shop. `shop_members` grants access to
additional shops, and the *active* shop travels in the access token — switching
is re-issuing a token for another shop you belong to.

RLS on this table keys on **user_id**, not shop_id: the whole point of the table
is to be read across tenants ("which shops may I switch to"), so the usual
`shop_id = app.current_shop_id` predicate would make it unreadable. Same
NULL-permissive shape as 0006 so unauthenticated flows (login) still work.

Backfill gives every existing user a membership for their current shop, so the
membership check in `current_user` never locks anyone out on deploy.

Revision ID: 0012_shop_members
Revises: 0011_baker_handovers
Create Date: 2026-08-05
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0012_shop_members"
down_revision: str | Sequence[str] | None = "0011_baker_handovers"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_USER_CTX = "NULLIF(current_setting('app.current_user_id', true), '')"
_USER_PRED = f"({_USER_CTX} IS NULL OR user_id = {_USER_CTX}::uuid)"


def upgrade() -> None:
    op.create_table(
        "shop_members",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "user_id", UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column(
            "shop_id", UUID(as_uuid=True),
            sa.ForeignKey("shops.id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("role", sa.String(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "role IN ('owner','cashier','baker')", name="shop_members_role_check"
        ),
        sa.UniqueConstraint("user_id", "shop_id", name="uq_shop_members_user_shop"),
    )
    op.create_index("ix_shop_members_user", "shop_members", ["user_id"])
    op.create_index("ix_shop_members_shop", "shop_members", ["shop_id"])

    # Every existing account keeps working: one membership for its home shop.
    op.execute(
        "INSERT INTO shop_members (id, user_id, shop_id, role, created_at) "
        "SELECT gen_random_uuid(), u.id, u.shop_id, u.role, now() "
        "FROM users u "
        "WHERE u.deleted_at IS NULL "
        "ON CONFLICT (user_id, shop_id) DO NOTHING"
    )

    # A device remembers which shop it is currently in. Refresh tokens carry
    # only user + device, so without this a token refresh would silently bounce
    # a multi-shop owner back to their home shop mid-session.
    op.add_column(
        "device_sessions",
        sa.Column(
            "active_shop_id", UUID(as_uuid=True),
            sa.ForeignKey("shops.id"), nullable=True,
        ),
    )

    op.execute("ALTER TABLE shop_members ENABLE ROW LEVEL SECURITY")
    op.execute("ALTER TABLE shop_members FORCE ROW LEVEL SECURITY")
    op.execute(
        "CREATE POLICY member_isolation ON shop_members "
        f"USING {_USER_PRED} WITH CHECK {_USER_PRED}"
    )


def downgrade() -> None:
    op.drop_column("device_sessions", "active_shop_id")
    op.drop_table("shop_members")
