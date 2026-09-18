# 19 — Boutique / apparel shop type

Status: **Phases 0–3 implemented** (proposed 2026-09-16, built 2026-09-18).
Phases 4 (boutique analytics) and 5 (barcode scanning, layaway) are not built.
Section 13 is the wire contract both sides were built against and is
authoritative wherever the earlier prose differs from it.

This is the plan for a third `shop_type` next to `regular` and `bakery`: a
**boutique** — clothes, shoes, bags, accessories. It follows the same playbook
the bakery type used (one `shop_type` string on the shop, feature-gated UI, a
few new tables and sync ops, everything else shared), but the thing that makes
apparel different is not cost (as with bakery recipes) — it is **variants**.
A shirt is one style sold in six sizes and three colours; the owner thinks
in styles, the stock count lives per size/colour, and the cashier has to pick
the exact one in two taps.

Everything below is organised as: what boutiques actually need → the
architectural decision → data model → sync → UI → reports → roles → l10n →
migrations → phased delivery → tests → open questions.

---

## 1. What an Ethiopian boutique actually does (requirements)

Observed workflow for a 1–5 person apparel shop (Merkato / Bole / Adama /
Hawassa style shops selling imported ready-made clothes and shoes):

| Job to be done | Frequency | Today's app support |
|---|---|---|
| Sell one *specific* size/colour of a style, fast | every sale | ❌ each variant would be an unrelated product; grid becomes 200 near-identical tiles |
| Negotiate the price down at the counter (haggling is normal) | most sales | ⚠️ only a whole-cart discount; no per-line price, no floor, no audit of "list vs sold" |
| Exchange for another size next day; refund occasionally | weekly | ❌ only full-sale refund (`sale.refund` takes just `sale_id`) |
| Receive a shipment: one style, a grid of sizes × colours, one landed cost | weekly/monthly | ⚠️ `bulk_restock` is per product; no grid entry |
| Know which sizes are missing ("broken size run") so the next buying trip fills them | weekly | ❌ low-stock is per product, not per style |
| Know what is not moving (dead stock ages, then gets marked down) | monthly | ⚠️ lots carry `received_at`, but no report uses it for ageing |
| Take a deposit and hold an item ("layaway") | weekly | ⚠️ credit sale + debt + half-payment chips already exist — good enough with a label |
| Write price tags / hand-written SKU codes | on receipt | ❌ no SKU concept |
| Credit to known customers | weekly | ✅ debts |
| Shifts, cash reconciliation, accountability | daily | ✅ unchanged |

Things that are **not** needed and should stay out of scope: ingredient
supplies, recipes, production runs, handovers, baker role, expiry dates and
FEFO ordering (apparel does not expire — lots still matter for *cost* and
*ageing*, so lots stay, expiry is hidden), spoilage as such (renamed
"damaged / lost" in the UI — same `stock.spoil` op).

Non-goals for v1 (explicitly): store credit / gift vouchers, bundles and
"buy 2 get 1" promotions, consignment stock, tailoring/alterations jobs,
multi-warehouse, loyalty points.

---

## 2. The central decision: how to model variants

### Options considered

**A. Variant = a `products` row, grouped by a new `styles` table (recommended).**
Every sellable unit (Style × Size × Colour) is a normal product with its own
id, stock, barcode, lots, sale items. New nullable columns on `products`:
`style_id`, `size`, `color`, `sku`, `min_selling_price`. A `styles` row holds
the shared bits (name, brand, category, image, default prices, size set).

- ✅ Zero changes to `sales`, `sale_items`, `stock_lots`, `lot_consumptions`,
  `inventory_logs`, `handovers`, `debts`, shift reconciliation, batch/expiry
  reports, CSV export, receipts, cost masking, RLS. They already work per
  product; a variant *is* a product.
