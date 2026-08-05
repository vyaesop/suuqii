"""Capability matrix — pure unit tests, no database.

The point of these is the *negative* cases. Before capabilities the role model
was binary (`role != "owner"`), so adding a third role would silently have
granted it every cashier permission including the till. These tests fail if
that regression is ever reintroduced.
"""
import pytest

from app.core.capabilities import (
    ADMIN,
    BAKER,
    CASHIER,
    HANDOVER_ACCEPT,
    HANDOVER_CREATE,
    INVITABLE_ROLES,
    MANAGE_DEBT,
    OWNER,
    RECORD_EXPENSE,
    RECORD_PRODUCTION,
    REFUND,
    ROLE_CAPS,
    SELL,
    SYNC_OP_CAPS,
    VIEW_COSTS,
    VIEW_PRODUCTS,
    VIEW_REPORTS,
    can,
    capability_for_op,
    needs_owner_pin,
)
from app.services.sync_service import SENSITIVE_OPS


def test_owner_holds_every_capability():
    for role_caps in ROLE_CAPS.values():
        assert role_caps <= ROLE_CAPS[OWNER]


@pytest.mark.parametrize(
    "denied",
    [SELL, REFUND, MANAGE_DEBT, RECORD_EXPENSE, VIEW_COSTS, VIEW_REPORTS, ADMIN],
)
def test_baker_never_touches_money(denied):
    assert not can(BAKER, denied)


def test_baker_can_do_its_actual_job():
    assert can(BAKER, RECORD_PRODUCTION)
    assert can(BAKER, HANDOVER_CREATE)
    assert can(BAKER, VIEW_PRODUCTS)


def test_baker_cannot_accept_its_own_handovers():
    """Two independent counts is the entire control. If a baker could accept,
    one person would be declaring and confirming the same number."""
    assert can(BAKER, HANDOVER_CREATE)
    assert not can(BAKER, HANDOVER_ACCEPT)


def test_cashier_accepts_but_does_not_create_handovers():
    assert can(CASHIER, HANDOVER_ACCEPT)
    assert not can(CASHIER, HANDOVER_CREATE)


def test_cashier_capabilities_unchanged_by_the_refactor():
    """Guards against the capability layer quietly widening or narrowing what
    a cashier could already do."""
    assert can(CASHIER, SELL)
    assert can(CASHIER, REFUND)
    assert can(CASHIER, MANAGE_DEBT)
    assert can(CASHIER, RECORD_EXPENSE)
    assert not can(CASHIER, VIEW_REPORTS)
    assert not can(CASHIER, VIEW_COSTS)
    assert not can(CASHIER, ADMIN)


def test_unknown_role_gets_nothing():
    for cap in ROLE_CAPS[OWNER]:
        assert not can("chef", cap)
        assert not can(None, cap)
        assert not can("", cap)


def test_owner_is_not_invitable():
    assert OWNER not in INVITABLE_ROLES
    assert set(INVITABLE_ROLES) == {CASHIER, BAKER}


def test_every_sync_op_capability_is_a_real_capability():
    for op, cap in SYNC_OP_CAPS.items():
        assert cap in ROLE_CAPS[OWNER], f"{op} maps to unknown capability {cap}"


def test_unmapped_op_fails_closed():
    assert capability_for_op("sale.create") == SELL
    assert capability_for_op("handover.create") == HANDOVER_CREATE
    # No entry → no capability → the sync engine rejects it outright.
    assert capability_for_op("payroll.pay_everyone") is None


def test_baker_cannot_push_a_sale():
    cap = capability_for_op("sale.create")
    assert cap is not None
    assert not can(BAKER, cap)


def test_production_needs_no_pin_for_a_baker_but_does_for_a_cashier():
    """Production is the baker's job, not a privileged act. A cashier doing it
    is still unusual enough to want the owner's PIN."""
    assert "production.record" in SENSITIVE_OPS
    assert not needs_owner_pin(BAKER, "production.record", SENSITIVE_OPS)
    assert needs_owner_pin(CASHIER, "production.record", SENSITIVE_OPS)
    assert not needs_owner_pin(OWNER, "production.record", SENSITIVE_OPS)


def test_baker_pin_exemption_does_not_leak_to_other_sensitive_ops():
    for op in SENSITIVE_OPS - {"production.record"}:
        assert needs_owner_pin(BAKER, op, SENSITIVE_OPS), op


def test_handover_ops_are_not_pin_gated():
    """Daily work. A PIN on every handover would train staff to skip them."""
    for op in ("handover.create", "handover.accept"):
        assert op not in SENSITIVE_OPS
        assert not needs_owner_pin(BAKER, op, SENSITIVE_OPS)
        assert not needs_owner_pin(CASHIER, op, SENSITIVE_OPS)
