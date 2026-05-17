# 14 — Deployment

## Stack at a glance

| Component | Where | Why |
|---|---|---|
| Postgres | **Neon** (serverless) | Branching for staging, generous free tier, no ops |
| FastAPI | **Vercel** Python runtime | Same dashboard as future Next.js web admin |
| Static assets | **Vercel** | Co-located |
| Push notifications | **Firebase Cloud Messaging** | Free, reliable on cheap Android |
| Object storage (product photos, exports) | **Cloudflare R2** (S3-compatible) | Egress-free, cheaper than S3 |
| Error tracking | **Sentry** (free tier) | Backend + mobile |
| Logs | **Vercel** + **Logtail** | Searchable, retained 7 days free |
| CI | **GitHub Actions** | Free for public/small teams |
| Mobile distribution | **Firebase App Distribution** during beta; **Play Store** for GA | Internal testers don't need Play |

Fallback path if Vercel doesn't fit (cold starts, payload size): **Render** or **Fly.io**. The FastAPI app is plain ASGI; no Vercel-specific code.

## Environments

| Env | Backend host | DB |
|---|---|---|
| **local** | `uvicorn --reload` | Postgres in Docker, or Neon dev branch |
| **staging** | Vercel preview deployments | Neon staging branch (auto-created per PR) |
| **production** | Vercel `main` | Neon main branch |

Neon's branch-per-environment is the killer feature: every PR gets an isolated DB with seeded data; cleanup is automatic.

## Setup — first time

### 1. Neon
1. Create project `suuqii-prod`.
2. Note `DATABASE_URL` (use the **pooled** connection string for serverless).
3. Create dev branch `staging`.

### 2. JWT secret
```bash
python -c "import secrets; print(secrets.token_urlsafe(48))"
```
Store the result. You'll set this in Vercel and locally.

### 3. Backend env vars (set in Vercel project settings → Environment Variables)
```
DATABASE_URL=postgresql+asyncpg://...
DATABASE_URL_SYNC=postgresql://...           # for alembic
JWT_SECRET=<from step 2>
JWT_SECRET_PREVIOUS=                          # blank initially, set during rotation
JWT_ACCESS_TTL_MIN=60
JWT_REFRESH_TTL_DAYS=30
ALLOWED_ORIGINS=https://admin.suuqii.app
FCM_PROJECT_ID=...
FCM_PRIVATE_KEY=...                          # base64 of service account JSON
SENTRY_DSN=...
LOG_LEVEL=INFO
RATE_LIMIT_REDIS_URL=                         # optional; in-memory fallback OK for one node
```

### 4. Deploy backend
```bash
cd backend
vercel link
vercel env pull .env                          # syncs from dashboard
alembic upgrade head                          # against production DB
vercel deploy --prod
```

Vercel reads `vercel.json` (committed):
```json
{
  "builds": [{ "src": "app/main.py", "use": "@vercel/python" }],
  "routes": [{ "src": "/(.*)", "dest": "app/main.py" }]
}
```

### 5. Mobile config
Set `API_BASE_URL` per flavor:
```dart
// mobile/lib/core/env/env.dart
class Env {
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL',
      defaultValue: 'https://suuqii.vercel.app');
}
```
Build commands:
```bash
flutter build apk --release \
  --dart-define=API_BASE_URL=https://suuqii.vercel.app \
  --dart-define=SENTRY_DSN=...
```

### 6. Firebase
1. Create Firebase project.
2. Add Android app, download `google-services.json` → `mobile/android/app/`.
3. Generate service account JSON, base64 it → set as `FCM_PRIVATE_KEY` on Vercel.
4. Mobile: `firebase_messaging` package, request permission, send token to `POST /v1/users/me/fcm-token`.

## CI (GitHub Actions)

`.github/workflows/backend.yml`:
- lint (ruff), typecheck (mypy), test (pytest + testcontainers Postgres).
- on push to `main`: alembic upgrade against staging, run smoke tests, then promote to prod.

`.github/workflows/mobile.yml`:
- analyze, test.
- on tag `v*.*.*`: build signed AAB, upload to Firebase App Distribution.

## Backups

- **Neon point-in-time recovery**: included, 7 days on free tier, 30 days on paid.
- **Weekly logical dump**: GitHub Action runs `pg_dump --format=custom`, encrypts with `age`, uploads to R2 bucket `backups/YYYY-MM-DD.dump.age`. Retention: 12 months.
- **Restore test**: monthly, dry-run restore into a Neon branch and run a smoke test.

## Rotating the JWT secret

1. Set `JWT_SECRET_PREVIOUS = <old>`, `JWT_SECRET = <new>`.
2. Deploy. Backend now accepts tokens signed with either; issues new with `JWT_SECRET`.
3. Wait 24h for all client refreshes to migrate.
4. Clear `JWT_SECRET_PREVIOUS`. Deploy again.

## Owner onboarding

The owner installs the app, taps "Create new shop", and that's it — there's no admin web portal needed for go-live. Operations like "delete this shop" require contacting support (intentional — no public endpoint).

## Monitoring & alerts

Sentry alerts on:
- Any 5xx > 5/min.
- New mobile crash signature.

Cron job alerts on:
- Sync queue backlog on any device > 500 pending → owner notified.
- No sync from any active device for > 24h → owner notified ("Check Kebede's phone").

## Domain & TLS

- API: `suuqii.vercel.app` → Vercel.
- Web admin (future): `admin.suuqii.app` → Vercel.
- Mobile: not applicable (deep links use `suuqii://` custom scheme).
- TLS via Vercel automatic.
