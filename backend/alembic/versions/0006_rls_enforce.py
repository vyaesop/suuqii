"""Actually enforce row-level security.

The 0001 policies were inert: the app connects as the role that owns the
tables, and table owners bypass RLS unless FORCE ROW LEVEL SECURITY is set.
They also had no WITH CHECK clause, so writes were never constrained.

This migration:
- adds FORCE ROW LEVEL SECURITY so the owning role is subject to policies,
- recreates every tenant policy with a matching WITH CHECK,
- extends coverage to the bakery tables (supplies, recipe_items) which had
  no RLS at all.

Policies deliberately allow access when no app.current_shop_id context is
set: alembic data migrations, scripts/seed.py, and the sales_daily_mv
refresh all run as the table owner with no tenant context and must keep
working. Every API request path sets the context via deps.db_session, so
endpoint queries are constrained even if a WHERE shop_id is forgotten.

Revision ID: 0006_rls_enforce
Revises: 0005_expense_threshold
Create Date: 2026-07-11
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0006_rls_enforce"
down_revision: str | Sequence[str] | None = "0005_expense_threshold"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# Tables carrying a shop_id column
SHOP_TABLES = [
    "products",
    "sales",
    "inventory_logs",
    "debts",
    "debt_payments",
    "expenses",
    "shifts",
    "audit_logs",
    "sync_events",
    "supplies",
    "recipe_items",
]

_CTX = "NULLIF(current_setting('app.current_shop_id', true), '')"
_TENANT_PRED = f"({_CTX} IS NULL OR shop_id = {_CTX}::uuid)"
_SALE_ITEMS_PRED = (
    f"({_CTX} IS NULL OR EXISTS ("
    "SELECT 1 FROM sales WHERE sales.id = sale_items.sale_id "
    f"AND sales.shop_id = {_CTX}::uuid))"
)


def upgrade() -> None:
    for t in SHOP_TABLES:
        op.execute(f"ALTER TABLE {t} ENABLE ROW LEVEL SECURITY")
        op.execute(f"ALTER TABLE {t} FORCE ROW LEVEL SECURITY")
        op.execute(f"DROP POLICY IF EXISTS tenant_isolation ON {t}")
        op.execute(
            f"CREATE POLICY tenant_isolation ON {t} "
            f"USING {_TENANT_PRED} WITH CHECK {_TENANT_PRED}"
        )

    op.execute("ALTER TABLE sale_items ENABLE ROW LEVEL SECURITY")
    op.execute("ALTER TABLE sale_items FORCE ROW LEVEL SECURITY")
    op.execute("DROP POLICY IF EXISTS tenant_isolation ON sale_items")
    op.execute(
        "CREATE POLICY tenant_isolation ON sale_items "
        f"USING {_SALE_ITEMS_PRED} WITH CHECK {_SALE_ITEMS_PRED}"
    )

    # Housekeeping: debt_threshold had a Python-side default only; rows
    # created by raw SQL would get NULL.
    op.execute("ALTER TABLE shops ALTER COLUMN debt_threshold SET DEFAULT 500.00")
    op.execute("UPDATE shops SET debt_threshold = 500.00 WHERE debt_threshold IS NULL")


def downgrade() -> None:
    for t in [*SHOP_TABLES, "sale_items"]:
        op.execute(f"ALTER TABLE {t} NO FORCE ROW LEVEL SECURITY")
        op.execute(f"DROP POLICY IF EXISTS tenant_isolation ON {t}")

    # Restore the original (owner-bypassed, USING-only) 0001 policies.
    for t in [t for t in SHOP_TABLES if t not in ("supplies", "recipe_items")]:
        op.execute(
            f"CREATE POLICY tenant_isolation ON {t} "
            "USING (shop_id = current_setting('app.current_shop_id', true)::uuid)"
        )
    op.execute(
        "CREATE POLICY tenant_isolation ON sale_items USING (EXISTS ("
        "SELECT 1 FROM sales WHERE sales.id = sale_items.sale_id "
        "AND sales.shop_id = current_setting('app.current_shop_id', true)::uuid))"
    )
    op.execute("ALTER TABLE supplies DISABLE ROW LEVEL SECURITY")
    op.execute("ALTER TABLE recipe_items DISABLE ROW LEVEL SECURITY")
