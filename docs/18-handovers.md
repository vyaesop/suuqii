# 18 — Baker handovers

A handover is **two independent counts of the same transfer**: the baker
declares what they carried to the counter, whoever is on the counter counts what
actually arrived, and the difference is attributable to two named people and a
shift.

This is the stock analogue of `shifts` — declared vs expected cash with a
generated `variance` column — and it is modelled the same way deliberately, so
the owner reads it with a habit they already have.

## Why it exists

A real client's bakery ledger (26 consecutive days, one row per product per
day) recorded a single number for "sold". 11 of 196 rows did not balance
against their own opening/production/leftover figures, and 26 carry-forward
breaks meant yesterday's leftover disagreed with today's opening. On one day
18 units went unaccounted for. With one person writing one number there is
nothing to reconcile against — the gap has nowhere to show up.

## What it does *not* do

**A handover moves no stock.** `production.record` already created the units and
bumped `products.stock`; the counter's sale decrements it. The goods never leave
the shop, so a handover that also moved stock would double-count. The rows are a
control artefact, not an inventory movement.

This also keeps the offline story simple: the baker's device and the counter's
device are different phones, and the counter can sell whether or not the
handover has synced yet.

## Data model

```
handovers        id, shop_id, from_user_id, to_user_id, accepted_by_user_id,
                 shift_id, occurred_at, accepted_at, status, note,
                 accept_note, device_id, created_at
handover_items   id, shop_id, handover_id, product_id,
                 product_name_snapshot, qty_handed, qty_received,
                 variance  -- GENERATED ALWAYS AS (qty_received - qty_handed)
```

`status`: `pending` → `accepted` (every line matched) | `disputed` (any line
differed). `variance` is a stored generated column so the two counts can never
disagree with their own difference. Both tables carry the same forced tenant RLS
as everything else (migration `0011_baker_handovers`).

On the client, `variance` is *not* stored — SQLite computes it in the query, so
there is one definition per side and no chance of a stale local copy.

## Sync ops

| Op | Actor | Capability | Owner PIN |
|---|---|---|---|
| `handover.create` | baker | `handover_create` | no |
| `handover.accept` | counter | `handover_accept` | no |

Neither is PIN-gated: they are daily work, and a PIN on every handover would
train staff to skip them.

**The person who handed over cannot accept.** Enforced in
`sync_service._handover_accept`, not only in the UI — if one person could do
both, the two counts collapse into one and the control is worth nothing.
`ROLE_CAPS` reinforces it: a baker holds `HANDOVER_CREATE` and not
`HANDOVER_ACCEPT`.

A partial count is rejected (`incomplete_count`): a handover with an uncounted
line has no meaningful variance. A second accept returns `CONFLICT` with the
server's state. A disputed handover also writes an `AuditLog` row
(`handover.variance`) so it surfaces the day it happens rather than at month-end.

## Ingredient timing (changed in 0011)

Ingredients are deducted by `production.record`, for the **full produced
quantity**. Previously only spoiled units deducted at production and the rest
deducted at sale time via `supply_deductions` on `sale.create`.

That was wrong in a way the client's data shows plainly: one product was baked
30 on day one, sold 17 across the next thirteen days, and still had 13 on the
shelf at the end. Under sale-time deduction, the flour for those 13 stayed
counted as unused flour in the store room for thirteen days.

Consequences of the change:

- Bakery products now carry real `products.stock`. Production adds, sales
  subtract, refunds restore — bakery converges with the regular flow, and the
  `if (!isBakery)` branches through the POS, sales repository and sync service
  are gone.
- Bakery sales consume their production lot FEFO. They previously skipped lot
  consumption entirely, so production lots sat at full `qty_remaining` forever
  and bakery batch reports were meaningless.
- COGS for a bakery sale comes from the recipe-costed lot, server-authoritative,
  instead of being recomputed from recipes per sale on the client.
- Refunds restore stock and the lot but **never** the ingredients. The flour was
  used when the dough was mixed; a returned loaf does not put it back in the sack.
- `sale.create` ignores any `supply_deductions` it still receives and logs it.
  **`settings.min_app_version` must be raised in the same deploy** so older
  clients stop sending it — otherwise a straggler's deductions are silently
  dropped and its ingredient counts drift upward.

There is no data migration: past events were applied under the old rule, so the
change only affects events applied from here on.

## Stock gate

For bakery shops the POS stock check is a **warning, not a block**. The counter's
view of stock is only as current as the baker's last synced handover, and they
are on different devices; blocking would let a sync delay stop a sale during the
morning rush. Regular shops still hard-block. See `posBakeryStockWarning`.

## Counting blind

The accept sheet hides the baker's declared quantity behind a "Reveal" tap. If
the counter sees the expected number first, an independent count becomes a
confirmation — which is the failure the whole feature exists to prevent.

## Reads

- `GET /v1/handovers?status=` — the counter's pending list.
- `GET /v1/handovers/variance-report?range=` — owner only. Attributes gaps per
  baker with both **net** and **gross** (Σ|variance|) unit counts. Net can cancel
  out across days; gross cannot, so gross is the honest measure.
