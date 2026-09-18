"""Boutique analytics — Phase 4 (docs/19-boutique-shop-type.md §14).

Size curve, dead stock, broken runs and top styles. Fixtures and event
builders come from test_boutique: these reports read exactly what the
`style.*` / `sale.*` / `sale.return` handlers write, so seeding through the
sync engine (rather than hand-inserting rows) is what makes the assertions
mean anything.

Like test_boutique, the schema here is built from metadata, so RLS *policies*
are absent and tenant isolation is exercised at the application layer — every
one of the four endpoints is asked to leak another shop's data and must not.
"""
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient
from test_boutique import _create_style, _ev, _return, _sale, _svc, _variant

from app.core.capabilities import CASHIER, ROLE_CAPS, VIEW_REPORTS
from app.core.deps import current_token_payload, current_user, db_session
from app.core.size_presets import SIZE_PRESETS
from app.main import app
from app.models import Product, Shop, Style, User
from app.models.style import SIZE_SETS

# ---------------------------------------------------------------- helpers ---


@pytest.fixture
async def client(db):
    """HTTP client with the test session injected; caller sets `as_user`.
    Same shape as test_boutique's — `require_cap` reads the token payload
    directly, so that dependency is derived from the same user."""
    holder = {}

    async def _db():
        yield db

    async def _user():
        return holder["user"]

    async def _payload():
        u = holder["user"]
        return {"sub": str(u.id), "shop_id": str(u.shop_id), "role": u.role, "typ": "access"}

    app.dependency_overrides[db_session] = _db
    app.dependency_overrides[current_user] = _user
    app.dependency_overrides[current_token_payload] = _payload
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        c.as_user = lambda u: holder.__setitem__("user", u)  # type: ignore[attr-defined]
        yield c
    app.dependency_overrides.clear()


def _receive_at(product_id, qty, cost, when=None):
    """stock.receive with an explicit receipt time — the lot's received_at is
    the payload's occurred_at, which is what dates the dead-stock report."""
    return _ev("stock.receive", {
        "id": str(uuid4()), "product_id": str(product_id),
        "quantity": qty, "unit_cost": cost,
        "occurred_at": (when or datetime.now(UTC)).isoformat(),
    })


def _ago(days):
    return datetime.now(UTC) - timedelta(days=days)


async def _plain_product(db, shop, name="Plain soap", stock="10"):
    """A product with no style: the boutique that also sells a few odds and
    ends must still see them in the rollup."""
    p = Product(
        id=uuid4(), shop_id=shop.id, name=name,
        purchase_price=Decimal("12.00"), selling_price=Decimal("20.00"),
        stock=Decimal(stock), low_stock_threshold=Decimal("0"), unit="piece",
    )
    db.add(p)
    await db.flush()
    return p


async def _other_boutique(db):
    """A second boutique with its own style, one depleted and one stocked
    variant, so every report has something to leak if it forgets the shop
    filter."""
    shop = Shop(
        id=uuid4(), name="Other boutique", phone="+251900000090",
        shop_type="boutique", debt_threshold=Decimal("500.00"),
        expense_approval_threshold=Decimal("500.00"),
    )
    db.add(shop)
    await db.flush()
    owner = User(
        id=uuid4(), shop_id=shop.id, name="Other owner", phone="+251900000091",
        password_hash="x", role="owner", is_active=True,
    )
    style = Style(
        id=uuid4(), shop_id=shop.id, name="Other style", brand="Other brand",
        default_selling_price=Decimal("100.00"), default_purchase_price=Decimal("50.00"),
        size_set="letter",
    )
    db.add_all([owner, style])
    await db.flush()
    variants = [
        Product(
            id=uuid4(), shop_id=shop.id, name=f"Other style · {size}", style_id=style.id,
            size=size, purchase_price=Decimal("50.00"), selling_price=Decimal("100.00"),
            stock=Decimal(stock), low_stock_threshold=Decimal("0"), unit="piece",
        )
        for size, stock in (("M", "4"), ("L", "0"))
    ]
    db.add_all(variants)
    await db.flush()
    return shop, owner, style, variants


def _sizes(body):
    return [row["size"] for row in body["sizes"]]


# -------------------------------------------------------------- size curve --


