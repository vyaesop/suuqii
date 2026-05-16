# 01 — Architecture

## System context

```
┌────────────────────────────────────────────────────────────────────┐
│                          Shop floor (offline)                      │
│  ┌───────────────────────┐         ┌───────────────────────┐       │
│  │  Owner phone (Android)│         │  Cashier phone        │       │
│  │  Flutter + Drift      │         │  Flutter + Drift      │       │
│  │  ▾ SQLite (truth-     │         │  ▾ SQLite             │       │
│  │    until-synced)      │         │                       │       │
│  └─────────┬─────────────┘         └─────────┬─────────────┘       │
└────────────┼─────────────────────────────────┼─────────────────────┘
             │ HTTPS (when online, batched)    │
             ▼                                 ▼
        ┌──────────────────────────────────────────────────┐
        │   FastAPI on Vercel (Python serverless)          │
        │   ── /auth, /sync, /products, /sales, ...        │
        │   ── JWT, rate limit, RLS-by-shop_id             │
        └────────────────────┬─────────────────────────────┘
                             │ asyncpg
                             ▼
                ┌──────────────────────────┐
                │   Neon PostgreSQL        │
                │   ── append-only audit   │
                │   ── sync_events log     │
                │   ── materialized views  │
                └──────────────────────────┘
                             │
                             ▼
                ┌──────────────────────────┐
                │   Firebase Cloud Msgs    │
                │   (low-stock, debt due)  │
                └──────────────────────────┘
```

## Layers (per app)

### Mobile (clean architecture, per feature)

```
presentation/   Riverpod providers, GoRouter routes, screens, widgets
    ↑ depends on
domain/         entities (Freezed), use cases, repository interfaces
    ↑ depends on
data/           repository impl, drift DAOs (local), Dio clients (remote), DTOs + mappers
```

Rule: `domain/` imports nothing app-specific. `data/` and `presentation/` depend on `domain/`, never on each other.

### Backend (FastAPI)

```
api/v1/         FastAPI routers, request validation
    ↓ calls
services/       business logic, transaction boundaries
    ↓ calls
db/ + models/   SQLAlchemy ORM, session per request
```

Each service is a plain Python class with injected `AsyncSession`. No framework leakage into services.

## Data flow: a sale

```
[Cashier taps "Checkout"]
        │
        ▼
SalesController.checkout()                          presentation
        │
        ▼
SubmitSaleUseCase.execute(cart, payment)            domain
        │
        ▼
SaleRepository.create(saleDraft)                    data
        │ in a single SQLite transaction:
        │   1. INSERT INTO sales (..., synced=0)
        │   2. INSERT INTO sale_items (...)
        │   3. UPDATE products SET stock = stock - qty
        │   4. INSERT INTO inventory_logs (movement='sale')
        │   5. INSERT INTO debts (...) if payment=credit
        │   6. INSERT INTO sync_events (op='sale.create', payload=...)
        │   7. INSERT INTO audit_logs (...)
        ▼
SyncWorker (background isolate) wakes              sync
        │ when connectivity returns:
        │   POST /v1/sync/push  { events: [...] }
        ▼
FastAPI /sync/push                                  backend
        │   for each event, in one DB tx:
        │     - replay into authoritative tables
        │     - resolve conflicts (last-writer-wins per row,
        │       except stock which is delta-based)
        │     - return per-event ack { client_id, server_id }
        ▼
Mobile marks events synced=1, swaps client UUIDs   sync
```

**Critical invariant**: the local SQLite write is the source of truth until acked by the server. The UI never blocks on network; sync is an eventual reconciliation.

## Identity model

- Every mutable row has a `id UUID` (v4, generated client-side).
- Server **never reassigns** IDs; client UUID becomes canonical.
- This eliminates the "swap temp ID for real ID" class of bugs.
- `sync_events.client_event_id` (UUID) is the idempotency key — re-pushing the same event is a no-op.

## Multi-tenancy

- Every row carries `shop_id`.
- JWT claims include `shop_id` and `role`.
- FastAPI dependency `current_shop()` extracts it; every query is filtered by it.
- Postgres RLS policies enforce this as a second line of defence (see [03-database-schema.md](03-database-schema.md)).

## Failure modes (and what handles them)

| Failure | Owner | Mitigation |
|---|---|---|
| Phone dies mid-sale | Drift | SQLite tx is atomic; either whole sale lands or none |
| Phone lost / stolen | Backend | JWT refresh tokens revocable per device; sales already synced are safe |
| Network flaky for hours | Sync worker | Exponential backoff with jitter, capped at 5 min |
| Two cashiers sell last unit at same time | Sync server | Stock is delta-applied server-side; final stock may go to -1 → flagged in `audit_logs.anomalies` for owner review |
| Clock skew on cheap phone | Backend | Server timestamps audit_logs; client `occurred_at` retained but not trusted for ordering |
| Sync server returns 500 | Mobile | Event stays queued, retried; UI shows discrete "X unsynced" badge, never blocks |
| Postgres down | Backend | FastAPI returns 503; mobile retries; no data loss |

## Why these choices (vs alternatives)

- **Drift over Isar/Hive**: needs schema migrations as the product evolves; Drift gives Alembic-style versioned migrations.
- **FastAPI over Next.js routes**: sync logic needs long, transactional handlers; Vercel's Python runtime handles 10s+ tx better than edge JS for this pattern. Next.js routes were considered but rejected for risk of cold-start during checkout sync.
- **JWT over sessions**: shop devices may go offline for days; refresh tokens issued long (30d) per device, short access tokens (1h).
- **UUID v4 over autoincrement**: required for offline ID generation. The space cost (16 bytes vs 8) is irrelevant at the scale of a single shop.
- **Riverpod over Bloc**: less boilerplate, codegen catches errors at compile time, and the team is small.
