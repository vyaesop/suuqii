# 15 — Production scaling

This system is designed for **a few hundred shops** in its first year. This doc describes what breaks first as that scales, in roughly the order it will.

## Capacity assumptions

| Tier | Shops | Cashiers/shop | Sales/day/shop | Sales/day total | DB write rate (peak) |
|---|---|---|---|---|---|
| Pilot | 5 | 2 | 100 | 500 | trivial |
| Small | 50 | 2 | 200 | 10,000 | ~5 writes/sec sustained, 20/sec peak |
| Medium | 500 | 3 | 200 | 100,000 | ~50/sec sustained, 200/sec peak |
| Large | 5,000 | 3 | 200 | 1,000,000 | needs partitioning |

## What breaks first, in order

### 1. Vercel cold starts (around tier "small")
**Symptom**: first `/sync/push` after idle takes 2–4s.
**Fix**: move to a long-running host (Render, Fly.io, Railway). FastAPI doesn't change. Vercel was a convenience, not a requirement. Migration is a couple of hours of work.

### 2. `audit_logs` table grows (tier "small → medium")
**Symptom**: index bloat slows owner audit queries.
**Fix**:
- Add monthly **table partitioning** on `created_at`:
  ```sql
  CREATE TABLE audit_logs_2026_05 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
  ```
- Move partitions older than 12 months to a cheaper archive tier (still queryable).

### 3. Dashboard query latency (tier "medium")
**Symptom**: owner dashboard takes >2s on Friday afternoons.
**Fix**:
- `sales_daily_mv` materialized view (already designed) is refreshed every 15 min.
- Add `sales_hourly_mv` for "today" view.
- Cache `/v1/reports/dashboard` in Redis for 60s per `(shop, range)` key.

### 4. Single Postgres write hotspot on `products.stock` (tier "medium")
**Symptom**: row-level lock contention during peak hours on popular products.
**Fix**:
- Stop updating `products.stock` directly. Move to event-sourced stock:
  ```sql
  -- products.stock becomes:
  SELECT COALESCE(SUM(quantity_delta), 0) FROM inventory_logs WHERE product_id = ?
  ```
- Maintain a denormalized cache in `products.stock_cached` updated by a trigger with batched aggregation.
- Inventory writes are append-only (no contention).

### 5. Sync push payload size (tier "medium" for slow networks)
**Symptom**: cashiers returning from 2+ days offline take 30+s to drain.
**Fix**:
- Compress requests (`Content-Encoding: gzip`) — Dio supports it.
- Stream pull with `?limit=200` chunks.
- Add a "force resync" flow that pulls a full snapshot in batches rather than replaying every event.

### 6. JWT refresh storms (tier "medium")
**Symptom**: at 9am opening, hundreds of devices refresh simultaneously, spiking `/auth/refresh`.
**Fix**:
- Stagger access TTL: 60 min ± random 5 min per device. Done in code, no infra change.
- Add a small Redis (Upstash) for refresh-token revocation list.

### 7. Push notification throughput (tier "medium")
**Symptom**: low-stock alerts to 500 owners take minutes.
**Fix**: FCM batched send (multicast); already supported. Move notification generation to a background queue (RQ/Arq) at this point.

### 8. Single shop with extreme volume (any tier)
**Symptom**: one supermarket-sized customer with 50 cashiers, 5000 sales/day.
**Fix**:
- This is **out of target scope** (the product is for small shops).
- If we want them anyway: introduce `shop_partition_id`, route writes per shop to a dedicated Postgres branch, federate reads via a thin BFF.

### 9. Multi-branch feature lands (planned product change)
**Symptom**: not a scaling break, but a model break. `shops.parent_shop_id` was reserved; now we need real cross-branch reporting.
**Fix**:
- Introduce `organizations` table; `shops` becomes a child of an organization.
- Inventory transfers between branches → new sync op `inventory.transfer`.
- Backend OK; mobile gets a "branch picker" in the home shell. Backwards-compatible.

### 10. Going multi-region (tier "large")
**Symptom**: not really applicable for an Ethiopia-only product, but listed for completeness.
**Fix**: stay single-region (likely Frankfurt or Mumbai for Ethiopia latency); regional sharding is more complexity than this product warrants.

## What we deliberately don't do prematurely

- **Microservices.** One FastAPI app handles all of this. We split only when service-level concerns (deploy cadence, ownership) actually diverge — not for scaling.
- **Kafka / event bus.** Postgres `LISTEN/NOTIFY` is enough for any cross-process eventing we need at every tier listed above.
- **gRPC.** REST + JSON is fine. Mobile networks don't benefit from gRPC's wire format enough to justify the dev cost.
- **Custom auth service.** JWT + Postgres is enough for 10,000+ users.
- **Caching everything.** Cache the dashboard endpoint; everything else is fast enough or already cached locally on the device.

## Cost projection (rough)

| Tier | Neon | Vercel / Render | FCM | R2 | Total/month |
|---|---|---|---|---|---|
| Pilot (5 shops) | free | free | free | <$1 | ~$0 |
| Small (50) | $19 | $20 | free | $1 | ~$40 |
| Medium (500) | $69 | $100 | free | $5 | ~$175 |
| Large (5,000) | $300+ (custom) | $500 | $0 (under free limits) | $20 | ~$1,000 |

Per-shop cost trends down sharply with scale — the architecture is fine for the business model.

## When to revisit this doc

- Crossing **50 active shops**: review items 1, 2.
- Crossing **500 active shops**: review items 3–7.
- Adding multi-branch: review item 9.
- Adding web admin: not in this doc — the FastAPI backend just serves another client, no schema changes needed.