async def test_size_curve_shape_and_ordering(client, db, boutique_shop, boutique_owner):
    payload, variants = await _create_style(db, boutique_shop, boutique_owner)
    blue32, blue34, black32 = (
        variants[("32", "Blue")], variants[("34", "Blue")], variants[("32", "Black")],
    )
    svc = _svc(db, boutique_shop, boutique_owner)
    for v, qty in ((blue32, "10"), (blue34, "6"), (black32, "4")):
        await svc.apply(_receive_at(v.id, qty, "800.00"))
    await svc.apply(_sale([(blue32, "4", "1200.00")]))
    await svc.apply(_sale([(blue34, "2", "1200.00")]))
    await svc.apply(_sale([(black32, "1", "1200.00")]))

    client.as_user(boutique_owner)
    r = await client.get(f"/v1/reports/size-curve?style_id={payload['id']}")
    assert r.status_code == 200
    body = r.json()
    assert body["style"] == {"id": payload["id"], "name": "Slim jeans", "brand": "Levi's"}

    # Waist preset order: 32 before 34 (a plain sort of the labels agrees here,
    # but the preset is what is being asserted — see the fallback test).
    assert _sizes(body) == ["32", "34"]
    assert body["sizes"][0] == {
        "size": "32", "received": "14", "sold": "5", "on_hand": "9",
        "sell_through": "0.357", "revenue": "6000.00",   # 5/14 = 0.3571…
    }
    assert body["sizes"][1] == {
        "size": "34", "received": "6", "sold": "2", "on_hand": "4",
        "sell_through": "0.333", "revenue": "2400.00",
    }
    assert [c["color"] for c in body["colors"]] == ["Black", "Blue"]
    assert body["colors"][0] == {
        "color": "Black", "received": "4", "sold": "1", "on_hand": "3",
        "sell_through": "0.25", "revenue": "1200.00",
    }
    assert body["colors"][1]["received"] == "16"
    assert body["colors"][1]["sell_through"] == "0.375"      # 6/16
    assert body["totals"] == {
        "received": "20", "sold": "7", "on_hand": "13", "revenue": "8400.00",
    }


async def test_size_curve_nets_resellable_and_damaged_returns(
    client, db, boutique_shop, boutique_owner,
):
    payload, variants = await _create_style(
        db, boutique_shop, boutique_owner, name="Tee", prefix="TS",
        selling="1000.00", purchase="500.00", size_set="letter",
        variants=[_variant("M", "Red", sku="TS-M-RED")],
    )
    tee = variants[("M", "Red")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive_at(tee.id, "10", "500.00"))
    sale = _sale([(tee, "4", "1000.00")])
    await svc.apply(sale)
    await svc.apply(_return(sale, [(0, "1", "resellable")], refund="1000.00", method="cash"))
    await svc.apply(_return(sale, [(0, "1", "damaged")], refund="1000.00", method="cash",
                            reason="defect"))

    client.as_user(boutique_owner)
    body = (await client.get(f"/v1/reports/size-curve?style_id={payload['id']}")).json()
    row = body["sizes"][0]
    # Both conditions come off `sold` and off revenue; only the resellable one
    # goes back on the shelf, so on_hand is 10 − 4 + 1, not 10 − 4 + 2.
    assert row == {
        "size": "M", "received": "10", "sold": "2", "on_hand": "7",
        "sell_through": "0.2", "revenue": "2000.00",
    }
    assert body["totals"] == {
        "received": "10", "sold": "2", "on_hand": "7", "revenue": "2000.00",
    }


async def test_size_curve_sell_through_is_zero_when_nothing_was_received(
    client, db, boutique_shop, boutique_owner,
):
    payload, variants = await _create_style(
        db, boutique_shop, boutique_owner, name="Scarf", prefix="SC",
        variants=[_variant("M", None, sku="SC-M")],
    )
    scarf = variants[("M", None)]
    # Unlotted stock: a CSV import sets products.stock with no stock_lots row.
    scarf.stock = Decimal("5")
    await db.flush()
    await _svc(db, boutique_shop, boutique_owner).apply(_sale([(scarf, "2", "1200.00")]))

    client.as_user(boutique_owner)
    body = (await client.get(f"/v1/reports/size-curve?style_id={payload['id']}")).json()
    assert body["sizes"][0] == {
        "size": "M", "received": "0", "sold": "2", "on_hand": "3",
        "sell_through": "0", "revenue": "2400.00",
    }
    assert body["colors"][0]["color"] is None


