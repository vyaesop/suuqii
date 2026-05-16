# 12 — Offline-first strategy

## The thesis

In the target environment — small Ethiopian retail shops on cheap Android phones — connectivity is **fragile by default**. Mobile data is metered and expensive, Wi-Fi is rare, and even when available it cuts out for minutes at a time. An app that asks "is the network up?" before doing work has already failed.

This system flips the default: **every operation that doesn't strictly need the network completes against the local DB**. The network is for sync, not for serving the user.

## Operations and their connectivity needs

| Operation | Offline? | Why |
|---|---|---|
| Open the app, see inventory | ✓ | Drift cache |
| Make a sale (cash / mobile / credit) | ✓ | Local write + sync queue |
| Refund a sale | ✓ | Same |
| Adjust stock | ✓ | Same |
| Open/close shift | ✓ | Local; variance computed locally and re-verified server-side |
| Add expense | ✓ | Same |
| Collect debt payment | ✓ | Same |
| Search products | ✓ | Drift indexes |
| View today's KPIs | ✓ (own device) | Computed from local DB |
| Login | ✗ | Initial token must be issued by server |
| Refresh access token | ✗ | But if access not expired, fine offline |
| Invite employee | ✗ | Code must be server-issued |
| Owner PIN sensitive ops | ✗ | Challenge token from server |
| Cross-device visibility (see other cashier's sales) | ✗ | Needs sync to land |
| Owner dashboard analytics for date ranges | ✗ when not cached | Falls back to last cached snapshot |
| Audit log reads | ✗ | Always live (auditor expectation) |

## Write paths

Every write is **local-first**. The repository pattern:

1. Validate input against domain rules.
2. Open Drift transaction.
3. Mutate authoritative local table(s).
4. Enqueue a sync event in `sync_events`.
5. Commit.
6. Kick the sync worker (it may or may not have network).
7. Return success to the UI immediately.

If step 7 happens before step 6 ever talks to the network, that's correct behaviour. The UI does not show "syncing..." spinners for normal operations.

## Read paths

All reads are from Drift. Background sync updates Drift via:
- Pulling events from `/v1/sync/pull` and replaying them as upserts.
- For aggregated reports the owner wants live (dashboard ranges, audit), the API is queried directly; offline we show the last cached snapshot with a stale-since timestamp.

## What the user sees

| Connectivity state | UI cue |
|---|---|
| Online, queue empty | No badge. |
| Online, queue draining | Small spinner near top with "Syncing 12 changes". |
| Offline, queue empty | Slim "Offline" banner (only after 5+ min offline). |
| Offline, queue building | "12 changes pending — will sync when online" badge. |
| Sync failure (auth, rejection) | Red badge → tap → details screen. |

The app never shows a blocking "no internet" dialog.

## Conflict resolution (recap from sync engine doc)

| Class of write | Strategy |
|---|---|
| Inserts with client UUIDs | Always merge cleanly (server stores as-is) |
| Updates on rows | LWW by `client_updated_at`, server logs both pre-images in audit |
| Stock changes | Delta-applied; negatives flagged but accepted |
| Closes (shifts, sales) | First-wins; second is rejected with code |

The user is **never asked** to resolve a conflict mid-flow. Owner sees the result in the audit feed and decides what (if anything) to do.

## Data integrity guarantees

- **Atomicity**: SQLite transactions are ACID. A sale either fully happens or not at all.
- **Durability**: SQLite `journal_mode=WAL`, `synchronous=NORMAL`. Power loss preserves committed transactions; in-flight rolls back.
- **Crash recovery**: app restart finds queued events and resumes sync. Idempotency keys mean replay-on-restart is safe.
- **No silent loss**: every mutation has a `sync_events` row until acked. The badge surfaces the count.

## Storage budget

- Empty Flutter app: ~30MB.
- Drift DB with 500 products + 1 month of sales (~10k sales, ~30k items): ~25MB.
- Photos cached: optional; default product images are off. With photos at ~100KB each × 500: ~50MB.
- 6 months of data: ~150MB worst case.

Cheap Android phones have 16–32GB storage. We're fine. We do not preemptively prune; the owner can "archive" old months via Settings (moves to compressed JSON in app-internal storage; rare op).

## Bandwidth budget

A sale event ≈ 1KB of JSON. A daily push of 200 sales + auxiliary events ≈ 300KB. A monthly bandwidth cost per device is in single-MB territory, well within an Ethio Telecom prepaid plan.

Pull is similar size, dominated by what other devices pushed.

## Testing offline

`integration_test/offline_sync_test.dart`:
1. Login.
2. Toggle network off (via test harness).
3. Perform 50 sales, 10 stock adjustments, 5 debt collections.
4. Assert all visible in UI.
5. Toggle network on.
6. Wait for queue to drain (poll `sync_events` count).
7. Assert backend received all 65 events with correct shop_id and user_id.
8. Toggle off again, refund a sale, toggle on, verify refund lands.

This test runs on every PR.
