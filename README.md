# Suuqii — Mobile Inventory & Shop Management for Ethiopian Retail

> **Suuqii** ("market" in Afaan Oromoo). A lightweight, offline-first operational control system for small Ethiopian retail shops. Not an ERP.

---

## What this is

A mobile-first POS + inventory + accountability system tuned for **single-shop, 1–5 employee operations** on **cheap Android phones** with **intermittent connectivity**. Designed for shop owners who currently track inventory on paper or in their head, and need accountability when they aren't in the store.

### Non-goals
- Full ERP (no GL, no double-entry accounting, no payroll module)
- Multi-warehouse logistics
- Complex tax/VAT compliance flows
- Web-first / desktop-first UX

### Core principles
1. **Faster than paper.** A sale takes ≤3 taps from cold app open.
2. **Offline is the default.** Connectivity is treated as a sync opportunity, never a precondition.
3. **Accountability is a first-class feature.** Every mutation has an immutable trail.
4. **One thumb, big targets.** Cashiers operate one-handed during a rush.
5. **Boring tech.** Postgres, JWT, SQLite, Flutter. No experimental stacks.

---

## Tech stack

| Layer | Choice | Why |
|---|---|---|
| Mobile | **Flutter 3.x + Dart 3** | One codebase, fast on cheap Android, good offline tooling |
| Local DB | **Drift (SQLite)** | Type-safe DAOs, migrations, reactive streams |
| State | **Riverpod 2 (codegen)** | Compile-safe, testable, no BuildContext coupling |
| Routing | **GoRouter** | Declarative, deep linking, role-guarded routes |
| HTTP | **Dio + Retrofit** | Interceptors for auth refresh, retry, queueing |
| Models | **Freezed + json_serializable** | Immutable, exhaustive unions for sync events |
| Backend | **FastAPI (Python 3.12)** | Async Postgres, OpenAPI for client codegen, fits Vercel/Render |
| ORM | **SQLAlchemy 2.0 async + asyncpg** | Production-grade, well-supported |
| Migrations | **Alembic** | Versioned, reversible |
| DB | **Neon Postgres** | Serverless, branching for staging, generous free tier |
| Auth | **JWT (access + refresh)** | Stateless, offline-friendly |
| Hosting | **Vercel (API) + Neon (DB)** | Free-tier viable; document Render/Fly fallback |
| Push | **Firebase Cloud Messaging** | Free, reliable on cheap Androids |
| i18n | **flutter_localizations + intl ARB** | English + Afaan Oromoo from day one |

---

## Repository layout

```
inventory-management/
├── README.md                  ← you are here
├── docs/                      ← 15 deliverables, one per file
│   ├── 01-architecture.md
│   ├── 02-folder-structure.md
│   ├── 03-database-schema.md
│   ├── 04-api-design.md
│   ├── 05-flutter-structure.md
│   ├── 06-sync-engine.md
│   ├── 07-authentication.md
│   ├── 08-ui-screens.md
│   ├── 09-state-management.md
│   ├── 10-example-code.md
│   ├── 11-audit-log.md
│   ├── 12-offline-first.md
│   ├── 13-shift-reconciliation.md
│   ├── 14-deployment.md
│   └── 15-production-scaling.md
├── backend/                   ← FastAPI service
│   ├── pyproject.toml
│   ├── app/
│   │   ├── main.py
│   │   ├── core/              ← config, security, deps
│   │   ├── api/v1/            ← route modules per feature
│   │   ├── db/                ← session, base
│   │   ├── models/            ← SQLAlchemy ORM
│   │   ├── schemas/           ← Pydantic
│   │   └── services/          ← business logic (sync, audit, shifts)
│   └── alembic/
│       └── versions/0001_initial.sql
└── mobile/                    ← Flutter app
    ├── pubspec.yaml
    ├── lib/
    │   ├── main.dart
    │   ├── app/               ← router, theme, i18n
    │   ├── core/              ← env, http, storage, errors
    │   ├── features/
    │   │   ├── auth/
    │   │   ├── inventory/
    │   │   ├── sales/
    │   │   ├── debt/
    │   │   ├── expenses/
    │   │   ├── shifts/
    │   │   ├── dashboard/
    │   │   ├── audit/
    │   │   ├── sync/
    │   │   └── settings/
    │   └── shared/            ← widgets, utils
    ├── assets/l10n/           ← app_en.arb, app_om.arb
    └── README.md
```