async def test_size_curve_falls_back_to_numerics_first_without_a_preset(
    client, db, boutique_shop, boutique_owner,
):
    payload, _ = await _create_style(
        db, boutique_shop, boutique_owner, name="Mixed", prefix=None, size_set=None,
        variants=[
            _variant("10", None), _variant("2", None), _variant("M", None),
            _variant("XL", None), _variant(None, None),
        ],
    )
    client.as_user(boutique_owner)
    body = (await client.get(f"/v1/reports/size-curve?style_id={payload['id']}")).json()
    # Numerics first and numerically ("2" before "10", which lexicographic
    # order would invert), then text, then the unsized row.
    assert _sizes(body) == ["2", "10", "M", "XL", None]


async def test_size_curve_404_for_unknown_and_foreign_styles(
    client, db, boutique_shop, boutique_owner,
):
    payload, _ = await _create_style(db, boutique_shop, boutique_owner)
    _, other_owner, other_style, _ = await _other_boutique(db)

    client.as_user(boutique_owner)
    assert (await client.get(f"/v1/reports/size-curve?style_id={uuid4()}")).status_code == 404
    assert (await client.get(f"/v1/reports/size-curve?style_id={other_style.id}")).status_code == 404
    client.as_user(other_owner)
    assert (await client.get(f"/v1/reports/size-curve?style_id={payload['id']}")).status_code == 404


# -------------------------------------------------------------- dead stock --


async def test_dead_stock_ages_from_the_oldest_open_lot(
    client, db, boutique_shop, boutique_owner,
):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    blue32, blue34, black32 = (
        variants[("32", "Blue")], variants[("34", "Blue")], variants[("32", "Black")],
    )
    svc = _svc(db, boutique_shop, boutique_owner)
    # A lot received 300 days ago and sold out 200 days ago: the stock sitting
    # on the shelf today arrived 100 days ago, so that is the age.
    await svc.apply(_receive_at(blue32.id, "5", "700.00", _ago(300)))
    await svc.apply(_sale([(blue32, "5", "1200.00")], occurred=_ago(200)))
    await svc.apply(_receive_at(blue32.id, "3", "800.00", _ago(100)))
    await svc.apply(_receive_at(blue32.id, "1", "1000.00", _ago(80)))
    # Never lotted, never sold.
    blue34.stock = Decimal("2")
    # Sold yesterday: alive, whatever its age.
    await svc.apply(_receive_at(black32.id, "4", "900.00", _ago(150)))
    await svc.apply(_sale([(black32, "1", "1200.00")], occurred=_ago(1)))
    await db.flush()

    client.as_user(boutique_owner)
    body = (await client.get("/v1/reports/dead-stock")).json()
    assert body["days"] == 60
    assert [i["product_id"] for i in body["items"]] == [str(blue32.id), str(blue34.id)]

    dead = body["items"][0]
    assert dead["age_days"] == 100           # not 300
    assert dead["last_sold_at"] == _ago(200).date().isoformat()
    assert dead["stock"] == "4"
    # Weighted over the open lots only: (3×800 + 1×1000) / 4.
    assert dead["unit_cost"] == "850.00"
    assert dead["value"] == "3400.00"
    assert dead["style_id"] is not None
    assert (dead["size"], dead["color"]) == ("32", "Blue")

    unlotted = body["items"][1]
    assert unlotted["last_sold_at"] is None
    assert unlotted["unit_cost"] == "800.00"  # falls back to purchase_price
    assert unlotted["value"] == "1600.00"
    assert body["total_value"] == "5000.00"
    assert body["has_more"] is False
    assert body["next_cursor"] is None


