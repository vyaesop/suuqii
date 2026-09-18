# 04 — API design

Versioned under `/v1`. JSON only. All times ISO-8601 with timezone. Money as strings to dodge float weirdness in JS clients (Flutter parses to `Decimal` via the `decimal` package).

## Conventions

- Auth: `Authorization: Bearer <access_token>` except where noted.
- Errors: RFC 7807 problem details
  ```json
  { "type": "about:blank", "title": "Conflict", "status": 409, "detail": "stock would go negative", "code": "stock_negative" }
  ```
- Pagination: cursor-based (`?cursor=...&limit=50`). Never offset — sales tables grow.
- All POSTs accept an optional `Idempotency-Key` header (UUID); duplicates return the original response with `200`.

## Auth

### `POST /v1/auth/register-shop`
Body:
```json
{ "shop_name": "Suuq #1", "owner_name": "Abebe", "phone": "+2519...", "password": "..." }
```
→ creates shop + owner user. Returns `{access, refresh, user, shop}`.

### `POST /v1/auth/login`
Body: `{ "phone": "+2519...", "password": "..." }`
→ `{access, refresh, user, shop}`. Access TTL 1h, refresh TTL 30d.

### `POST /v1/auth/refresh`
Body: `{ "refresh": "..." }` → new pair. Old refresh revoked (rotating).

### `POST /v1/auth/invite` (owner only)
Body: `{ "name": "Kebede", "phone": "+251...", "role": "cashier" }`
→ returns one-time `invite_code` (8-digit). Owner reads it to employee in person.

### `POST /v1/auth/accept-invite`
Body: `{ "invite_code": "12345678", "password": "..." }` → tokens.

### `POST /v1/auth/devices/:id/revoke` (owner only)
Revoke a stolen device. Tokens rejected on next refresh.

### `POST /v1/auth/owner-pin/verify`
Body: `{ "pin": "1234" }` → `{ "ok": true, "challenge_token": "..." }`.
Sensitive operations (price change, large credit) require this token in `X-Owner-Challenge`.

## Sync

The **only** mutating path for offline-capable entities. Direct CRUD endpoints below are for **owner web/desktop usage** and for hydration; the mobile app never POSTs directly to `/products` etc., only via sync.

### `POST /v1/sync/push`
Body:
```json
{
  "device_id": "abc123",
  "events": [
    {
      "client_event_id": "uuid-v4",
      "op": "sale.create",
      "occurred_at": "2026-05-16T10:30:00+03:00",
      "payload": { /* full sale object incl. items */ }
    },
    {
      "client_event_id": "uuid-v4",
      "op": "product.update",
      "occurred_at": "...",
      "payload": { "id": "...", "selling_price": "12.50", "client_updated_at": "..." }
    }
  ]
}
```
Response:
```json
{
  "results": [
    { "client_event_id": "...", "status": "applied" },
    { "client_event_id": "...", "status": "conflict", "resolution": "server_wins", "server": {...} },
    { "client_event_id": "...", "status": "rejected", "code": "owner_pin_required" }
  ],
  "server_cursor": "1234567"
}
```
**Idempotency**: `(shop_id, client_event_id)` is unique. Re-pushing returns the prior result.

### `GET /v1/sync/pull?cursor=...&limit=200`
Pulls events the client doesn't have yet. Response includes events from *other devices* in the same shop so multiple cashiers stay consistent.
```json
{
  "events": [ { "op": "...", "payload": {...}, "applied_at": "..." } ],
  "next_cursor": "1234890",
  "has_more": false
}
```

### Supported `op` values
| Op | Notes |
|---|---|
| `sale.create` | full sale + items + stock decrement implied |
| `sale.refund` | reverses sale, restores stock |
| `sale.void` | owner only; soft-deletes |
| `product.create` | |
| `product.update` | LWW by `client_updated_at`; price changes need `X-Owner-Challenge` |
| `product.delete` | soft, owner only |
| `inventory.adjust` | delta-based; owner only or audited |
| `debt.create` | usually piggybacks on `sale.create` with `payment_method=credit` |
| `debt.payment.create` | |
| `debt.writeoff` | owner only |
| `expense.create` | |
| `shift.open` | |
| `shift.close` | computes variance server-side, returns it |
| `style.create` | boutique: one style + N variant products atomically (docs/19 §13.3); PIN for cashiers |
| `style.update` | LWW by `client_updated_at`; recomposes variant names/SKUs; `apply_price_to_variants` = mark-down (audited) |
| `style.add_variants` | idempotent per variant id; `variant_exists` on a live duplicate |
| `style.delete` | soft-deletes style + variants; `style_has_stock` if any variant has stock |
| `sale.return` | partial return / exchange per `sale_item_id`; per-lot reversal; PIN for cashiers (docs/19 §13.3) |

## Direct read endpoints (owner dashboard, hydration)

### `GET /v1/products`
Query: `?q=&category=&low_stock=true&cursor=&limit=`
Returns active products for this shop. `q` matches the name fuzzily and
`sku`/`barcode` exactly. Dump includes `style_id, size, color, sku,
min_selling_price` (null for plain products).

