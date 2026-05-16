# 07 — Authentication

## Flows

### A. Register a new shop
```
Owner taps "Create new shop"
  → enters shop name, owner name, phone, password (min 8)
  → POST /v1/auth/register-shop
  → server creates shops + users(role=owner) + device_sessions row
  → returns { access(1h), refresh(30d), user, shop }
Mobile stores:
  - access token  → in memory only
  - refresh token → flutter_secure_storage (Keychain/Keystore)
  - user + shop   → Drift `auth_state` table (single row)
```

### B. Login (existing user)
```
Phone + password → POST /v1/auth/login
Server checks argon2id hash; if ok, issues tokens + creates a new device_sessions row keyed by device_fingerprint
```

If a refresh token already exists for this `device_fingerprint`, it's rotated (old one revoked, new one issued). One active refresh token per (user, device).

### C. Invite an employee
```
Owner: settings → employees → "Invite"
  → enters name, phone, role (cashier)
  → POST /v1/auth/invite
  → server creates users(role=cashier, is_active=false), generates 8-digit invite_code, stores hashed
  → response includes the code in plaintext (one-time)
Owner reads the 8-digit code to the employee verbally (or sends via SMS).
Employee installs app → taps "Join shop with code"
  → enters phone + invite_code + chooses password
  → POST /v1/auth/accept-invite
  → server validates code, activates user, returns tokens
```

Invite codes:
- 30-minute TTL
- Single-use
- Rate-limited: 10 invites/day per owner

### D. Refresh
Access token expires after 1h. Mobile's auth interceptor catches 401, calls `POST /v1/auth/refresh`, retries the original request once. Refresh tokens rotate (server returns new refresh, invalidates old). If refresh fails → logout, route to `/login`.

### E. Owner PIN gate
Separate 4-digit PIN, **never the same** as login password. Set during shop registration. Used to authorize:
- Price changes
- Stock adjustments
- Debt creation above `shops.debt_threshold`
- Sale deletions
- Employee management

Mobile flow:
```
[Cashier triggers sensitive op]
  → "Owner PIN required" bottom sheet appears
  → enters 4 digits
  → POST /v1/auth/owner-pin/verify
  → server returns challenge_token (5 min TTL, single-use)
  → mobile attaches X-Owner-Challenge: <token> to the actual mutating request (or includes in the sync_event payload)
```
After 5 failed PIN entries: locked for 15 minutes. Failures audit-logged.

### F. Device revocation (lost/stolen)
Owner: settings → devices → sees list with `device_label`, `last_seen_at`. Tap → revoke. Server marks `device_sessions.revoked_at`. Next refresh attempt from that device returns 401 with `code=device_revoked` → mobile wipes local DB and routes to login.

## Token specifics

| Token | TTL | Storage | Carries |
|---|---|---|---|
| Access JWT | 1 hour | RAM only | `sub=user_id`, `shop_id`, `role`, `device_id`, `exp` |
| Refresh JWT | 30 days | flutter_secure_storage | `sub=user_id`, `device_id`, `jti`, `exp` (server validates against `device_sessions.refresh_token_hash`) |
| Owner challenge JWT | 5 minutes | RAM | `sub=user_id`, `purpose='owner_pin'`, `exp`, `nonce` |

Signed with HS256 (single backend, no need for asymmetric yet). Secret in `JWT_SECRET` env var. Rotation: maintain `JWT_SECRET` + `JWT_SECRET_PREVIOUS` for 24h overlap.

## Password storage

argon2id with `time_cost=3, memory_cost=64MB, parallelism=4`. Owner PINs use the same scheme but with shorter, predictable input — rate limiting compensates.

## Headers

| Header | When |
|---|---|
| `Authorization: Bearer <access>` | always |
| `X-Device-Id` | always (raw, the fingerprint hash) |
| `X-Device-Label` | once at login (for UI list) |
| `X-Owner-Challenge` | sensitive ops only |
| `Idempotency-Key` | optional, on all POSTs |
| `Accept-Language` | `en` or `om` |

## Mobile state shape

```dart
@freezed
class AuthState with _$AuthState {
  const factory AuthState.unknown() = _Unknown;
  const factory AuthState.unauthenticated() = _Unauthenticated;
  const factory AuthState.authenticated({
    required User user,
    required Shop shop,
    required String accessToken,
  }) = _Authenticated;
  const factory AuthState.error(String message) = _Error;
}
```

Single `authStateProvider` (Riverpod `AsyncNotifier<AuthState>`); router redirects derive from it.

## Edge cases handled

- **Same person logs in on a new phone** → previous refresh remains valid until expiry; both phones work. Owner can revoke the old one if it's stolen.
- **Clock skew on the phone** → JWT validation tolerates 60s of skew; access tokens are short-lived so abuse window is small.
- **User uninstalls and reinstalls** → device_fingerprint regenerates → new `device_sessions` row → user has to log in again. The old row is left in place until its refresh expires (then a nightly job cleans it).
- **Employee fired** → owner deactivates user (`users.is_active=false`); revokes their devices. Their last shift remains in history.