Each feature module follows clean architecture:
```
features/sales/
├── data/        repositories, local (drift) + remote (dio), DTOs
├── domain/      entities (freezed), use cases, repo interfaces
└── presentation/ screens, widgets, Riverpod providers
```

---

## The 15 deliverables

Each is a dedicated doc under `docs/`:

1. **[Architecture](docs/01-architecture.md)** — system context, layers, data flow
2. **[Folder structure](docs/02-folder-structure.md)** — full tree, every module explained
3. **[PostgreSQL schema](docs/03-database-schema.md)** — DDL with indexes, FKs, RLS notes
4. **[API design](docs/04-api-design.md)** — REST endpoints, request/response shapes
5. **[Flutter app structure](docs/05-flutter-structure.md)** — clean-arch breakdown per feature
6. **[Sync engine](docs/06-sync-engine.md)** — event log, queue, conflict resolution
7. **[Authentication flow](docs/07-authentication.md)** — JWT, device sessions, employee invites
8. **[UI screen list](docs/08-ui-screens.md)** — every screen, role-gated
9. **[State management](docs/09-state-management.md)** — Riverpod patterns, codegen
10. **[Example code](docs/10-example-code.md)** — critical-system snippets
11. **[Audit log](docs/11-audit-log.md)** — immutable trail, trigger-based capture
12. **[Offline-first strategy](docs/12-offline-first.md)** — write paths, retry, conflict
13. **[Shift reconciliation](docs/13-shift-reconciliation.md)** — open/close, variance math
14. **[Deployment](docs/14-deployment.md)** — Vercel + Neon + FCM setup
15. **[Production scaling](docs/15-production-scaling.md)** — what breaks first, in what order

---

## Quick start (developer)

### Backend
```bash
cd backend
uv venv && source .venv/bin/activate     # or python -m venv .venv
uv pip install -e ".[dev]"
cp .env.example .env                     # set DATABASE_URL, JWT_SECRET
alembic upgrade head
uvicorn app.main:app --reload
```

### Mobile
```bash
cd mobile
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run                              # connect cheap Android via USB
```

---

## Roles & permissions (at a glance)

| Action | Owner | Cashier |
|---|---|---|
| Sell (cash/mobile) | ✓ | ✓ |
| Sell on credit (under threshold) | ✓ | ✓ |
| Sell on credit (over threshold) | ✓ | requires owner PIN |
| Add/edit product | ✓ | view-only |
| Change selling price | ✓ | requires owner PIN |
| Stock adjustment | ✓ | requires owner PIN, logged |
| Delete sale | ✓ | ✗ (only refund) |
| Delete debt | ✓ | ✗ |
| Open/close own shift | ✓ | ✓ |
| View other employees' shifts | ✓ | ✗ |
| View dashboard analytics | ✓ | ✗ |
| Invite employee | ✓ | ✗ |
| Export data | ✓ | ✗ |

---

## Future-ready (intentionally deferred)

The architecture leaves clean seams for:
- **Barcode scanning** — `products.barcode` exists; add `mobile_scanner` package + scanner screen
- **Receipt printing** — sales already serialize to a `Receipt` value object; add ESC/POS adapter
- **Multi-branch** — `shops.parent_shop_id` reserved; sync filters by shop_id today
- **Suppliers** — `purchase_orders` and `suppliers` tables stubbed in migration `0002_optional.sql`
- **AI demand prediction** — daily aggregates in `sales_daily_mv` materialized view
- **Amharic voice input** — input layer abstracted behind `TextInputSource`
- **Telegram/WhatsApp reports** — owner dashboard exposes a `ReportSnapshot` JSON suitable for bot posting
- **QR payments** — `payment_method` is an enum extensible without breaking changes
- **Web admin** — same FastAPI backend; build a Next.js read-only dashboard later

---

## License

Proprietary — for the operator of this shop network. Source available to invited employees and contractors only.
