# 13 — Shift reconciliation

## What it solves

At the end of a shift, the cashier counts the physical cash in the drawer. The system computes what *should* be there. The difference (variance) is what the owner cares about — it's either honest counting error, miscounted change, or theft. Surfacing it consistently is what turns the app into an accountability tool.

## Lifecycle

```
       open                                         close
 ┌──────────┐                ┌─ sales (cash) ──┐  ┌──────────┐
 │ Opening  │                │ sales (mobile)  │  │ Declared │
 │  cash    │ ───────────────│ sales (credit)  │──│  cash    │  → compare
 │ (input)  │                │ debt payments   │  │ (input)  │
 └──────────┘                │ expenses        │  └──────────┘
                             └─────────────────┘
```

## Database (recap)

```sql
shifts (
  id, shop_id, user_id,
  opened_at, closed_at,
  opening_cash,
  declared_closing_cash,
  expected_closing_cash,
  variance GENERATED AS (declared_closing_cash - expected_closing_cash),
  note,
  ...
)
```

## Expected cash formula

```
expected_closing_cash =
    opening_cash
  + sum(sales.total WHERE shift_id = X AND payment_method = 'cash' AND deleted_at IS NULL)
  + sum(debt_payments.amount WHERE shift_id = X AND method = 'cash')
  - sum(expenses.amount WHERE shift_id = X)   -- assumed paid from till
  - sum(refunds.amount WHERE shift_id = X AND payment_method = 'cash')
```

Mobile money sales **do not** affect cash. Credit sales **do not** affect cash. Refunds against non-cash original payments are excluded.

## Open shift

```
POST /sync/push  (event: shift.open)
{
  "id": "<uuid>",
  "user_id": "<self>",
  "opening_cash": "500.00",
  "opened_at": "2026-05-16T08:00:00+03:00",
  "device_id": "..."
}
```

Mobile validates: no other open shift for this user. Backend re-validates.

Until close:
- Every sale this user makes is stamped `shift_id = current_shift_id` (locally and on the wire).
- Every expense the user logs goes against this shift.

## Close shift

Cashier taps "End shift" → counts cash → enters declared amount.

Mobile:
1. Compute `expected` locally (Drift query, instant).
2. Show breakdown sheet:
   ```
   Opening cash         500.00
   Cash sales         + 3,420.00
   Debt collected     +   250.00
   Expenses           -    80.00
   Refunds (cash)     -   100.00
   ─────────────────────────────
   Expected           = 3,990.00
   Declared (entered)   3,975.00
   ─────────────────────────────
   Variance              -15.00
   ```
3. Optional note field (cashier explains: "gave too much change to customer X").
4. Confirm → enqueue `shift.close` event.

Backend re-computes expected from authoritative data (in case the local DB missed an event from another device touching this shift — rare but possible). If server expected ≠ client expected, the server value wins and the audit captures both.

## Variance handling

Thresholds, configurable per shop:
- |variance| ≤ ETB 5 → green, dismissable.
- ETB 5 < |variance| ≤ ETB 50 → yellow, requires note.
- |variance| > ETB 50 OR > 5% of cash sales → red, push notification to owner; cashier may close but it's flagged in audit immediately.

The system **does not block** closing a shift on variance — preventing close would just lead to "leave the shift open forever" workarounds. Surfacing > preventing.

## What about credit sales and mobile money?

Tracked separately on the shift summary screen:
- Cash sales — affects cash variance.
- Mobile money sales — recorded against a per-user mobile money account total; reconciled by the owner against their telebirr/CBE statement.
- Credit sales — go to `debts` table; their later cash collection lands in the *collecting* cashier's shift, not the original sale's.

This matches how shop owners actually think about money.

## Edge cases

| Case | Behaviour |
|---|---|
| Cashier forgets to close shift before going home | Shift stays open; next morning a "Shift not closed" notification reminds them. Owner can force-close from their device after a configurable timeout (default 18h). |
| Cashier closes shift on phone A, but phone B had unsynced sales | Phone B's late sales still carry `shift_id = X`. On sync, server detects shift X is closed; appends them but flags `late_shift_event` audit anomaly. Owner reviews. |
| Two cashiers share a till (split shift mid-day) | Each opens their own shift with their own opening cash. The till's physical state must be recounted at each handoff — the system can't physically count cash. |
| Power dies during close | Shift remains open; cash count not lost (typed values are kept in a draft until commit). Reopen → resume close flow. |
| Cashier puts the till's cash in their pocket and lies about declared cash | Variance will be negative and large; flagged immediately to owner. Audit log shows declared amount with timestamp. Repeat offenders are visible in the dashboard "anomalies" panel. |

## Reports

Owner dashboard → Shifts tab shows last 30 shifts with: user, opened, closed, total sales (cash/mobile/credit broken out), variance, note, anomaly flags. Tap into one for full sales list during that shift.

Aggregate metric on dashboard: **avg variance / cashier / week** — surfaces who is sloppy or worse over time.
