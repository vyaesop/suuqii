# 11 — Audit log

## Why this exists

Cashiers can mistype prices, sell to friends at cost, "lose" cash on shift close, mark debts as paid that weren't, or quietly delete sales. Paper logs don't help; spreadsheets get edited. The point of this system is to make every mutation **non-deniable** without making honest mistakes shameful.

## Properties

1. **Append-only.** No user role can `UPDATE` or `DELETE` from `audit_logs`. Postgres role permissions enforce this.
2. **Server-stamped.** `created_at` is set by Postgres `now()`, never by client. Client `occurred_at` is kept for forensics but not trusted for ordering.
3. **Trigger-based.** Application code can forget to call the audit logger; database triggers cannot.
4. **Full diff.** Both `old_value` (pre-image) and `new_value` (post-image) are captured as JSONB.
5. **Attribution.** Every row carries `user_id` and `device_id` from session context.

## Captured actions

| Entity | INSERT | UPDATE | DELETE | Special |
|---|---|---|---|---|
| products | ✓ create | ✓ update (price changes flagged) | ✓ delete (soft) | `price.change` derived event |
| sales | ✓ | rare | ✓ refund / void | `sale.delete` is owner only |
| sale_items | ✓ | ✗ | ✗ (cascade) | always paired with parent sale event |
| debts | ✓ | ✓ writeoff | ✓ | `debt.writeoff` flagged |
| debt_payments | ✓ | ✗ | ✗ | |
| expenses | ✓ | ✓ | ✓ | |
| shifts | ✓ open | ✓ close | ✗ | `shift.close` with variance |
| inventory_logs | ✓ | ✗ | ✗ | append-only by design |

## Implementation

### Triggers (Postgres)
Defined in `0001_initial.sql`. One generic `audit_capture()` function attached as `AFTER INSERT/UPDATE/DELETE` on each audited table. See [`docs/03-database-schema.md`](03-database-schema.md#triggers--audit-capture).

The function reads:
- `current_setting('app.current_user_id', true)` — set by FastAPI per request
- `current_setting('app.current_device_id', true)` — same
- Per-row `shop_id`, `id` — from `NEW` or `OLD`

### Per-request session vars (FastAPI)
```python
# backend/app/core/deps.py
async def db_session(user=Depends(current_user), device=Depends(current_device)) -> AsyncSession:
    async with AsyncSessionLocal() as session:
        await session.execute(text("SET LOCAL app.current_user_id = :v"), {"v": str(user.id)})
        await session.execute(text("SET LOCAL app.current_device_id = :v"), {"v": device})
        await session.execute(text("SET LOCAL app.current_shop_id = :v"), {"v": str(user.shop_id)})
        yield session
```

### Derived events
Some mutations need a more meaningful action label than the table-level `products.update`. The service layer writes them explicitly **in addition to** the trigger-generated row:

```python
if old.selling_price != new.selling_price:
    await self._write_audit("price.change", entity_type="product", entity_id=new.id,
        old_value={"price": str(old.selling_price)},
        new_value={"price": str(new.selling_price)})
```

The base trigger row is still there; the derived row is what owners see in their daily audit feed.

## Anomaly detection

Periodic background job scans for patterns the owner should know about. Emits push notifications.

| Anomaly | Detection |
|---|---|
| `stock.negative` | `products.stock < 0` |
| `shift.variance.large` | `\|variance\| > ETB 50 OR \|variance\| > 5% of cash sales` |
| `price.drop.suspicious` | `selling_price < purchase_price * 1.05` (sold at near cost) |
| `sale.delete.cluster` | >3 sale deletions by one user in a day |
| `debt.writeoff.large` | writeoff > shop's debt threshold |
| `login.unusual` | new device, or login outside 6am–11pm local time |

These are surfaces, not policies — the owner decides what to do.

## Owner UX

### AuditScreen (`/owner/audit`)
- Default view: today, all actions, all users.
- Filters: user, action type, entity, date range.
- Row → expand for full JSON diff (pretty-printed, color-coded add/remove).
- Anomaly chip at top showing today's flagged events.

### Read API
```
GET /v1/audit?from=2026-05-15&to=2026-05-16&user_id=&action=&entity_id=&cursor=&limit=50
```

Owner role only. Returns rows with diff:
```json
{
  "id": "...",
  "action": "price.change",
  "actor": { "id": "...", "name": "Kebede" },
  "entity": { "type": "product", "id": "...", "name": "Coca-Cola 300ml" },
  "old": { "price": "20.00" },
  "new": { "price": "18.00" },
  "device_id": "...",
  "created_at": "2026-05-16T11:23:00+03:00"
}
```

## What is **not** in the audit log

- Reads. Querying the inventory or dashboard is not logged. Doing so would 10x storage for low information value.
- Failed actions (e.g. wrong PIN attempt) — these have their own `auth_events` table; out of scope here.
- Sync-layer mechanics (push/pull) — operational logs only.

## Retention

`audit_logs` rows are kept **forever**. For a busy shop, ~1000 rows/day = ~365k/year. JSONB columns average ~500B → 200MB/year. Trivial.

Backups: daily Neon point-in-time + a weekly logical dump to S3-compatible storage (see [14-deployment.md](14-deployment.md)).