async def test_dead_stock_paginates_oldest_first(client, db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    blue32, blue34 = variants[("32", "Blue")], variants[("34", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive_at(blue32.id, "2", "800.00", _ago(200)))
    await svc.apply(_receive_at(blue34.id, "2", "800.00", _ago(100)))

    client.as_user(boutique_owner)
    first = (await client.get("/v1/reports/dead-stock?limit=1")).json()
    assert [i["product_id"] for i in first["items"]] == [str(blue32.id)]
    assert first["has_more"] is True
    # The total is the whole shelf, not the page.
    assert first["total_value"] == "3200.00"
    second = (await client.get(
        "/v1/reports/dead-stock", params={"limit": 1, "cursor": first["next_cursor"]},
    )).json()
    assert [i["product_id"] for i in second["items"]] == [str(blue34.id)]
    assert second["has_more"] is False


async def test_dead_stock_days_is_bounded_and_applied(
    client, db, boutique_shop, boutique_owner,
):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    blue32 = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive_at(blue32.id, "5", "800.00", _ago(90)))
    await svc.apply(_sale([(blue32, "1", "1200.00")], occurred=_ago(45)))

    client.as_user(boutique_owner)
    assert (await client.get("/v1/reports/dead-stock?days=0")).status_code == 422
    assert (await client.get("/v1/reports/dead-stock?days=366")).status_code == 422
    # Sold 45 days ago: dead at 30 days, alive at 60.
    assert (await client.get("/v1/reports/dead-stock?days=60")).json()["items"] == []
    at30 = (await client.get("/v1/reports/dead-stock?days=30")).json()
    assert [i["product_id"] for i in at30["items"]] == [str(blue32.id)]
    assert at30["days"] == 30
    assert (await client.get("/v1/reports/dead-stock?days=365")).status_code == 200


# ------------------------------------------------------------ broken runs --


async def test_broken_runs_lists_rebuyable_styles_only(
    client, db, boutique_shop, boutique_owner,
):
    svc = _svc(db, boutique_shop, boutique_owner)

    # Slim jeans: two sizes gone, one still selling → a genuine broken run.
    jeans_payload, jeans = await _create_style(db, boutique_shop, boutique_owner)
    blue32, blue34, black32 = (
        jeans[("32", "Blue")], jeans[("34", "Blue")], jeans[("32", "Black")],
    )
    await svc.apply(_receive_at(blue32.id, "6", "800.00"))
    await svc.apply(_sale([(blue32, "6", "1200.00")]))
    await svc.apply(_receive_at(black32.id, "3", "800.00"))
    black_sale = _sale([(black32, "3", "1200.00")])
    await svc.apply(black_sale)
    # A damaged return: the unit does not come back to the shelf (stock stays
    # 0, so the variant is still missing) but it was not really sold either.
    await svc.apply(_return(black_sale, [(0, "1", "damaged")], refund="1200.00",
                            method="cash", reason="defect"))
    await svc.apply(_receive_at(blue34.id, "5", "800.00"))

    # Tee: everything sold out → gone, not broken.
    tee_payload, tees = await _create_style(
        db, boutique_shop, boutique_owner, name="Tee", prefix="TS",
        variants=[_variant("M", "Red", sku="TS-M-RED"), _variant("L", "Red", sku="TS-L-RED")],
    )
    for v in tees.values():
        await svc.apply(_receive_at(v.id, "2", "500.00"))
        await svc.apply(_sale([(v, "2", "1000.00")]))

    # Cap: one variant at (not below) its threshold, one empty, one healthy.
    cap_payload, caps = await _create_style(
        db, boutique_shop, boutique_owner, name="Cap", prefix="CP", size_set="letter",
        variants=[
            _variant("M", None, sku="CP-M", threshold="2"),
            _variant("L", None, sku="CP-L"),
            _variant("XL", None, sku="CP-XL"),
        ],
    )
    for size, received, sold in (("M", "3", "1"), ("L", "1", "1"), ("XL", "3", "0")):
        v = caps[(size, None)]
        await svc.apply(_receive_at(v.id, received, "300.00"))
        if sold != "0":
            await svc.apply(_sale([(v, sold, "600.00")]))

    client.as_user(boutique_owner)
    body = (await client.get("/v1/reports/broken-runs")).json()
    # Ranked by the demand behind the missing sizes: jeans 6 + 2, cap 1 + 1.
    assert [i["name"] for i in body["items"]] == ["Slim jeans", "Cap"]
    assert tee_payload["id"] not in [i["style_id"] for i in body["items"]]

    jeans_row = body["items"][0]
    assert jeans_row["style_id"] == jeans_payload["id"]
    assert jeans_row["brand"] == "Levi's"
    assert jeans_row["variant_count"] == 3
    assert jeans_row["in_stock_count"] == 1
    assert jeans_row["stock_total"] == "5"
    assert jeans_row["missing"] == [
        {"size": "32", "color": "Blue", "sold_30d": "6"},
        {"size": "32", "color": "Black", "sold_30d": "2"},   # 3 sold − 1 returned
    ]

    cap_row = body["items"][1]
    assert cap_row["style_id"] == cap_payload["id"]
    assert cap_row["in_stock_count"] == 1
    # "M" sits exactly on its threshold of 2 and still counts as missing.
    assert sorted(m["size"] for m in cap_row["missing"]) == ["L", "M"]


async def test_broken_runs_is_empty_without_styles(client, db, boutique_shop, boutique_owner):
    client.as_user(boutique_owner)
    assert (await client.get("/v1/reports/broken-runs")).json() == {"items": []}


# ------------------------------------------------------------- top styles --


async def test_top_styles_rolls_up_variants_and_nets_returns(
    client, db, boutique_shop, boutique_owner,
):
    payload, variants = await _create_style(db, boutique_shop, boutique_owner)
    blue32, blue34, black32 = (
        variants[("32", "Blue")], variants[("34", "Blue")], variants[("32", "Black")],
    )
    soap = await _plain_product(db, boutique_shop)
    svc = _svc(db, boutique_shop, boutique_owner)
    for v in (blue32, blue34, black32):
        await svc.apply(_receive_at(v.id, "6", "800.00"))
    blue_sale = _sale([(blue32, "3", "1200.00")])
    await svc.apply(blue_sale)
    await svc.apply(_sale([(blue34, "2", "1200.00")]))
    await svc.apply(_sale([(black32, "1", "1200.00")]))
    await svc.apply(_sale([(soap, "5", "20.00")]))

    client.as_user(boutique_owner)
    body = (await client.get("/v1/reports/top-styles")).json()
    assert body["items"][0] == {
        "style_id": payload["id"], "name": "Slim jeans", "brand": "Levi's",
        "image_url": None, "quantity": "6", "revenue": "7200.00",
        "profit": "2400.00", "variant_count": 3,
    }
    # An unstyled product rolls up as itself rather than vanishing.
    assert body["items"][1] == {
        "style_id": None, "name": "Plain soap", "brand": None, "image_url": None,
        "quantity": "5", "revenue": "100.00", "profit": "40.00", "variant_count": 1,
    }

    await svc.apply(_return(blue_sale, [(0, "1", "resellable")], refund="1200.00", method="cash"))
    await svc.apply(_return(blue_sale, [(0, "1", "damaged")], refund="1200.00", method="cash",
                            reason="defect"))
    body = (await client.get("/v1/reports/top-styles")).json()
    jeans = body["items"][0]
    assert jeans["quantity"] == "4"
    assert jeans["revenue"] == "4800.00"
    # The resellable unit gives its cost back so only its margin (400) is
    # lost; the damaged one takes the whole 1200 with it.
    assert jeans["profit"] == "800.00"


async def test_top_styles_limit_is_bounded(client, db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    blue32 = variants[("32", "Blue")]
    soap = await _plain_product(db, boutique_shop)
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive_at(blue32.id, "4", "800.00"))
    await svc.apply(_sale([(blue32, "1", "1200.00")]))
    await svc.apply(_sale([(soap, "5", "20.00")]))

    client.as_user(boutique_owner)
    assert len((await client.get("/v1/reports/top-styles?limit=1")).json()["items"]) == 1
    assert (await client.get("/v1/reports/top-styles?limit=0")).status_code == 422
    assert (await client.get("/v1/reports/top-styles?limit=51")).status_code == 422


async def test_top_styles_window_is_half_open(client, db, boutique_shop, boutique_owner):
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    blue32 = variants[("32", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive_at(blue32.id, "4", "800.00"))
    await svc.apply(_sale([(blue32, "1", "1200.00")], occurred=_ago(10)))

    client.as_user(boutique_owner)
    inside = await client.get(f"/v1/reports/top-styles?from={_ago(11).date()}")
    assert inside.json()["items"][0]["quantity"] == "1"
    outside = await client.get(f"/v1/reports/top-styles?to={_ago(11).date()}")
    assert outside.json()["items"] == []


# -------------------------------------------------------- roles and scope --


async def test_boutique_reports_are_owner_only(
    client, db, boutique_shop, boutique_owner, boutique_cashier,
):
    payload, _ = await _create_style(db, boutique_shop, boutique_owner)
    client.as_user(boutique_cashier)
    for path in (
        f"/v1/reports/size-curve?style_id={payload['id']}",
        "/v1/reports/dead-stock",
        "/v1/reports/broken-runs",
        "/v1/reports/top-styles",
    ):
        assert (await client.get(path)).status_code == 403, path


async def test_costs_are_masked_without_view_costs(
    client, db, boutique_shop, boutique_owner, boutique_cashier, monkeypatch,
):
    """Only owners hold VIEW_REPORTS today, so the masking is unreachable in
    production — but the day a manager role gets reports without costs, the
    numbers must already be blank rather than leak the buy price."""
    monkeypatch.setitem(ROLE_CAPS, CASHIER, ROLE_CAPS[CASHIER] | {VIEW_REPORTS})
    _, variants = await _create_style(db, boutique_shop, boutique_owner)
    blue32, blue34 = variants[("32", "Blue")], variants[("34", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    # blue32 sits unsold since 90 days ago (dead stock); blue34 sells today
    # (top styles), so both reports have a row whose cost must be blank.
    await svc.apply(_receive_at(blue32.id, "4", "800.00", _ago(90)))
    await svc.apply(_receive_at(blue34.id, "4", "800.00"))
    await svc.apply(_sale([(blue34, "1", "1200.00")]))

    client.as_user(boutique_cashier)
    dead = (await client.get("/v1/reports/dead-stock")).json()
    assert dead["items"][0]["unit_cost"] == "0"
    assert dead["items"][0]["value"] == "0"
    assert dead["total_value"] == "0"
    top = (await client.get("/v1/reports/top-styles")).json()
    assert top["items"][0]["revenue"] == "1200.00"
    assert top["items"][0]["profit"] == "0"


async def test_boutique_reports_are_shop_scoped(client, db, boutique_shop, boutique_owner):
    payload, variants = await _create_style(db, boutique_shop, boutique_owner)
    blue32, blue34 = variants[("32", "Blue")], variants[("34", "Blue")]
    svc = _svc(db, boutique_shop, boutique_owner)
    await svc.apply(_receive_at(blue32.id, "6", "800.00", _ago(200)))
    await svc.apply(_sale([(blue32, "6", "1200.00")]))
    await svc.apply(_receive_at(blue34.id, "5", "800.00", _ago(200)))
    _, other_owner, other_style, other_variants = await _other_boutique(db)

    client.as_user(other_owner)
    # The other shop has stock and a broken run of its own, and sees only it.
    dead = (await client.get("/v1/reports/dead-stock")).json()
    assert [i["product_id"] for i in dead["items"]] == [str(other_variants[0].id)]
    assert (await client.get("/v1/reports/broken-runs")).json()["items"] == [
        {
            "style_id": str(other_style.id), "name": "Other style", "brand": "Other brand",
            "image_url": None, "variant_count": 2, "in_stock_count": 1, "stock_total": "4",
            "missing": [{"size": "L", "color": None, "sold_30d": "0"}],
        }
    ]
    assert (await client.get("/v1/reports/top-styles")).json()["items"] == []
    assert (await client.get(
        f"/v1/reports/size-curve?style_id={payload['id']}"
    )).status_code == 404

    client.as_user(boutique_owner)
    dead = (await client.get("/v1/reports/dead-stock")).json()
    assert [i["product_id"] for i in dead["items"]] == [str(blue34.id)]
    runs = (await client.get("/v1/reports/broken-runs")).json()["items"]
    assert [i["style_id"] for i in runs] == [payload["id"]]
    tops = (await client.get("/v1/reports/top-styles")).json()["items"]
    assert [i["style_id"] for i in tops] == [payload["id"]]
    curve = (await client.get(f"/v1/reports/size-curve?style_id={payload['id']}")).json()
    assert curve["totals"]["received"] == "11"


# ------------------------------------------------------------- size table --


def test_size_presets_cover_every_size_set():
    """The preset table is a verbatim mirror of
    mobile/lib/core/shop_type/size_presets.dart and of styles.size_set: a key
    that exists on one side only would silently fall back to generic ordering
    and scramble the curve."""
    assert set(SIZE_PRESETS) == set(SIZE_SETS)
    assert SIZE_PRESETS["letter"] == ("XS", "S", "M", "L", "XL", "XXL", "3XL")
    assert SIZE_PRESETS["numeric"] == ("34", "36", "38", "40", "42", "44", "46", "48")
    assert SIZE_PRESETS["waist"] == ("26", "28", "30", "32", "34", "36", "38", "40", "42")
    assert SIZE_PRESETS["shoe_eu"][0] == "35" and SIZE_PRESETS["shoe_eu"][-1] == "46"
    assert SIZE_PRESETS["kids_age"][:3] == ("0–3m", "3–6m", "6–12m")
    assert SIZE_PRESETS["free"] == () and SIZE_PRESETS["custom"] == ()
