# 17 — Role matrix: owner vs cashier

Two roles only. The owner runs the shop; cashiers sell. Anything that moves
money/inventory *definitions* (not sales) is owner territory; a cashier can
do it only with a fresh owner-PIN challenge, and it is always audited.

| Capability | Cashier | Owner |
|---|---|---|
| POS sale (cash) | ✅ | ✅ |
| POS sale (credit, under customer threshold) | ✅ | ✅ |
| Credit sale over customer threshold | 🔑 PIN | ✅ |
| Refund | 🔑 PIN | ✅ |
| View products / stock levels | ✅ (cost prices masked) | ✅ |
| Create/edit/delete product | 🔑 PIN | ✅ |
| Receive stock (`stock.receive`) | 🔑 PIN | ✅ |
| Record spoilage (`stock.spoil`) | 🔑 PIN | ✅ |
| Record production (`production.record`, bakery) | 🔑 PIN | ✅ |
| Manual stock adjust | 🔑 PIN | ✅ |
| Manage supplies / recipes | 🔑 PIN (recipes: owner-created products only) | ✅ |
| Record expense ≤ threshold | ✅ | ✅ |
| Record expense > threshold | 🔑 PIN | ✅ |
| Collect debt payment | ✅ | ✅ |
| Write off debt | 🔑 PIN | ✅ |
| Open own shift / close own shift | ✅ | ✅ |
| Close someone else's shift | ❌ | ✅ (force-close) |
| View own recent sales | ✅ | ✅ |
| View all sales (with profit) | ❌ (profit hidden) | ✅ |
| Dashboard / reports / batch & expiry reports | ❌ | ✅ |
| Audit log / anomaly scan | ❌ | ✅ |
| Invite/deactivate employees | ❌ | ✅ |
| Revoke device sessions | ❌ | ✅ (own shop only) |
| Change shop settings (thresholds, locale) | ❌ | ✅ |

Enforcement layers, in order of authority:
1. **Server endpoint checks** — role tests on every owner-only route;
   sensitive sync ops require a shop-scoped, single-use PIN challenge token.
2. **Postgres RLS** — tenant isolation backstop (FORCE + WITH CHECK).
3. **Mobile route guards + UI** — cashiers never *see* owner surfaces
   (dashboard, reports, audit, employees, settings). This is UX, not
   security; the server is the boundary.

Scenarios considered:
- Cashier with a stolen owner phone → PIN challenge still required for
  sensitive ops; PIN attempts are rate-limited and DB-lockout enforced.
- Owner PIN verified in shop A cannot authorize ops in shop B (challenge
  token carries shop_id).
- Cashier logging out with unsynced sales → blocked with explicit warning.
- Deactivated cashier → `is_active=false` fails `current_user` on every
  request; refresh token dies with the device session revoke.
- Cashier trying to read cost prices via API → `purchase_price` masked in
  list responses; reports endpoints are owner-only outright.
