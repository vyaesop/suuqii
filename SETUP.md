# Setup — getting Suuqii running end-to-end

This is the exact, copy-pasteable path from a clean machine to "I just made a sale on my phone and it landed in Postgres."

> **Time estimate**: 30–45 minutes if you've used Docker, Python, and Flutter before. ~90 minutes if any of those are new.

---

## What you need installed (one-time)

| Tool | How to check | If missing |
|---|---|---|
| **Docker Desktop** | `docker --version` | https://docs.docker.com/desktop/ |
| **Python 3.12+** | `python --version` | https://www.python.org/downloads/ |
| **Flutter 3.24+** | `flutter --version` | https://docs.flutter.dev/get-started/install |
| **Android Studio** (or just Android SDK + an emulator) | `flutter doctor` should be clean for "Android toolchain" | https://developer.android.com/studio |

On Windows (your machine), use PowerShell unless noted otherwise.

---

## Environment variables you need

The backend needs these. Here's exactly how to get each.

### 1. `DATABASE_URL` — Postgres connection string

**Easiest (local Docker — recommended while developing):**

```powershell
cd c:\Users\PC\Documents\inventory-management
docker compose up -d
```

That starts a local Postgres on `localhost:5432`. Your URL is already set in `.env.example`:

```
DATABASE_URL=postgresql+asyncpg://suuqii:suuqii@localhost:5432/suuqii
DATABASE_URL_SYNC=postgresql://suuqii:suuqii@localhost:5432/suuqii
```

**For production (Neon):**

1. Go to https://console.neon.tech/signup and sign up (GitHub login is fastest).
2. Click **Create project**. Name it `suuqii`. Region: pick **AWS eu-central-1 (Frankfurt)** (lowest latency from Ethiopia).
3. After creation you land on the dashboard. Look for the **Connection string** panel.
4. Toggle to **Pooled connection**. Copy the string. It looks like:
   ```
   postgresql://suuqii_owner:abc...@ep-xxxx-pooler.eu-central-1.aws.neon.tech/suuqii?sslmode=require
   ```
5. In `backend/.env`, set two variants (asyncpg for the API, sync for Alembic migrations):
   ```
   DATABASE_URL=postgresql+asyncpg://suuqii_owner:abc...@ep-xxxx-pooler.eu-central-1.aws.neon.tech/suuqii?ssl=require
   DATABASE_URL_SYNC=postgresql://suuqii_owner:abc...@ep-xxxx-pooler.eu-central-1.aws.neon.tech/suuqii?sslmode=require
   ```
   ⚠️ For asyncpg use `?ssl=require`. For the sync URL use `?sslmode=require`. Different parameter names, same effect.

### 2. `JWT_SECRET` — signs auth tokens

Generate a strong random string. Run **once** from the project root:

```powershell
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

Copy the output. Example: `kQ7Mx_8sP3vN-tLr...` Paste it into `backend/.env`:
```
JWT_SECRET=kQ7Mx_8sP3vN-tLr...
```

Keep it secret. Never commit it. Use a different one for production than for dev.

### 3. `JWT_SECRET_PREVIOUS` — leave blank initially

```
JWT_SECRET_PREVIOUS=
```

Only set when rotating the secret (see `docs/14-deployment.md`).

### 4. `ALLOWED_ORIGINS` — for CORS

For local dev:
```
ALLOWED_ORIGINS=*
```

For production, set to your web admin origin (e.g. `https://admin.suuqii.app`). Mobile (Flutter) doesn't need CORS.

### 5. Optional — `SENTRY_DSN`

Skip for first run. To enable later:
1. Sign up at https://sentry.io/signup/
2. **Create project** → platform: **FastAPI** → name: `suuqii-backend` → **Create**
3. Copy the DSN (looks like `https://abc123@o12345.ingest.sentry.io/67890`).
4. Paste into `.env`:
   ```
   SENTRY_DSN=https://abc123@o12345.ingest.sentry.io/67890
   ```

### 6. Optional — `FCM_PROJECT_ID` + `FCM_PRIVATE_KEY`

Skip for first run. Push notifications require Firebase setup; do it after the rest works:
1. https://console.firebase.google.com → **Add project** → name `suuqii`.
2. **Project settings** → **Service accounts** → **Generate new private key** → downloads `serviceAccount.json`.
3. Base64-encode it:
   ```powershell
   [Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\Downloads\serviceAccount.json")) | Set-Clipboard
   ```
4. In `.env`:
   ```
   FCM_PROJECT_ID=suuqii-xxxxx
   FCM_PRIVATE_KEY=<the base64 you just copied>
   ```

### Defaults that are already correct

```
JWT_ACCESS_TTL_MIN=60
JWT_REFRESH_TTL_DAYS=30
JWT_OWNER_CHALLENGE_TTL_MIN=5
LOG_LEVEL=INFO
DEFAULT_LOCALE=en
TIMEZONE=Africa/Addis_Ababa
```

---

## Step-by-step: run the backend

```powershell
cd c:\Users\PC\Documents\inventory-management\backend

# 1. Make a virtual env
python -m venv .venv
.\.venv\Scripts\Activate.ps1

# 2. Install deps
pip install -e ".[dev]"

# 3. Create .env from the template
Copy-Item .env.example .env
# Edit .env in your editor — paste DATABASE_URL and JWT_SECRET from above

# 4. Start Postgres (if using Docker — skip if using Neon)
cd ..
docker compose up -d
cd backend

# 5. Run the schema migration
alembic upgrade head

# 6. Seed some test data (optional but recommended for the first sale)
python scripts/seed.py

# 7. Start the API
uvicorn app.main:app --reload
```