### `GET /v1/styles` (boutique pull domain, docs/19 §13.4)
Query: `?q=&category=&segment=&cursor=&limit=`; keyset on `(name, id)` like
products. Items carry `variant_count`, `stock_total`, `sizes_out` (variants at
or below their threshold). `default_purchase_price` is `"0"` without
`VIEW_COSTS`.

### `GET /v1/styles/{id}`
Style fields plus `variants: [product dump]`.

### `GET /v1/sales/{id}` (SELL)
One sale with `items[]` (incl. `list_price`, `returned_quantity`) and
`returns[]`. `profit` only with `VIEW_COSTS`. This is the cross-device fallback
for the return sheet when the sale is not in the phone's local DB.

### `GET /v1/sales/{id}/returns` (SELL)
`{items: [return…]}` for one sale.

### `GET /v1/sales`
Query: `?from=&to=&user_id=&payment_method=&cursor=&limit=`

### `GET /v1/debts?status=open`

### `GET /v1/shifts?user_id=&from=&to=`

### `GET /v1/audit?from=&to=&action=&user_id=&entity_id=`
Owner only. Append-only feed of every mutation.

### `GET /v1/reports/dashboard?range=today|7d|30d`
Single endpoint feeding the owner dashboard. Aggregates from `sales_daily_mv`.
```json
{
  "range": "today",
  "revenue": "1234.50",
  "profit": "234.10",
  "expenses": "45.00",
  "net_profit": "189.10",
  "sale_count": 23,
  "credit_sales": "100.00",
  "outstanding_debt": "850.00",
  "low_stock": [ { "id": "...", "name": "...", "stock": "1.0" } ],
  "top_products": [ { "id": "...", "name": "...", "qty": 12, "revenue": "400.00" } ],
  "trend": [ { "day": "2026-05-15", "revenue": "..." }, ... ]
}
```

### `GET /v1/reports/returns?from=&to=` (VIEW_REPORTS)
`{count, refund_total, damaged_value, by_reason:{…}, by_user:[{user_id,count,refund_total}]}`.
Default window: last 30 days. `damaged_value` is at unit cost.

### `GET /v1/reports/price-leakage?from=&to=` (VIEW_REPORTS)
`{leakage_total, lines, by_user:[…], by_style:[{style_id,name,lines,leakage}]}` where
leakage = Σ (list_price − unit_price) × qty over lines with `list_price > unit_price`.

### `GET /v1/reports/dashboard` — boutique `low_stock`
For `shop_type = boutique` each `low_stock` entry is a *style* with a broken
size run (`{id, name, stock, sizes_out}`), not a product.

### Returns netting in revenue / profit reports
`dashboard`, `sales-series`, `top-products`, `payment-mix` and
`cashier-performance` all account for `sale.return` the same way
`ShiftService.expected_cash` does:
- A sale returned through `sale.return` stays in revenue at its full total —
  even once every line is back and its status reads `refunded` — and the money
  handed back (`Σ sale_returns.refund_amount`, in the period the return
  *occurred*) is subtracted from revenue. The dashboard exposes that figure as
  `refund_total`.
- Gross profit gets the cost of **resellable** returned units back (they are
  stock again); a **damaged** unit keeps its cost as the loss it is. To count
  that loss once, the dashboard's `spoilage_cost` line excludes the spoilage
  consumptions written by damaged returns (`/reports/returns.damaged_value`
  still shows them).
- Legacy full `sale.refund` sales (no `sale_returns` row) stay excluded from
  revenue exactly as before; `cashier-performance.refund_count/refund_total`
  combine legacy refunds and returns, attributed to the sale's cashier.
- Per-day (`sales-series`) and per-method (`payment-mix`) netting keys on the
  return's day and the original sale's payment method respectively.

### `GET/PATCH /v1/shops/settings`
Adds `return_window_days` (int, 0–90, default 7). Also returned in the login /
refresh `TokenBundle`.

### `GET /v1/export/products.csv` / `POST /v1/export/products/import`
Both **ADMIN (owner-only)**, like `sales.csv`: an import rewrites purchase
prices and creates styles wholesale with no per-row PIN, which
`MANAGE_PRODUCTS` alone (cashiers hold it) must not be able to do. Columns gain
`style, brand, segment, size, color, sku, min_selling_price`. Import groups
rows by `(style, brand)`, creates styles on the fly, composes variant names
(docs/19 §13.2) and stores `sku` as given. Cashiers get 403.

## Rate limits

| Endpoint | Limit |
|---|---|
| `/auth/login` | 10 / min / IP, 5 / hour / phone |
| `/auth/refresh` | 60 / min / device |
| `/auth/owner-pin/verify` | 5 / min / user (after 5 failures, lock for 15 min) |
| `/sync/push` | 60 / min / device |
| `/sync/pull` | 120 / min / device |
| everything else | 100 / min / user |

## OpenAPI

FastAPI serves `/openapi.json`. Mobile codegen via `openapi-generator` produces `lib/core/api/generated/` (gitignored). We use it for typed DTOs only; repository code is still hand-written for sync logic.
