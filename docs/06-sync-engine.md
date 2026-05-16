# 06 — Sync engine

## Goals

1. **Zero blocking** — UI never waits on the network.
2. **No data loss** — survive crashes, kills, OOMs, OS upgrades.
3. **Idempotent** — re-sending the same event has the same effect.
4. **Eventually consistent across devices** — two cashiers see each other's sales within seconds of being online.

## Model

The sync layer is event-sourced **at the boundary**. Internally each app uses normal row tables; the sync queue is a thin append-only log of intents that haven't been confirmed by the server yet.

### Local `sync_events` table (Drift)

```sql
CREATE TABLE sync_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_event_id TEXT NOT NULL UNIQUE,      -- UUID v4
  op TEXT NOT NULL,                          -- 'sale.create', etc.
  payload TEXT NOT NULL,                     -- JSON
  occurred_at INTEGER NOT NULL,              -- epoch ms, client clock
  enqueued_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_attempt_at INTEGER,
  last_error TEXT,
  status TEXT NOT NULL DEFAULT 'pending'     -- pending | synced | failed | rejected
);
CREATE INDEX idx_sync_pending ON sync_events(status) WHERE status='pending';
```

### Write path (UI → local DB → queue)

Inside one Drift transaction:
1. Mutate the authoritative local tables (e.g. `sales`, `sale_items`, `products.stock`).
2. INSERT a row in `sync_events` describing the operation.
3. Commit.

Atomicity is enforced by SQLite — either both the data and the event land, or neither.

### Trigger sync

Sources that wake the worker:
- App startup
- Connectivity changes to online (`connectivity_plus`)
- New event enqueued (Riverpod stream wakes the worker if it's idle)
- Periodic `Workmanager` background task (every 15 min when in background)
- Push notification from server (`sync.ping` data message via FCM)

### Worker loop

```
loop forever:
  wait_for_connectivity()
  events = SELECT * FROM sync_events WHERE status='pending' ORDER BY id LIMIT 50
  if empty: sleep_until_signal()
  try:
    response = POST /v1/sync/push { events }
    for r in response.results:
      update local sync_events.status accordingly
      if r.status == 'conflict' and resolution == 'server_wins':
        apply server payload to local table  (LWW)
  catch network or 5xx:
    increment attempts, set last_error
    backoff = min(2^attempts seconds + jitter, 300)
    sleep(backoff)
```

After push succeeds, pull recent events from other devices:
```
since = (SELECT max(server_cursor) FROM sync_meta)
GET /v1/sync/pull?cursor=since
apply each event locally (idempotent — use server-side IDs to detect dups)
update sync_meta.cursor
```

## Conflict resolution

| Op | Strategy | Why |
|---|---|---|
| `product.update` | Last-Writer-Wins by `client_updated_at` | Pricing/name is human-driven, rare collisions |
| `inventory.adjust` | Delta-summed | Each adjust is an absolute delta; just sum them |
| `sale.create` | No conflict possible (insert with unique UUID) | New IDs never collide |
| `sale.refund` | Reject if already refunded | Idempotency check by sale ID |
| `debt.payment.create` | Sum, even if it overpays — flag in audit | Real-world: two people might collect on the same debt |
| `shift.close` | Reject if already closed | One close per shift |

### Stock as a special case

Stock is **not** synced as an absolute value. Each sale and each adjustment carries a **delta**. Server computes:
```
new_stock = current_stock + sum(deltas for this product since last reconcile)
```
This means two cashiers selling the same last unit can result in `stock = -1`. That's intentional:
- It's a real-world event (oversold) — the system records it rather than silently dropping a sale.
- The owner sees a `stock.negative` audit anomaly.
- Manual stock-take reconciles via an `inventory.adjust` event.

Validating "stock >= quantity" client-side prevents most accidental oversells; the server doesn't re-validate because by the time it gets the event, the sale is already in the customer's bag.

## Failure semantics

| Failure | Local effect | Server effect | Recovery |
|---|---|---|---|
| App killed mid-sale | Drift tx rolls back | nothing | User retypes (rare; happens before commit) |
| App killed mid-push | event stays `pending` | nothing | Retry on next wake |
| Server returns conflict | local row updated to server version | server wins | User notified non-blockingly |
| Server returns `rejected` (e.g. owner PIN required) | event marked `rejected`, surfaced as a notification | nothing | Owner reviews in Audit screen |
| Phone wiped | local state lost | server is authoritative | Re-login pulls everything via `/sync/pull?cursor=0` |

## Capacity

- A busy shop: ~500 sales/day, ~3 events per sale (sale + items implicit + audit + stock movements implicit in payload) → ~500 events/day per device.
- One-week offline: ~3500 events, ~5MB of JSON. SQLite handles this trivially.
- 30-day offline (worst case, broken phone returned after a month) is still under 100MB. We don't optimize for it; we tell the owner that 30 days offline isn't supported.

## What does NOT go through the sync engine

- Auth (login, refresh) — must be online.
- Owner PIN verification — must be online (challenge tokens have 5-minute TTL).
- Reports / dashboard reads — always live from server when online; cached snapshot is shown offline with a "last updated" timestamp.
- Audit log reads — always live.

This keeps the engine small and predictable.
