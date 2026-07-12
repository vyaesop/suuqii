# 16 — Inventory lots: batch costing, spoilage, expiry

## Why lots

A shop buys 10 sodas at 10 birr and sells them at 15; restocks 10 more at 13
and sells at 16. Weighted-average costing (Loyverse-style) blends the two
costs and the owner can never see which batch made what margin. We use
**purchase lots with FIFO/FEFO consumption** (the Odoo/Lightspeed model):

- Every stock receipt creates a **lot**: quantity, unit cost, optional
  expiry date.
- Sales consume lots **FEFO** (first-expiry-first-out) when expiry dates
  exist, else FIFO by receipt time. This is the standard strategy for
  food/pharma retail.
- Each consumption is recorded (`lot_consumptions`), so per-batch margin is
  exact: batch A: 10 sold × (15 − 10); batch B: sold × (16 − 13).
- COGS for a sale item = weighted cost of the lots it consumed. The server
  recomputes this at sync-apply time (client values are advisory, same as
  sale totals).

## Data model

```
stock_lots
  id UUID PK, shop_id, product_id,
  qty_received NUMERIC, qty_remaining NUMERIC,
  unit_cost NUMERIC(12,2),          -- santim int on mobile
  expiry_date DATE NULL,
  received_at timestamptz, note TEXT NULL, created_by UUID

lot_consumptions
  id UUID PK, shop_id, lot_id FK,
  sale_item_id UUID NULL,           -- set for sales
  movement TEXT,                    -- 'sale' | 'spoilage' | 'adjustment' | 'refund_reversal'
  quantity NUMERIC,                 -- positive = consumed from lot
  unit_cost NUMERIC(12,2),          -- lot cost at consumption time
  consumed_at timestamptz
```

`supplies.expiry_date DATE NULL` — ingredients (flour, milk) expire too;
supplies stay quantity-tracked without lots (v1 keeps them simple).

Invariant (regular shops): `product.stock ≈ Σ lots.qty_remaining`. Stock can
still go negative (oversell is recorded, per docs/06); consumption beyond
available lots clamps lots at 0 and falls back to `product.purchase_price`
for COGS, flagged `cogs_fallback` in the consumption note.

## Sync ops

| Op | Payload | Effect |
|---|---|---|
| `stock.receive` | id, product_id, quantity, unit_cost, expiry_date?, spoiled_quantity?, note?, occurred_at | Creates lot (qty_remaining = quantity − spoiled). Stock += quantity − spoiled. Spoiled portion recorded as spoilage consumption at unit_cost. Updates product.purchase_price to the new cost (last-cost display). |
| `stock.spoil` | id, product_id, quantity, lot_id?, reason?, occurred_at | Consumes FEFO (or the named lot). InventoryLog movement='spoilage'. Valued at lot cost → waste report. |
| `production.record` | id, product_id, quantity_produced, quantity_spoiled?, note?, occurred_at | **Bakery only.** Stock += produced − spoiled (informational; bakery sales don't decrement stock). Spoiled units deduct supplies per recipe (they consumed ingredients but will never hit a sale, which is where bakery supplies are normally deducted) and are valued at recipe cost as spoilage. |

`inventory.adjust` keeps working: positive delta creates a lot at
`product.purchase_price`; negative delta consumes FEFO.

`sale.refund` reverses the sale's exact lot consumptions (quantities go back
to the same lots), so batch reports stay truthful after refunds.

## Consumption order

```sql
ORDER BY (expiry_date IS NULL), expiry_date ASC, received_at ASC, id ASC
```

## Roles

`stock.receive`, `stock.spoil`, `production.record` are SENSITIVE_OPS:
cashiers need an owner-PIN challenge (same as inventory.adjust). Spoilage is
a classic shrinkage vector — "spoiling" 5 breads and pocketing the cash —
so it stays PIN-gated and always audited.

## Reports

- `GET /v1/reports/batches?product_id=` — per lot: received, cost,
  sold qty, spoiled qty, remaining, revenue, margin.
- `GET /v1/reports/expiring?days=7` — lots + supplies expiring within N
  days or already expired, with quantities and value at risk.
- Spoilage total (units + cost) joins the P&L as a visible waste line.
