# 17 — Role matrix: owner, cashier, baker

Three roles. The owner runs the shop; cashiers sell; bakers produce and hand
over. Anything that moves money/inventory *definitions* (not sales) is owner
territory; a cashier can do it only with a fresh owner-PIN challenge, and it is
always audited.

Roles are **deny by default**. `app/core/capabilities.py` is the single source
of truth: a role holds a capability only if it is listed, and an unknown role
holds nothing. Before this the model was binary (`role != "owner"`), so any new
role would silently have inherited every cashier permission including the till.

`baker` is only invitable in a shop whose features include production
(`features_for(shop_type).has_production` — today only `bakery`; see
`app/core/shop_features.py`, which replaced the scattered `== "bakery"` checks).

| Capability | Cashier | Baker | Owner |
|---|---|---|---|
| POS sale (cash) | ✅ | ❌ | ✅ |
| POS sale (credit, under customer threshold) | ✅ | ❌ | ✅ |
| Credit sale over customer threshold | 🔑 PIN | ❌ | ✅ |
| Refund | 🔑 PIN | ❌ | ✅ |
| View products / stock levels | ✅ (cost prices masked) | ✅ (costs masked) | ✅ |
| Create/edit/delete product | 🔑 PIN | ❌ | ✅ |
| Receive stock (`stock.receive`) | 🔑 PIN | ❌ | ✅ |
| Record spoilage (`stock.spoil`) | 🔑 PIN | ❌ | ✅ |
| Record production (`production.record`, bakery) | 🔑 PIN | ✅ (no PIN — it's the job) | ✅ |
| Declare handover (`handover.create`) | ❌ | ✅ | ✅ |
| Count in a handover (`handover.accept`) | ✅ | ❌ | ✅ |
| Manual stock adjust | 🔑 PIN | ❌ | ✅ |
| View supplies / ingredient levels | ✅ | ✅ | ✅ |
| Manage supplies / recipes | 🔑 PIN (recipes: owner-created products only) | ❌ | ✅ |
| Record expense ≤ threshold | ✅ | ❌ | ✅ |
| Record expense > threshold | 🔑 PIN | ❌ | ✅ |
| Collect debt payment | ✅ | ❌ | ✅ |
| Write off debt | 🔑 PIN | ❌ | ✅ |
| Open own shift / close own shift | ✅ | ✅ | ✅ |
| Close someone else's shift | ❌ | ❌ | ✅ (force-close) |
| View own recent sales | ✅ | ❌ | ✅ |
| View all sales (with profit) | ❌ (profit hidden) | ❌ | ✅ |
| Dashboard / reports / batch & expiry reports | ❌ | ❌ | ✅ |
| Handover variance report | ❌ | ❌ | ✅ |
| Audit log / anomaly scan | ❌ | ❌ | ✅ |
| Invite/deactivate employees | ❌ | ❌ | ✅ |
| Revoke device sessions | ❌ | ❌ | ✅ (own shop only) |
| Change shop settings (thresholds, locale, return window) | ❌ | ❌ | ✅ |
| **Boutique (docs/19 §7)** | | | |
| Create style / add variants (`style.create`, `style.add_variants`) | 🔑 PIN | ❌ | ✅ |
| Edit / delete style (`style.update`, `style.delete`) | 🔑 PIN | ❌ | ✅ |
| Sell at negotiated price ≥ floor | ✅ | ❌ | ✅ |
| Sell below floor (`min_selling_price`, else tag price when a discount is declared) | 🔑 PIN (server-enforced, `below_price_floor`) | ❌ | ✅ (audited `sale.below_floor`) |
| Partial return / exchange within `return_window_days` (`sale.return`) | 🔑 PIN | ❌ | ✅ |
| Return outside window | 🔑 PIN | ❌ | ✅ (audited `sale.return_outside_window`) |
| Mark down a style (`style.update` + `apply_price_to_variants`) | ❌ (server rejects `forbidden`; cost fields are ignored for non-owners on every style op) | ❌ | ✅ (audited `style.markdown`) |
| Returns / price-leakage reports | ❌ | ❌ | ✅ |

Boutique gating reuses existing capabilities — `MANAGE_PRODUCTS` for styles,
`REFUND` for returns, `SELL` for line pricing — plus `SENSITIVE_OPS` and the
conditional challenge inside `_sale_create`. No new capability constants.

**A baker holds `handover_create` and not `handover_accept`, and a cashier the
reverse.** That disjointness is the whole point: two independent counts of the
same transfer. One person holding both collapses them into a self-confirmation.
See docs/18-handovers.md.

Enforcement layers, in order of authority:
1. **Capability check** — `can(role, capability)`, applied at the sync boundary
   before anything else (an op with no capability entry is rejected outright)
   and on HTTP routes via `require_cap`.
2. **Owner PIN** — sensitive sync ops require a shop-scoped, single-use
   challenge token. `ROLE_PIN_EXEMPT` carves out ops that are a role's ordinary
   work: a baker recording production is not a privileged act.
3. **Postgres RLS** — tenant isolation backstop (FORCE + WITH CHECK).
4. **Mobile route guards + UI** — cashiers never *see* owner surfaces, and
   bakers never see the POS, debts, expenses or recent sales. This is UX, not
   security; the server is the boundary.

Scenarios considered:
- Baker's token replayed against `/v1/sales`, `/v1/debts`, `/v1/expenses` or
  any report → 403 from `require_cap`, not a masked payload.
- Baker pushing `sale.create` through the offline queue → rejected
  `forbidden_for_role` before the handler runs; nothing is written.
- Baker accepting their own handover → rejected `self_accept_forbidden`.
- Baker covering the counter in a one-person shift → they still cannot count in
  their own handover, so the control degrades to "unreconciled", not to
  "silently self-approved".
- Cashier with a stolen owner phone → PIN challenge still required for
  sensitive ops; PIN attempts are rate-limited and DB-lockout enforced.
- Owner PIN verified in shop A cannot authorize ops in shop B (challenge
  token carries shop_id).
- Cashier logging out with unsynced sales → blocked with explicit warning.
- Deactivated cashier → `is_active=false` fails `current_user` on every
  request; refresh token dies with the device session revoke.
- Cashier trying to read cost prices via API → `purchase_price` masked in
  list responses; reports endpoints are owner-only outright.