- ✅ `product.name` stays the composed display name
  ("Slim jeans · 32 · Blue"), so `product_name_snapshot`, receipt lines,
  search folding ([products_dao.dart:29](../mobile/lib/features/inventory/data/products_dao.dart#L29)),
  recent strip, and top-products all remain correct with no code change.
- ✅ Per-variant barcode and per-variant price override come for free.
- ⚠️ Renaming a style must recompose N product names (handled inside the
  `style.update` handler on both sides — see §4).
- ⚠️ A shop with 150 styles × 8 variants = 1,200 product rows. Fine for
  SQLite and for the paginated `/v1/products` list; the POS grid must group by
  style (see §6) or it becomes unusable.

**B. Separate `product_variants` table; `sale_items.variant_id`.**
Textbook-correct but touches every table and op that references
`product_id` (sales, lots, consumptions, logs, handovers, refunds, reports,
exports, RLS), plus every Drift DAO. Weeks of churn for no user-visible gain.
Rejected.

**C. Denormalised only: `products.style_name`, `size`, `color` strings.**
Cheapest; no new table, no new sync ops. But: no style-level image or default
price, renaming a style is an N-row update with no atomicity, and the
"style" grouping is a string equality that breaks on a typo. Acceptable as a
throw-away prototype; not as the shipped model.

**Decision: A.** It is the same trick the bakery type used (a bakery product
is still a product; recipes hang off it).

### Second decision: stop branching on `isBakery`, branch on features

Today there are ~30 `if (isBakery)` / `shop.shop_type == "bakery"` sites
across mobile and backend (home_shell, pos_screen, cart_review_sheet,
sales_repository, product_edit/detail, employees_screen, sync_reconciler,
reports.py, auth.py, sync_service.py). Adding `isBoutique` alongside would
double that. Introduce **one feature table per shop type**, keyed on the
type string, and have the call sites ask for the *feature*, not the type:

```dart
// mobile/lib/core/shop_type/shop_features.dart
class ShopFeatures {
  const ShopFeatures({
    required this.hasSupplies,        // bakery
    required this.hasProduction,      // bakery
    required this.hasHandovers,       // bakery
    required this.tracksExpiry,       // regular, bakery
    required this.allowsOversell,     // bakery (handover sync lag)
    required this.hasVariants,        // boutique
    required this.hasLinePricing,     // boutique
    required this.hasReturns,         // boutique (partial return + exchange)
    required this.defaultUnit,        // 'piece' everywhere; boutique locks it
    required this.spoilageLabelKey,   // l10n key: "Spoilage" vs "Damaged / lost"
  });
  static ShopFeatures of(String shopType) => switch (shopType) { ... };
}
```

```python
# backend/app/core/shop_features.py
SHOP_FEATURES = {
    "regular":  Features(has_supplies=False, has_variants=False, ...),
    "bakery":   Features(has_supplies=True,  has_production=True, ...),
    "boutique": Features(has_variants=True,  has_line_pricing=True, has_returns=True, ...),
}
```

`Authenticated.features` and `ShopOption.features` getters replace
`isBakery` at call sites over time (keep `isBakery` as a thin alias so the
migration can be gradual). This is the single most valuable refactor in the
plan: the fourth shop type (pharmacy? electronics?) then costs a table entry.

---

## 3. Data model

### 3.1 Backend (PostgreSQL) — migration `0013_boutique`

```sql
-- shops: widen the accepted set (validators live in code, not a CHECK)
--   backend/app/api/v1/shops.py:74  pattern "^(regular|bakery)$"  -> add boutique
--   backend/app/schemas/auth.py:29  {"regular", "bakery"}         -> add boutique

CREATE TABLE styles (
  id                     UUID PRIMARY KEY,
  shop_id                UUID NOT NULL REFERENCES shops(id),
  name                   VARCHAR NOT NULL,           -- "Slim jeans"
  brand                  VARCHAR,                    -- "Levi's" / "Turkish"
  category               VARCHAR,                    -- reuses product categories
  segment                VARCHAR,                    -- men | women | kids | unisex (nullable)
  image_url              VARCHAR,
  default_selling_price  NUMERIC(12,2) NOT NULL,
  default_purchase_price NUMERIC(12,2) NOT NULL DEFAULT 0,
  size_set               VARCHAR,                    -- preset key, see 6.2 (nullable = custom)
  sku_prefix             VARCHAR(8),                 -- "JN"  -> JN-32-BLU
  client_updated_at      TIMESTAMPTZ,
  created_at/updated_at/deleted_at                   -- TimestampMixin + SoftDeleteMixin
);
CREATE INDEX styles_shop_idx ON styles(shop_id) WHERE deleted_at IS NULL;

ALTER TABLE products
  ADD COLUMN style_id          UUID REFERENCES styles(id),
  ADD COLUMN size              VARCHAR,
  ADD COLUMN color             VARCHAR,
  ADD COLUMN sku               VARCHAR,
  ADD COLUMN min_selling_price NUMERIC(12,2);        -- NULL = no haggling floor

CREATE INDEX products_style_idx ON products(style_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX products_sku_uq
  ON products(shop_id, sku) WHERE deleted_at IS NULL AND sku IS NOT NULL;
-- COALESCE so a NULL size or colour still dedupes (Postgres treats NULLs as distinct)
CREATE UNIQUE INDEX products_variant_uq
  ON products(style_id, COALESCE(size, ''), COALESCE(color, ''))
  WHERE deleted_at IS NULL AND style_id IS NOT NULL;

ALTER TABLE sale_items
  ADD COLUMN list_price NUMERIC(12,2);               -- price before any line discount; NULL = same as unit_price

-- Partial returns / exchanges (Phase 2)
CREATE TABLE sale_returns (
  id               UUID PRIMARY KEY,
  shop_id          UUID NOT NULL REFERENCES shops(id),
  sale_id          UUID NOT NULL REFERENCES sales(id),
  user_id          UUID NOT NULL REFERENCES users(id),
  shift_id         UUID REFERENCES shifts(id),
  occurred_at      TIMESTAMPTZ NOT NULL,
  refund_amount    NUMERIC(12,2) NOT NULL,           -- money handed back (0 for even exchange)
  refund_method    VARCHAR,                          -- cash | mobile_money | NULL when netted into exchange
  exchange_sale_id UUID REFERENCES sales(id),        -- the replacement sale, if any
  reason           VARCHAR,                          -- wrong_size | defect | changed_mind | other
  note             TEXT,
  created_at       TIMESTAMPTZ NOT NULL
);
CREATE TABLE sale_return_items (
  id            UUID PRIMARY KEY,
  return_id     UUID NOT NULL REFERENCES sale_returns(id) ON DELETE CASCADE,
  sale_item_id  UUID NOT NULL REFERENCES sale_items(id),
  quantity      NUMERIC(12,3) NOT NULL,
  condition     VARCHAR NOT NULL,                    -- resellable | damaged
  unit_price    NUMERIC(12,2) NOT NULL               -- credited per unit (= sale_items.unit_price)
);
-- sales.status gains 'partially_returned'. status is a plain VARCHAR today;
-- check 0001_initial.sql for a CHECK and widen it if present (same landmine
-- as inventory_logs.movement in 0009).

ALTER TABLE shops ADD COLUMN return_window_days INTEGER NOT NULL DEFAULT 7;
```

RLS: every new table gets the tenant policy from `0006_rls_enforce`
(`shop_id = current_setting('app.current_shop_id')`). `sale_return_items`
has no `shop_id`; give it the same treatment `sale_items` got in 0006
(policy via join, or add a denormalised `shop_id` — copy whichever 0006 did).

Model mirroring rule (from the lots wave): backend tests build the schema with
`Base.metadata.create_all`, not migrations. **Any CHECK or unique constraint
added in SQL must also be declared on the SQLAlchemy model**, or tests pass on a
schema production doesn't have.

### 3.2 Mobile (Drift) — schema v11

- `StylesTable` (`styles`) mirroring the above; money as int64 santim like
  `ProductsTable`.
- `ProductsTable` + `styleId`, `size`, `color`, `sku`, `minSellingPrice`
  (nullable). `SaleItemsTable` + `listPrice` (nullable int santim).
- `SaleReturnsTable`, `SaleReturnItemsTable` (Phase 2).
- `onUpgrade`: `if (from < 11) { createTable(styles); addColumn ×5 on products;
  addColumn on sale_items; createTable ×2 returns; _createIndexes(); }` in
  [app_database.dart](../mobile/lib/core/storage/app_database.dart#L91).
- Indexes: `products(style_id)`, unique `(style_id, size, color)`, `products(sku)`.

### 3.3 Composed variant name (shared rule, both sides)

```
name = style.name
     + (size  != null ? " · " + size  : "")
     + (color != null ? " · " + color : "")
sku  = style.sku_prefix + "-" + sizeCode(size) + "-" + colorCode(color)
```

`sizeCode` = size uppercased, spaces removed ("32", "XL", "40"); `colorCode` =
first 3 letters of the *Latin* colour name when the colour is Latin, else the
full colour string (Ethiopic has no meaningful 3-letter abbreviation and
barcode-free shops write the tag by hand anyway). Implement once in
`mobile/lib/core/shop_type/variant_naming.dart` and
`backend/app/core/variant_naming.py`, with a parity test on a fixture list
— the same pattern `units.py` / `unit_conversion.dart` already follow.

---

## 4. Sync ops

New ops in `_handler_for`
([sync_service.py:251](../backend/app/services/sync_service.py#L251)) and in
`domainsForOp`
([sync_reconciler.dart:60](../mobile/lib/features/sync/data/sync_reconciler.dart#L60)).

| Op | Payload (essentials) | Sensitive (owner PIN for cashier)? | Reconciler domains |
|---|---|---|---|
| `style.create` | style fields + `variants: [{id, size, color, barcode?, selling_price?, purchase_price?}]` | yes (same as `product.create`) | `{styles, products}` |
| `style.update` | style fields; server **recomposes `name`/`sku` of live variants** when `name` or `sku_prefix` changes; optional `apply_price_to_variants` | yes | `{styles, products}` |
| `style.delete` | `id`; soft-deletes the style and all variants **only if every variant has stock 0** (else `DomainError("style_has_stock")`) | yes | `{styles, products}` |
| `style.add_variants` | `style_id`, `variants: [...]` — add sizes/colours to an existing style | yes | `{styles, products}` |
| `product.create` / `product.update` | + optional `style_id`, `size`, `color`, `sku`, `min_selling_price` | unchanged | unchanged |
| `sale.create` | items gain optional `list_price`; **server enforces the floor** (see §7) | conditionally: any `unit_price < floor` requires `owner_challenge`, mirroring credit-over-threshold | unchanged |
| `sale.return` | `id`, `sale_id`, `items: [{sale_item_id, quantity, condition}]`, `refund_amount`, `refund_method`, `exchange_sale_id?`, `reason`, `occurred_at` | yes for cashier (as `sale.refund` today) | `{products, lots}` |

Design notes:

- `style.create` is **one event** that creates 1 style + N products
  atomically. Do not emit N `product.create` events — a half-applied matrix is
  worse than none, and the pull side refreshes the whole products domain
  anyway. Idempotency: if `styles.id` exists, return (same as `_product_create`).
- Variant stock in `style.create` is always 0. Opening stock arrives via
  `stock.receive` per variant so it gets a lot and a cost (the 0008/v8
  opening-balance backfill only covers pre-existing rows). The wizard UI still
  shows a "starting qty" grid and emits the receives right after, in the same
  local transaction.
- `sale.return` reuses the lot-reversal logic of `_sale_refund`, but
  **per `sale_item_id`**: `lot_consumptions` already carry `sale_item_id`, so
  partial reversal is a filtered version of the full one.
  `condition = damaged` → do **not** restore the lot; write a spoilage
  consumption (`movement='spoilage'`, reason `return_damaged`) so the loss is
  visible in the adjustments/spoilage report rather than silently vanishing.
- An exchange is `sale.return` + a normal `sale.create` linked by
  `exchange_sale_id` (the return references the new sale; `sale.create` itself
  stays untouched). Emit the return **after** the sale so the FK resolves on
  the server. Netting: the new sale's `discount` carries the return credit
  applied, so `sales.total` is what the customer actually paid and shift cash
  reconciliation ([docs/13](13-shift-reconciliation.md)) needs only one new
  term: cash `refund_amount` from returns. Audit both sides with an
  `AuditLog` `sale.exchange` row.
- Keep `sale.refund` (full) exactly as is for backward compatibility; the
  forced-upgrade client makes retiring it later possible.
- Cross-device gap: a return needs the original sale's items. Sales are not a
  pull domain today, so a sale made on phone A is not in phone B's SQLite. Use
  `GET /v1/sales/{id}` (exists in `sales.py`) as the fallback when the local row
  is missing; queue the return offline against the fetched snapshot. This is the
  same shape as the debt payment-history gap already noted for half payments.

Pull side: add `SyncDomain.styles` with a `refreshStyles` job hitting a new
`GET /v1/styles` (paginated like `/v1/products`, owner-only cost fields masked
the same way `_dump` masks `purchase_price`).

---

## 5. Backend API additions

| Endpoint | Purpose |
|---|---|
| `GET /v1/styles` | pull domain; `?q=&category=&segment=`; includes `variant_count`, `stock_total`, `sizes_out` (count of variants at ≤ threshold) |
| `GET /v1/styles/{id}` | style + variants matrix (for the picker when local is stale) |
| `GET /v1/sales/{id}/returns` | returns recorded against a sale (sale detail screen) |
| `GET /v1/reports/size-curve?style_id=&from=&to=` | received vs sold vs on-hand per size (and per colour) |
| `GET /v1/reports/dead-stock?days=60` | variants with on-hand > 0 and no sale in N days; age from oldest open lot `received_at`; value at lot cost |
| `GET /v1/reports/broken-runs` | styles with ≥1 variant at 0 while others have stock — the buying list |
| `GET /v1/reports/returns?from=&to=` | return rate, reasons mix, damaged value, per cashier |
| `GET /v1/reports/price-leakage?from=&to=` | Σ(list_price − unit_price)×qty per cashier/style — how much haggling is costing |
| `GET /v1/reports/dashboard` | boutique branch of `low_stock`: count of styles with broken runs instead of product count |
| `GET /v1/exports/products.csv` / `POST …/import` | add `style`, `brand`, `size`, `color`, `sku`, `min_selling_price` columns; import groups rows by `style` name (+brand) and creates styles on the fly |
| `PATCH /v1/shops/settings` | `return_window_days` (0–90) |

All report endpoints are owner-only (`VIEW_REPORTS`), same as the batch and
expiry reports.

---

## 6. Mobile UI

### 6.1 Shop-type plumbing (small, do first)

- `register_shop_screen.dart` `_ShopTypeSelector`: third card, icon
  `Icons.checkroom_rounded`, l10n `registerTypeBoutiqueLabel/Desc`.
- `Authenticated.shopType`, `ShopOption.shopType`: no schema change (string),
  add `features` getter; `shop_switcher_sheet.dart` icon mapping.
- `home_shell.dart`: boutique uses the **regular** nav (Sell, Inventory,
  Debts, Shift, Dashboard/Settings). No Supplies, no Handover tab.
- `employees_screen.dart`: role picker stays owner/cashier (baker hidden —
  already keyed on bakery).
- Product edit/detail: hide unit picker (locked to `piece`), hide expiry on
  receive, relabel spoilage as "Damaged / lost", hide production and recipe.
- Bakery-only l10n strings stay; boutique gets its own keys where the wording
  differs.

### 6.2 Style wizard (create a style with its variant matrix)

Route `/inventory/new-style` (owner, or cashier with PIN — same gate as new
product). Steps on one scrolling screen:

1. Name, brand (optional), category chips (existing categories), segment
   chips (Men / Women / Kids / Unisex), photo (existing `image_picker` upload).
2. Default selling price, default cost (owner only — cost masked for cashier
   per role matrix), optional min selling price (floor for haggling).
3. **Size set** preset chips (each preset is a constant list in the app, not in
   the DB — the chosen key is stored so "add missing sizes" can offer the rest):
   - Letter: XS S M L XL XXL 3XL
   - Numeric (EU, tops/dresses): 34 36 38 40 42 44 46 48
   - Waist (trousers): 26 28 30 32 34 36 38 40 42
   - Shoe EU: 35 … 46
   - Kids age: 0–3m 3–6m 6–12m 1y 2y 3y 4y 6y 8y 10y 12y 14y
   - Free size (single variant)
   - Custom (free text, comma separated)
   The owner can deselect sizes they did not buy.
4. Colours: free text chips (Amharic input allowed — "ቀይ", "ጥቁር" — search
   folding already handles Ethiopic), optional; no colours = one variant per
   size.
5. Preview grid (sizes as columns, colours as rows) with an optional starting
   quantity per cell and one landed cost for the batch. Save emits
   `style.create` (+ N `stock.receive` if quantities were entered, as one local
   transaction and a batch of sync events).

Later: `/inventory/style/:id` shows the matrix with stock per cell, tap a cell
→ variant product detail; buttons **Add sizes/colours** (`style.add_variants`),
**Receive shipment** (§6.4), **Edit style**, **Mark down** (Phase 3).

### 6.3 POS for variants

- `watchProductsProvider` output is grouped by `styleId` in the POS grid: one
  tile per style (style image, name, price, "Σ stock · N sizes" badge, red dot
  when a size run is broken). Products without a style render as today.
- Tapping a style tile opens a **variant picker sheet**: colour rows × size
  chips, each chip shows on-hand count, greyed at 0 (boutique keeps the hard
  stock gate — no oversell, unlike bakery). One tap adds the variant to the
  cart and closes the sheet; long-press stays open for multi-add.
- Search: typing "jeans 32" matches composed names via existing folding;
  typing/scanning an exact `sku` or `barcode` adds that variant directly
  (exact match check runs before the name filter in `products_dao.watchAll`).
- Recent strip already keys on `sale_items` → shows variants, works as is.
- Quantity steppers are integer-only for boutique (`unit == piece`).
- Cart line shows the composed name (so size/colour are visible on receipt
  and in `recent_sales`/`sale_detail` without changes).

### 6.4 Receiving by matrix

`bulk_restock_screen.dart` gains a "By style" mode for boutique: pick a style,
enter quantities per cell, one unit cost, one note ("Dubai shipment 12/09").
Emits one `stock.receive` per non-zero cell (existing op, existing lot
semantics — per-batch margins in `/reports/batches` then work for apparel
out of the box). Expiry field hidden.

### 6.5 Returns and exchanges (Phase 2)

From `sale_detail_screen.dart` (route `/recent-sales/:id`): button **Return /
exchange** (cashier → PIN challenge, as refund today). Sheet:

1. Tick items and quantities to return; per item choose **Resellable** or
   **Damaged**.
2. Reason chips: wrong size · defect · changed mind · other.
3. Choose **Refund** (cash / mobile money; amount = credit) or **Exchange**
   → opens the POS with the credit pinned in the cart bar; checkout settles the
   difference either way.
4. Outside `return_window_days` → owner PIN (the challenge flow already exists).
5. Receipt share (`receipt_share.dart`) gains a returns block: returned lines,
   credit, new lines, amount paid/refunded.

Sale status chip in recent sales: `partially_returned`.

### 6.6 Line pricing / haggling (Phase 3)

- In `cart_review_sheet.dart` `_CartLineTile`: tap price → "Sold at" dialog.
  `CartLine` gains `unitPrice` (defaults to `product.sellingPrice`);
  `sales_repository.submit` writes `unit_price = line.unitPrice`,
  `list_price = product.sellingPrice`.
- Floor = `product.minSellingPrice ?? sellingPrice` (no floor set = no
  discount without PIN). Below the floor: owner proceeds; cashier gets the PIN
  challenge (client), and the server rejects a below-floor line without
  `owner_challenge` (`DomainError("below_price_floor")`). Never below cost for
  anyone except owner (clearance is a deliberate owner action).
- **Mark down**: style-level action that sets a new `default_selling_price`
  and pushes it to variants (`style.update` with `apply_price_to_variants`),
  storing the previous price in the audit row so the price-leakage report can
  distinguish "clearance" from "haggled".

---

## 7. Roles and permissions

No new role. Additions to the matrix in [docs/17-roles.md](17-roles.md):

| Capability | Cashier | Owner |
|---|---|---|
| Create style / add variants (`style.create`, `style.add_variants`) | 🔑 PIN | ✅ |
| Edit / delete style | 🔑 PIN | ✅ |
| Sell at negotiated price ≥ floor | ✅ | ✅ |
| Sell below floor | 🔑 PIN (server-enforced) | ✅ (audited) |
| Partial return / exchange within window | 🔑 PIN | ✅ |
| Return outside window | 🔑 PIN | ✅ (audited) |
| Mark down a style | ❌ | ✅ |
| Size-curve / dead-stock / returns / leakage reports | ❌ | ✅ |

Capabilities: reuse `MANAGE_PRODUCTS` for styles, `REFUND` for returns,
`SELL` for line pricing. No new capability constants in `capabilities.py`;
gating is via `SENSITIVE_OPS` + the conditional challenge in `_sale_create`.

---

## 8. Localisation

- New ARB keys in `app_en.arb`, `app_am.arb`, `app_om.arb`. The parity test
  (`l10n_parity_test.dart`) fails the build if any key is missing or an Amharic
  value is not Ethiopic — that is the safety net; expect ~80–120 new keys.
- Terms needing native review (Amharic and Afaan Oromo): style, variant,
  size, colour, exchange, return, refund, damaged, mark-down, size run,
  layaway/hold, floor price. Register: the informal-masculine flag on the
  existing Amharic set applies here too — keep the same register for
  consistency and put the whole file through one review.
- Size labels stay Latin/numeric everywhere (that is how tags are written in
  Ethiopian shops). Colours are user text.

---

## 9. Migrations and landmines (from the previous waves)

1. Backend: `0013_boutique` revises `0012_shop_members`. `alembic/env.py` must
   keep the `conn.commit()` before `context.configure` — without it every
   incremental migration silently rolled back once before.
2. Mirror every SQL constraint on the SQLAlchemy model (tests use
   `create_all`).
3. Check `0001_initial.sql` for a CHECK on `sales.status`; if present, widen it
   for `partially_returned` (same as `0009_widen_movement_check`).
4. RLS policy on every new table (0006 pattern), including a `shop_id`-less
   child table.
5. Mobile Drift `schemaVersion` 10 → 11; regenerate with `build_runner` (use
   the drift_dev crash workaround from the half-payments wave).
6. Deploy order: server first (unknown ops are rejected by the server but
   skipped safely by old clients via the reconciler `default:` branch); bump the
   forced-upgrade minimum once line pricing ships so no client can push an
   un-floored `sale.create`.
7. Widen the two `shop_type` validators (`shops.py:74`, `schemas/auth.py:29`),
   the `/shops` "open second shop" endpoint, and the `conftest.py` fixtures.
8. `reports.py` `dashboard.low_stock` has a bakery branch — add the boutique
   branch (broken runs) rather than a third copy of the product query.

---

## 10. Phased delivery

| Phase | Scope | Size | Value |
|---|---|---|---|
| **0 — Plumbing** | `boutique` in validators/enums, registration card, `ShopFeatures` table on both sides, `isBakery` → features refactor at the ~30 call sites, hide bakery/expiry UI for boutique, unit locked to piece, "Damaged / lost" label | 1–2 days | Unblocks everything; also pays down the `isBakery` debt |
| **1 — Styles & variants** | Migration 0013 (styles + product columns), Drift v11, `style.*` ops, `/v1/styles`, style wizard, size presets, matrix screen, POS grouped grid + variant picker, SKU/barcode exact match, receive-by-matrix, CSV columns, SKU parity test | 1.5–2 weeks | The reason a boutique would install the app |
| **2 — Returns & exchanges** | `sale_returns` tables, `sale.return` op with per-item lot reversal and damaged handling, `return_window_days`, return/exchange sheet, exchange netting through POS, receipt block, `/reports/returns`, cross-device sale fetch fallback | 1–1.5 weeks | Second most common daily pain |
| **3 — Pricing controls** | `CartLine.unitPrice`, `list_price`, `min_selling_price`, floor challenge (client + server), mark-down action, `/reports/price-leakage` | 3–5 days | Directly protects margin |
| **4 — Boutique analytics** | size-curve, dead-stock ageing, broken-runs list, dashboard low-stock branch, style-level top sellers | 3–5 days | Turns lots data the app already has into buying decisions |
| **5 — Optional** | Barcode camera scanning (`mobile_scanner`, new dependency, camera permission — many shops have no barcodes so SKU typing comes first), "Hold / layaway" label on credit sales (reuses debts + half-payment chips), customer size preferences on the debt customer record | as needed | Nice-to-have |

Phase 0+1 is a shippable boutique. Phases 2–4 are independent of each other
after Phase 1 and can be reordered by owner feedback.

---

## 11. Tests

Backend (`backend/tests/test_boutique.py`, scratch-Postgres pattern from the
hardening pass — never the live Neon URL):

- `style.create` creates style + N products atomically; duplicate event is a
  no-op; duplicate `(style_id, size, color)` rejected.
- `style.update` renaming recomposes variant names and SKUs; unchanged
  variants keep `client_updated_at`.
- `style.delete` refuses when any variant has stock.
- `sale.return` partial: only the returned item's lot consumption is reversed;
  `damaged` writes a spoilage consumption and does not restore stock; sale
  status flips to `partially_returned`; returning more than was sold, or the
  same quantity twice, is rejected.
- Exchange: return + new sale net correctly; shift expected cash includes
  cash refunds.
- `sale.create` with `unit_price < min_selling_price` → rejected for cashier
  without challenge, accepted with; owner always accepted and audited.
- Boutique dashboard `low_stock` counts broken runs.
- `GET /v1/styles` masks `default_purchase_price` for cashier.
- RLS: a second shop cannot read another shop's styles or returns.
- Variant-naming parity fixture (Python).

Mobile (`mobile/test/…`):

- `variant_naming_test.dart` — same fixture as Python.
- `style_wizard_test.dart` — Letter set × 2 colours produces 14 variants,
  deselecting sizes shrinks the matrix, custom sizes parse.
- `variant_picker_test.dart` — 0-stock chip disabled; tap adds correct product.
- `pos_screen_test.dart` — boutique grid groups by style; SKU exact match.
- `home_shell_roles_test.dart` — boutique nav equals regular nav.
- `product_edit_screen_test.dart` — boutique hides unit/expiry/recipe.
- `return_sheet_test.dart` — netting maths for refund vs exchange.
- `l10n_parity_test.dart` — passes unchanged (guards the new keys).
- Drift migration test v10 → v11 on a seeded DB (existing products keep
  working with null style columns).

---

## 12. Open questions for the owner

1. **Sizes with no colours vs colours with no sizes** — bags and accessories
   often vary only by colour. The model allows either to be null; confirm the
   wizard should let you skip sizes entirely.
2. **Return window default** — 7 days? Some shops allow exchange only, never
   cash refund. Consider a second setting `allow_cash_refund` (default true).
3. **Below-cost sales by owner** — allowed and audited (clearance), or hard
   blocked? Plan assumes allowed for owner only.
4. **Cashier visibility of the floor price** — showing the floor tells the
   cashier how low they may go; hiding it means every haggle below list needs
   a PIN. Plan assumes the floor is shown to the cashier while cost stays masked.
5. **Barcodes** — does the target shop print tags? If yes, Phase 5 scanning
   moves up; if no, SKU typing is enough.
6. **Layaway** — is "hold with deposit" common enough to deserve reserving
   stock *without* a sale (a new `reservation` concept), or is a credit sale
   with the goods kept behind the counter acceptable? Plan assumes the latter.

---

## 13. Wire contract (authoritative for Phases 0–3)

Approved 2026-09-16. Backend and mobile implement exactly this; where the
prose above and this section differ, this section wins. Money is a decimal
string on the wire (as everywhere), quantities are decimal strings, ids are
UUID strings, timestamps ISO-8601 UTC.

### 13.1 Shop features

`shop_type ∈ {regular, bakery, boutique}`. Feature table, identical on both
sides (`backend/app/core/shop_features.py`,
`mobile/lib/core/shop_type/shop_features.dart`):

| feature | regular | bakery | boutique |
|---|---|---|---|
| has_supplies | no | yes | no |
| has_production | no | yes | no |
| has_handovers | no | yes | no |
| tracks_expiry | yes | yes | no |
| allows_oversell | no | yes | no |
| has_variants | no | no | yes |
| has_line_pricing | no | no | yes |
| has_returns | no | no | yes |
| default_unit | piece | piece | piece |
| locks_unit (unit picker hidden, always piece) | no | no | yes |
| spoilage label | Spoilage | Spoilage | Damaged / lost |
| nav | Sell·Inventory·Debts·Shift·Owner/Me | Sell·Inventory·Supplies·Shift·Owner/Me | same as regular |

Unknown shop_type → regular features (fail safe).

### 13.2 Variant naming (shared rule, parity-tested)

```
composeVariantName(styleName, size, color):
    parts = [trim(styleName)] + [trim(size) if non-empty] + [trim(color) if non-empty]
    return join(parts, " · ")          # U+0020 U+00B7 U+0020
```

SKU is **client-composed** and server-stored (the server never derives it):

```
composeSku(prefix, size, color):
    if prefix is empty → null
    P = upper(trim(prefix))
    S = upper(remove-whitespace(size))            # "" if size null
    C = color null → ""
        color matches ^[A-Za-z][A-Za-z ]*$ → upper(first 3 letters of first word)
        else → remove-whitespace(color)           # Ethiopic etc. kept verbatim
    return join(non-empty [P, S, C], "-")         # "JN-32-BLU", "JN-XL", "BAG-ቀይ"
```

Client resolves SKU collisions inside one style by extending the Latin colour
code to 4, 5… letters, then appending "2", "3"…. On `style.update` with a new
`sku_prefix`, the server rewrites each live variant's `sku` by replacing the
old `P-` prefix with the new one (null stays null).

### 13.3 Sync ops

All new `style.*` ops and `sale.return` are in `SENSITIVE_OPS`. Capabilities:
`style.*` → `MANAGE_PRODUCTS`, `sale.return` → `REFUND`. Reconciler domains:
`style.*` → `{styles, products}`, `sale.return` → `{products, lots}`.

**`style.create`**
```json
{
  "id": "<uuid>", "name": "Slim jeans", "brand": "Levi's|null", "category": "Jeans|null",
  "segment": "men|women|kids|unisex|null", "image_url": "https://…|null",
  "default_selling_price": "1200.00", "default_purchase_price": "800.00",
  "size_set": "letter|numeric|waist|shoe_eu|kids_age|free|custom|null",
  "sku_prefix": "JN|null", "client_updated_at": "<iso>",
  "variants": [
    {"id": "<uuid>", "size": "32|null", "color": "Blue|null", "sku": "JN-32-BLU|null",
     "barcode": "…|null", "selling_price": "1200.00", "purchase_price": "800.00",
     "low_stock_threshold": "1", "min_selling_price": "1000.00|null"}
  ],
  "owner_challenge": "<token, optional>"
}
```
Server: idempotent on `id`. 1 ≤ variants ≤ 200, no duplicate `(size, color)`
inside the payload (→ `invalid_payload`). Each variant becomes a `products`
row: `name` = composed, `stock = 0`, `unit = piece`, `category = style.category`,
`image_url = null` (display inherits the style image), `client_updated_at` =
payload's. `purchase_price`/`default_purchase_price` are owner-only: a
non-owner omits them and the server stores 0.

**`style.update`**
```json
{"id": "<uuid>", "client_updated_at": "<iso>",
 "name"?: "…", "brand"?: …, "category"?: …, "segment"?: …, "image_url"?: …,
 "default_selling_price"?: "…", "default_purchase_price"?: "…", "size_set"?: …, "sku_prefix"?: …,
 "apply_price_to_variants"?: false, "owner_challenge"?: "…"}
```
Server: same `client_updated_at` conflict rule as `product.update`. If `name`
changed → recompose every live variant's `name`; if `category` changed →
propagate; if `sku_prefix` changed → rewrite SKUs (13.2); if
`apply_price_to_variants` → set every live variant's `selling_price` to
`default_selling_price` and audit `style.markdown` with old/new price. Touched
variants get `client_updated_at` = payload's.

**`style.add_variants`** — `{"style_id", "client_updated_at", "variants": [...same shape...], "owner_challenge"?}`.
Idempotent per variant `id`; a live variant with the same `(size, color)` →
`variant_exists`.

**`style.delete`** — `{"id", "owner_challenge"?}`. Any live variant with
`stock > 0` → `style_has_stock`; otherwise soft-delete style and variants.

**`product.create` / `product.update`** additionally accept `style_id`,
`size`, `color`, `sku`, `min_selling_price` (all nullable). If a styled
product's `size`/`color` change, the server recomposes `name`.

**`sale.create`** — each item may carry `"list_price": "1200.00"` (the
product's selling price at the time; `unit_price` is what was charged).
Server floor rule, applied only when the shop's features have
`has_line_pricing`:
- `floor = product.min_selling_price` when set, else `product.selling_price`
  **but only if the client declared a discount** (`list_price` present and
  `unit_price < list_price`). With no floor set and no declared discount the
  line is accepted as-is (avoids rejecting stale-cached prices).
- `unit_price < floor` and role ≠ owner and no challenge →
  `OwnerPinRequired(code="below_price_floor")`.
- role = owner and `unit_price < floor` → accepted, one `AuditLog`
  `sale.below_floor` per sale listing the items.
- `unit_price < 0` → `invalid_payload`.

**`sale.return`**
```json
{"id": "<uuid>", "sale_id": "<uuid>", "shift_id": "<uuid>|null", "occurred_at": "<iso>",
 "items": [{"id": "<uuid>", "sale_item_id": "<uuid>", "quantity": "1", "condition": "resellable|damaged"}],
 "refund_amount": "1200.00", "refund_method": "cash|mobile_money|null",
 "exchange_sale_id": "<uuid>|null",
 "reason": "wrong_size|defect|changed_mind|other", "note": "…|null",
 "owner_challenge"?: "…"}
```
Server rules:
- Idempotent on `id`. Sale must exist in the shop and not be `refunded`.
- Per item: `sale_item.sale_id == sale_id`; `quantity > 0`; previously
  returned qty + `quantity` ≤ `sale_item.quantity` else `return_exceeds_sold`.
- Credit per unit = `unit_price × ratio`, quantized to cents, where
  `ratio = min(1, effective_total / sale.subtotal)` and
  `effective_total = sale.total + Σ credit of earlier returns whose
  exchange_sale_id is this sale`. The sale-level discount is shared
  proportionally, but an exchange's credit (which travels as the replacement
  sale's `discount`) is added back so returning an exchanged item credits its
  real value, not the cash top-up. `sale_return_items.unit_price` stores this
  proportional credit per unit. `credit_total = Σ qty × credit_unit`.
  `refund_amount` must be `0 ≤ refund_amount ≤ credit_total` else
  `invalid_payload`. When `exchange_sale_id` is set it must reference an
  existing sale of the shop. `reason` is required and must be one of the four
  values; `sku_prefix` is at most 8 characters.
- `sale.create` never trusts a client `status`; new sales are always
  `completed`. `sale.refund` (legacy full refund) is refused on a
  `partially_returned` sale and `sale.return` is refused on a `refunded` one,
  so the two refund paths are disjoint in shift and revenue math.
- Revenue and profit reports include sales settled through `sale.return`
  (status `refunded` with at least one `sale_returns` row) and subtract
  `refund_amount` in the return's window; gross profit also subtracts the cost
  of resellable returned units (damaged units stay a loss). Legacy
  `sale.refund` sales remain excluded as before.
- Inventory, per item: reverse that item's `sale` lot consumptions FIFO for
  `quantity` (`refund_reversal`, negative qty, lot `qty_remaining += q`),
  `products.stock += quantity`, `inventory_logs` movement `refund`,
  `reference_type = sale_return`, `reference_id = return id`.
  If `condition = damaged`, additionally write a `spoilage` consumption
  (+q, same lot, same unit cost), `products.stock -= quantity`, and an
  `inventory_logs` row movement `spoilage`, reason `return_damaged`. Net stock
  unchanged; the loss is visible in spoilage reporting.
- Sale status → `refunded` if every item is now fully returned, else
  `partially_returned`.
- `occurred_at − sale.occurred_at > shop.return_window_days` and role = owner
  → accepted with `AuditLog` `sale.return_outside_window` (cashiers are
  PIN-gated for every return already).
- Shift reconciliation: cash `refund_amount` counts against the shift's
  expected cash exactly as a full `sale.refund` does today.

Exchange = ordinary `sale.create` for the new items (its `discount` carries the
credit applied, so `sales.total` is what the customer paid) followed by
`sale.return` with `exchange_sale_id` set. `refund_amount = max(0, credit − new_total)`.
Client emits both events in one local transaction, sale first.

### 13.4 REST additions

| Endpoint | Cap | Response |
|---|---|---|
| `GET /v1/styles?q&category&segment&limit&cursor` | VIEW_PRODUCTS | `{items:[{id,name,brand,category,segment,image_url,default_selling_price,default_purchase_price ("0" unless VIEW_COSTS),size_set,sku_prefix,client_updated_at,variant_count,stock_total,sizes_out}], next_cursor, has_more}` keyset on `(name,id)` |
| `GET /v1/styles/{id}` | VIEW_PRODUCTS | style fields + `variants:[product dump]` |
| `GET /v1/products` (existing) | — | product dump gains `style_id,size,color,sku,min_selling_price`; `q` also exact-matches `sku`/`barcode` |
| `GET /v1/sales/{id}` | SELL | `{id,shift_id,user_id,subtotal,discount,total,payment_method,status,occurred_at,items:[{id,product_id,product_name_snapshot,quantity,unit_price,list_price,returned_quantity}],returns:[{id,occurred_at,refund_amount,refund_method,exchange_sale_id,reason,items:[{id,sale_item_id,quantity,condition,unit_price}]}]}`; `profit` only with VIEW_COSTS. Every nested row carries its own `id` so a client caching a remotely fetched sale can dedupe on it rather than minting one. |
| `GET /v1/reports/returns?from&to` | VIEW_REPORTS | `{count, refund_total, damaged_value, by_reason:{…}, by_user:[{user_id,count,refund_total}]}` |
| `GET /v1/reports/price-leakage?from&to` | VIEW_REPORTS | `{leakage_total, lines, by_user:[…], by_style:[{style_id,name,leakage}]}` where leakage = Σ (list_price − unit_price) × qty over items with list_price > unit_price |
| `GET/PATCH /v1/shops/settings` | ADMIN | + `return_window_days` (int, 0–90, default 7); also in `TokenBundle` |
| `GET /v1/reports/dashboard` | VIEW_REPORTS | boutique: `low_stock` = number of styles with ≥1 live variant at `stock ≤ low_stock_threshold` |
| `GET /v1/exports/products.csv`, `POST /v1/exports/products/import` | ADMIN (enforced; previously import was open to MANAGE_PRODUCTS) | columns `style,brand,segment,size,color,sku,min_selling_price` added; import groups rows by `(style, brand)` and creates styles as needed |

### 13.5 Mobile persistence (Drift v11)

`styles` mirrors 13.3 (money int64 santim). `products` + `style_id, size,
color, sku, min_selling_price` (nullable). `sale_items` + `list_price`
(nullable santim). `sale_returns` / `sale_return_items` mirror the server.
`sales.status` may be `partially_returned`. Pull domain `styles` refreshes from
`GET /v1/styles`.

---

## 14. Phase 4 wire contract — boutique analytics

Approved 2026-09-18. Phase 4 turns the batch and sale data the app already
stores into the three questions a boutique owner actually asks: *which sizes
do I need to rebuy*, *what is not moving*, and *which styles earn*. All four
endpoints are owner-only (`VIEW_REPORTS`) and are only offered by the client
when the shop's features have `has_variants`.

Money is a decimal string, quantities are decimal strings, dates are
`YYYY-MM-DD`, and the `from`/`to` window is half-open `[from, to)` like the
existing reports. Returns are netted out of "sold" the same way §13.3 nets
them out of revenue: a resellable return reduces sold and comes back to
on-hand; a damaged return reduces sold and is counted as a loss, not stock.

### 14.1 `GET /v1/reports/size-curve?style_id=&from=&to=`

The buying grid for one style: what was bought, what sold, what is left, per
size and per colour.

```json
{
  "style": {"id": "…", "name": "Slim jeans", "brand": "Levi's|null"},
  "sizes": [
    {"size": "32|null", "received": "12", "sold": "9", "on_hand": "3",
     "sell_through": "0.75", "revenue": "10800.00"}
  ],
  "colors": [
    {"color": "Blue|null", "received": "24", "sold": "15", "on_hand": "9",
     "sell_through": "0.625", "revenue": "18000.00"}
  ],
  "totals": {"received": "48", "sold": "30", "on_hand": "18", "revenue": "36000.00"}
}
```

`received` is Σ `stock_lots.qty_received` for the variant (all time, so the
curve reflects the whole buy, not just the window); `sold` and `revenue` come
from sale items in the window, net of returns. `sell_through` is
`sold / received` rounded to 3 decimals, `"0"` when nothing was received.
Sizes are ordered by the style's `size_set` preset order when it has one,
otherwise lexicographically with numerics first. Unknown `style_id` → 404.

### 14.2 `GET /v1/reports/dead-stock?days=60&limit=&cursor=`

Variants still on the shelf that nothing has sold for `days` days.

```json
{
  "days": 60,
  "items": [
    {"product_id": "…", "name": "Slim jeans · 32 · Blue", "style_id": "…|null",
     "size": "32|null", "color": "Blue|null", "stock": "3",
     "age_days": 104, "last_sold_at": "2026-06-04|null",
     "unit_cost": "800.00", "value": "2400.00"}
  ],
  "total_value": "2400.00",
  "next_cursor": "…|null", "has_more": false
}
```

Included when `stock > 0` and the variant has no sale in the last `days`
days. `age_days` counts from the oldest **open** lot's `received_at` (the
stock actually sitting there), not from the first ever receipt.
`last_sold_at` is null when it has never sold. `value` is `stock ×` the
weighted cost of its open lots, falling back to `purchase_price` for
unlotted stock. Ordered oldest first, then by value descending. `days` is
1..365 (default 60). Cost fields require `VIEW_COSTS`, which owners have.

### 14.3 `GET /v1/reports/broken-runs`

The rebuy list: styles selling well enough that some sizes have run out
while others still have stock.

```json
{
  "items": [
    {"style_id": "…", "name": "Slim jeans", "brand": "…|null", "image_url": "…|null",
     "variant_count": 8, "in_stock_count": 5, "stock_total": "11",
     "missing": [{"size": "32|null", "color": "Blue|null", "sold_30d": "9"}]}
  ]
}
```

A style qualifies when at least one live variant is at or below its
`low_stock_threshold` **and** at least one other live variant is above it —
a style that is entirely sold out is not a broken run, it is simply gone, and
listing it would bury the actionable rows. `missing` carries the depleted
variants with their 30-day sales so the owner rebuys the sizes that actually
move; it is ordered by `sold_30d` descending. Styles are ordered by the
total `sold_30d` of their missing variants, descending.

### 14.4 `GET /v1/reports/top-styles?from=&to=&limit=`

Top sellers rolled up to the style, since a boutique owner thinks in styles,
not in 8 rows of the same jeans.

```json
{
  "items": [
    {"style_id": "…|null", "name": "Slim jeans", "brand": "…|null", "image_url": "…|null",
     "quantity": "30", "revenue": "36000.00", "profit": "12000.00",
     "variant_count": 8}
  ]
}
```

Net of returns, same as `/reports/top-products`. Products with no style are
rolled up individually with `style_id: null` and their own name, so nothing
is hidden. `profit` requires `VIEW_COSTS`. `limit` is 1..50 (default 10).

### 14.5 Mobile

A "Boutique" section appears in the reports screen for `has_variants` shops,
above the existing sections, holding: the rebuy list (broken runs) as the
first and most actionable card, dead stock with its total value, and top
styles. The size curve opens per style from the style screen and from a
broken-run row, rendered as a bar per size with sold against received. Each
view is read-only, owner-only, fetched on demand, and shows a plain empty
state rather than an error when the shop has no data yet. No new Drift
tables: these are live report reads like the existing batch report.