You should see:
```
Uvicorn running on http://127.0.0.1:8000 (Press CTRL+C to quit)
```

Open http://127.0.0.1:8000/docs in your browser — that's the OpenAPI explorer. You should see all the `/v1/...` endpoints.

If the seed succeeded, it printed credentials at the end like:
```
✓ Seeded shop "Test Shop". Login with:
    phone: +251911111111
    password: pass1234
    owner PIN: 1234
```

Test the API quickly:
```powershell
curl -X POST http://localhost:8000/v1/auth/login `
  -H "Content-Type: application/json" `
  -d '{\"phone\":\"+251911111111\",\"password\":\"pass1234\",\"device_fingerprint\":\"my-laptop\"}'
```

You should get back `access`, `refresh`, `user_id`, `shop_id`, `role`.

---

## Step-by-step: run the mobile app

In a second terminal:

```powershell
cd c:\Users\PC\Documents\inventory-management\mobile

# 1. Get packages
flutter pub get

# 2. Generate code (Drift tables, Riverpod providers, etc.)
dart run build_runner build --delete-conflicting-outputs

# 3. List available emulators
flutter emulators
# If empty, open Android Studio → Device Manager → create a Pixel 5 / API 33 emulator

# 4. Boot one
flutter emulators --launch Pixel_5_API_33
# (replace with the id from step 3)

# 5. Run the app pointing at your backend
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

About `10.0.2.2`: that's the special hostname an Android emulator uses to reach the host machine's `localhost`. **Do not use `localhost`** — it points the emulator at itself.

On a real Android device connected via USB:
- Find your laptop's LAN IP: `(Get-NetIPAddress -AddressFamily IPv4).IPv4Address`
- Use `http://<that IP>:8000` instead of `10.0.2.2`
- Make sure the laptop firewall allows port 8000

You should land on the login screen. Log in with the seeded phone + password. You'll see a stocked POS screen with 5 sample products.

Tap a product → it lands in the cart. Tap **Checkout** → pick Cash → confirm. The cart clears, stock decrements locally. The top-right cloud icon flashes while the sync worker pushes the event. After a second it goes back to "all caught up".

Back on your terminal where uvicorn is running, you'll see a `POST /v1/sync/push` log line. Verify the sale landed:

```powershell
docker exec -it suuqii_postgres psql -U suuqii -d suuqii -c "SELECT id, total, payment_method FROM sales;"
```

---

## What's wired and works today

| Feature | Backend | Mobile | Notes |
|---|---|---|---|
| Register shop | ✓ | stub | Use seed script for now |
| Login | ✓ | ✓ | |
| Token refresh on 401 | ✓ | ✓ | Automatic via interceptor |
| Product list (read) | ✓ | ✓ | Pulled on first launch, cached |
| Make a sale (cash/mobile/credit) | ✓ | ✓ | The headline flow |
| Stock auto-decrements | ✓ | ✓ | Local + server, delta-based |
| Sync queue + retry | ✓ | ✓ | Survives offline |
| Open/close shift | ✓ | ✓ | Variance computed both sides |
| Owner PIN gate | ✓ | helper provided | Wire into edit screens as you build them |
| Audit log | ✓ (DB triggers) | view-only | Owner reads `/v1/audit` |
| Reports / dashboard | ✓ | stub | Hit `/v1/reports/dashboard` |

---

## Next steps for you (each ~1 hour of work)

These are deliberate stubs in the mobile app. Patterns are established, just copy the sales/auth shape:

1. **Inventory edit screen** — `mobile/lib/features/inventory/presentation/`. Use `productsRepositoryProvider.update(...)` and the owner PIN dialog.
2. **Debt collection screen** — same pattern with `debtsRepositoryProvider`.
3. **Expense entry sheet** — same.
4. **Dashboard charts** — call `/v1/reports/dashboard`, render with `fl_chart`.
5. **Invite employee flow** — call `/v1/auth/invite`, show the 8-digit code.
6. **Audit log viewer** (owner) — paginated list from `/v1/audit`.

Each one already has its Drift table, its sync ops, and its backend endpoint. You only need to build the screen.

---

## Troubleshooting

**`alembic upgrade head` says "no such function: gen_random_uuid"**
→ You're on Postgres < 13, or `pgcrypto` extension didn't load. The migration creates it; verify with `\dx` in psql. Docker image is 16 and works.

**Mobile says "Connection refused" or hangs**
→ You used `localhost` from the emulator. Use `10.0.2.2` (Android emulator) or your laptop's LAN IP (physical device).

**`flutter pub get` fails on Windows with long-path errors**
→ Enable long paths: `git config --system core.longpaths true` (admin shell), and in Windows settings: Settings → System → For developers → enable Developer Mode.

**`dart run build_runner build` fails with "conflict"**
→ Add `--delete-conflicting-outputs` (the SETUP command already has this).

**Login returns 401 with correct password**
→ Check the seed actually ran (`docker exec ... psql -c "SELECT phone FROM users;"`). If the table is empty, re-run `python scripts/seed.py`.

**Sync stays "pending" forever**
→ Look at uvicorn output. Most often it's a CORS/host mismatch. The mobile app logs the base URL on startup; verify it matches the emulator-reachable address.

**`flutter doctor` complains about Android licenses**
→ `flutter doctor --android-licenses` and accept all.
