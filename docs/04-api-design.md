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

## Direct read endpoints (owner dashboard, hydration)

### `GET /v1/products`
Query: `?q=&category=&low_stock=true&cursor=&limit=`
Returns active products for this shop.

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
