"""
Role capabilities — deny by default (docs/17-roles.md).

Before this module the role model was binary: ~30 sites tested
`user.role != "owner"`, so *any* non-owner role was implicitly a cashier with
full POS access. Adding `baker` under that model would have handed the bakery
staff the till. Roles now declare capabilities explicitly and an unknown role
gets nothing.

Three layers, unchanged in authority:
1. capability (this module) — may the role do this *at all*?
2. owner PIN (`SENSITIVE_OPS` in sync_service) — does it need fresh approval?
3. Postgres RLS — tenant isolation backstop.

A role can hold a capability and still need a PIN for it: cashiers may receive
stock, but only with the owner's PIN. `ROLE_PIN_EXEMPT` carves out the ops that
are a role's actual job — a baker recording production is not a privileged act,
it is the reason they have an account.
"""
from __future__ import annotations

# ---- capabilities ----------------------------------------------------------

SELL = "sell"                          # POS checkout
REFUND = "refund"                      # reverse a sale
VIEW_PRODUCTS = "view_products"        # names, units, stock levels
VIEW_COSTS = "view_costs"              # purchase price / unit cost / margin
VIEW_REPORTS = "view_reports"          # dashboard, reports, audit log
MANAGE_PRODUCTS = "manage_products"    # create/update/delete product
MANAGE_INVENTORY = "manage_inventory"  # receive, spoil, manual adjust
RECORD_PRODUCTION = "record_production"  # bakery: a bake run
HANDOVER_CREATE = "handover_create"    # baker → counter, declares quantities
HANDOVER_ACCEPT = "handover_accept"    # counter counts what it actually got
VIEW_SUPPLIES = "view_supplies"        # ingredient levels (no costs)
MANAGE_SUPPLIES = "manage_supplies"    # supplies + recipes
RECORD_EXPENSE = "record_expense"
MANAGE_DEBT = "manage_debt"            # collect payment, write off
MANAGE_SHIFT = "manage_shift"          # open/close own shift
ADMIN = "admin"                        # invites, devices, shop settings

OWNER = "owner"
CASHIER = "cashier"
BAKER = "baker"

ROLES: frozenset[str] = frozenset({OWNER, CASHIER, BAKER})

# Roles the owner may invite. Owner accounts are created by shop registration.
INVITABLE_ROLES: frozenset[str] = frozenset({CASHIER, BAKER})

_ALL: frozenset[str] = frozenset({
    SELL, REFUND, VIEW_PRODUCTS, VIEW_COSTS, VIEW_REPORTS, MANAGE_PRODUCTS,
    MANAGE_INVENTORY, RECORD_PRODUCTION, HANDOVER_CREATE, HANDOVER_ACCEPT,
    VIEW_SUPPLIES, MANAGE_SUPPLIES, RECORD_EXPENSE, MANAGE_DEBT, MANAGE_SHIFT,
    ADMIN,
})

ROLE_CAPS: dict[str, frozenset[str]] = {
    OWNER: _ALL,
    # Unchanged from the pre-capability behaviour: everything except the
    # owner-only surfaces (reports, audit, admin, cost prices).
    CASHIER: frozenset({
        SELL, REFUND, VIEW_PRODUCTS, MANAGE_PRODUCTS, MANAGE_INVENTORY,
        RECORD_PRODUCTION, HANDOVER_ACCEPT, VIEW_SUPPLIES, MANAGE_SUPPLIES,
        RECORD_EXPENSE, MANAGE_DEBT, MANAGE_SHIFT,
    }),
    # Bakers produce and hand over. They never touch money: no SELL, no
    # REFUND, no MANAGE_DEBT, no RECORD_EXPENSE, no VIEW_COSTS. Handing them
    # HANDOVER_ACCEPT too would collapse the two independent counts back into
    # one and defeat the whole point of the role.
    BAKER: frozenset({
        VIEW_PRODUCTS, RECORD_PRODUCTION, HANDOVER_CREATE, VIEW_SUPPLIES,
        MANAGE_SHIFT,
    }),
}

# Ops in SENSITIVE_OPS that a role may push without an owner-PIN challenge,
# because they are that role's ordinary work. Owners are exempt from all
# sensitive ops already (they *are* the PIN holder).
ROLE_PIN_EXEMPT: dict[str, frozenset[str]] = {
    BAKER: frozenset({"production.record"}),
}

# Every sync op → the capability required to push it. Ops absent from this map
# are rejected outright: a new op must declare who may perform it, so
# forgetting to add an entry fails closed rather than open.
SYNC_OP_CAPS: dict[str, str] = {
    "sale.create": SELL,
    "sale.refund": REFUND,
    "sale.void": REFUND,
    "product.create": MANAGE_PRODUCTS,
    "product.update": MANAGE_PRODUCTS,
    "product.delete": MANAGE_PRODUCTS,
    # Boutique styles are product definitions (docs/19 §7): same capability,
    # same PIN gate, no new constant.
    "style.create": MANAGE_PRODUCTS,
    "style.update": MANAGE_PRODUCTS,
    "style.add_variants": MANAGE_PRODUCTS,
    "style.delete": MANAGE_PRODUCTS,
    # A partial return is a refund by another name.
    "sale.return": REFUND,
    "inventory.adjust": MANAGE_INVENTORY,
    "stock.receive": MANAGE_INVENTORY,
    "stock.spoil": MANAGE_INVENTORY,
    "production.record": RECORD_PRODUCTION,
    "handover.create": HANDOVER_CREATE,
    "handover.accept": HANDOVER_ACCEPT,
    "debt.payment.create": MANAGE_DEBT,
    "debt.writeoff": MANAGE_DEBT,
    "expense.create": RECORD_EXPENSE,
    "shift.open": MANAGE_SHIFT,
    "shift.close": MANAGE_SHIFT,
    "supply.create": MANAGE_SUPPLIES,
    "supply.update": MANAGE_SUPPLIES,
    "supply.delete": MANAGE_SUPPLIES,
    "recipe.set": MANAGE_SUPPLIES,
}


def can(role: str | None, capability: str) -> bool:
    """Does [role] hold [capability]? Unknown/None role → False."""
    return capability in ROLE_CAPS.get(role or "", frozenset())


def capability_for_op(op: str) -> str | None:
    """Capability required to push [op], or None when the op is unknown."""
    return SYNC_OP_CAPS.get(op)


def needs_owner_pin(role: str | None, op: str, sensitive_ops: set[str]) -> bool:
    """Whether pushing [op] as [role] requires an owner-PIN challenge."""
    if op not in sensitive_ops:
        return False
    if role == OWNER:
        return False
    return op not in ROLE_PIN_EXEMPT.get(role or "", frozenset())
