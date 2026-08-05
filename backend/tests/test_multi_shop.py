"""Multi-shop membership (migration 0012).

The dangerous failure here is a tenant leak, so most of these are negative
tests: a token naming a shop you do not belong to must not read it, and
switching must not follow you home on the next token refresh.
"""
from datetime import UTC, datetime
from decimal import Decimal
from uuid import uuid4

import pytest
from fastapi import HTTPException
from sqlalchemy.orm.attributes import instance_state

from app.core.deps import current_user
from app.models import Shop, ShopMember, User


async def _mk_shop(db, name, shop_type="regular"):
    shop = Shop(
        id=uuid4(), name=name, phone=None, shop_type=shop_type,
        debt_threshold=Decimal("500.00"),
        expense_approval_threshold=Decimal("500.00"),
    )
    db.add(shop)
    await db.flush()
    return shop


async def _mk_member(db, user, shop, role="owner"):
    m = ShopMember(
        id=uuid4(), user_id=user.id, shop_id=shop.id, role=role,
        created_at=datetime.now(UTC),
    )
    db.add(m)
    await db.flush()
    return m


def _payload(user, shop_id, role="owner"):
    return {"sub": str(user.id), "shop_id": str(shop_id), "role": role,
            "typ": "access"}


async def test_home_shop_needs_no_membership_row(db, shop, owner):
    """Existing single-shop accounts keep working even before the backfill has
    given them a membership."""
    resolved = await current_user(_payload(owner, shop.id), db)
    assert resolved.id == owner.id
    assert resolved.shop_id == shop.id


async def test_membership_grants_a_second_shop(db, shop, owner):
    bakery = await _mk_shop(db, "Keol Bakery", shop_type="bakery")
    await _mk_member(db, owner, bakery, role="owner")

    resolved = await current_user(_payload(owner, bakery.id), db)
    assert resolved.shop_id == bakery.id


async def test_token_for_a_shop_you_do_not_belong_to_is_refused(db, shop, owner):
    stranger_shop = await _mk_shop(db, "Someone Else's Shop")
    with pytest.raises(HTTPException) as e:
        await current_user(_payload(owner, stranger_shop.id), db)
    assert e.value.status_code == 403


async def test_switching_does_not_persist_to_the_user_row(db, shop, owner):
    """`current_user` presents the active shop by overwriting `user.shop_id`.

    If that marked the instance dirty, the next flush would move the account's
    *home* shop permanently — and it would silently break the owner-PIN lockout
    counters, which mutate this same attached object.
    """
    bakery = await _mk_shop(db, "Bakery", shop_type="bakery")
    await _mk_member(db, owner, bakery, role="owner")

    resolved = await current_user(_payload(owner, bakery.id), db)
    assert resolved.shop_id == bakery.id
    assert "shop_id" not in instance_state(resolved).committed_state
    assert resolved not in db.dirty

    # A flush must not rewrite the home shop.
    resolved.owner_pin_attempts = 1  # the lockout path still works
    await db.flush()
    db.expunge(resolved)
    reloaded = await db.get(User, owner.id)
    assert reloaded.shop_id == shop.id
    assert reloaded.owner_pin_attempts == 1


async def test_role_follows_the_shop(db, shop, owner):
    """The same person can be owner of one shop and a cashier in another."""
    other = await _mk_shop(db, "Corner Shop")
    await _mk_member(db, owner, other, role="cashier")

    resolved = await current_user(_payload(owner, other.id, role="cashier"), db)
    assert resolved.role == "cashier"
    assert resolved.shop_id == other.id

    # Home shop is unaffected.
    db.expunge(resolved)
    at_home = await current_user(_payload(owner, shop.id), db)
    assert at_home.role == "owner"


async def test_revoked_membership_locks_the_shop_out(db, shop, owner):
    """A token outlives its membership; the check is per-request, not per-token."""
    bakery = await _mk_shop(db, "Bakery", shop_type="bakery")
    member = await _mk_member(db, owner, bakery)
    payload = _payload(owner, bakery.id)

    assert (await current_user(payload, db)).shop_id == bakery.id

    await db.delete(member)
    await db.flush()
    db.expunge_all()

    with pytest.raises(HTTPException) as e:
        await current_user(payload, db)
    assert e.value.status_code == 403


async def test_cashier_cannot_reach_another_shop_via_a_forged_shop_id(db, shop, cashier):
    other = await _mk_shop(db, "Other")
    with pytest.raises(HTTPException) as e:
        await current_user(_payload(cashier, other.id, role="cashier"), db)
    assert e.value.status_code == 403


async def test_inactive_user_is_refused_before_the_membership_check(db, shop, owner):
    bakery = await _mk_shop(db, "Bakery", shop_type="bakery")
    await _mk_member(db, owner, bakery)
    owner.is_active = False
    await db.flush()

    with pytest.raises(HTTPException) as e:
        await current_user(_payload(owner, bakery.id), db)
    assert e.value.status_code == 401
