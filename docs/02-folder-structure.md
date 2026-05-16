# 02 — Folder structure

## Top level

```
inventory-management/
├── README.md
├── docs/                     # 15 deliverable docs (this folder)
├── backend/                  # FastAPI service
├── mobile/                   # Flutter app
└── ops/                      # deployment scripts (later)
```

## Backend

```
backend/
├── pyproject.toml                  # uv/pip, deps, scripts
├── .env.example                    # DATABASE_URL, JWT_SECRET, etc.
├── alembic.ini
├── alembic/
│   ├── env.py
│   └── versions/
│       └── 0001_initial.sql        # raw SQL bootstrap (see docs/03)
└── app/
    ├── __init__.py
    ├── main.py                     # FastAPI() + middleware + routers
    ├── core/
    │   ├── config.py               # pydantic-settings, env vars
    │   ├── security.py             # password hash, JWT encode/decode
    │   ├── deps.py                 # current_user, current_shop, db session
    │   ├── rate_limit.py           # slowapi config
    │   └── errors.py               # exception handlers
    ├── db/
    │   ├── base.py                 # SQLAlchemy DeclarativeBase
    │   └── session.py              # async engine + sessionmaker
    ├── models/                     # SQLAlchemy ORM
    │   ├── shop.py
    │   ├── user.py
    │   ├── product.py
    │   ├── sale.py                 # Sale + SaleItem
    │   ├── debt.py                 # Debt + DebtPayment
    │   ├── expense.py
    │   ├── shift.py
    │   ├── inventory_log.py
    │   ├── audit_log.py
    │   └── sync_event.py
    ├── schemas/                    # Pydantic v2
    │   ├── auth.py
    │   ├── product.py
    │   ├── sale.py
    │   ├── sync.py                 # SyncEvent union, push/pull
    │   └── ...
    ├── api/
    │   └── v1/
    │       ├── __init__.py
    │       ├── auth.py             # /auth/login, /register-shop, /invite
    │       ├── products.py
    │       ├── sales.py
    │       ├── debts.py
    │       ├── expenses.py
    │       ├── shifts.py
    │       ├── sync.py             # /sync/push, /sync/pull
    │       ├── audit.py            # owner-only audit feed
    │       └── reports.py          # dashboard aggregates
    └── services/
        ├── auth_service.py
        ├── sync_service.py         # event replay, conflict resolution
        ├── audit_service.py
        ├── shift_service.py        # close, variance calc
        └── report_service.py       # daily/weekly/monthly aggregates
```

## Mobile (Flutter)

```
mobile/
├── pubspec.yaml
├── analysis_options.yaml           # very_good_analysis or lints
├── build.yaml                      # codegen config
├── android/                        # default flutter android scaffold
├── lib/
│   ├── main.dart                   # bootstrap: hive init, drift open, runApp
│   ├── app/
│   │   ├── app.dart                # root MaterialApp.router
│   │   ├── router.dart             # GoRouter + role guards
│   │   ├── theme/
│   │   │   ├── app_theme.dart      # M3 light/dark, large-touch defaults
│   │   │   └── tokens.dart         # spacing, sizes, radii
│   │   └── l10n/                   # generated localization
│   ├── core/
│   │   ├── env/env.dart            # API_BASE_URL etc.
│   │   ├── http/
│   │   │   ├── dio_client.dart
│   │   │   ├── auth_interceptor.dart
│   │   │   └── retry_interceptor.dart
│   │   ├── storage/
│   │   │   ├── app_database.dart   # Drift Database
│   │   │   ├── tables/             # Drift table classes
│   │   │   └── secure_storage.dart # flutter_secure_storage wrapper
│   │   ├── connectivity/connectivity_provider.dart
│   │   ├── errors/                 # Failure sealed class, mappers
│   │   └── utils/                  # money, dates, uuid
│   ├── features/
│   │   ├── auth/
│   │   │   ├── data/
│   │   │   │   ├── auth_remote_data_source.dart
│   │   │   │   ├── auth_local_data_source.dart
│   │   │   │   └── auth_repository_impl.dart
│   │   │   ├── domain/
│   │   │   │   ├── entities/user.dart
│   │   │   │   ├── repositories/auth_repository.dart
│   │   │   │   └── usecases/
│   │   │   │       ├── login.dart
│   │   │   │       ├── register_shop.dart
│   │   │   │       └── invite_employee.dart
│   │   │   └── presentation/
│   │   │       ├── controllers/auth_controller.dart
│   │   │       └── screens/
│   │   │           ├── login_screen.dart
│   │   │           ├── register_shop_screen.dart
│   │   │           └── invite_employee_screen.dart
│   │   ├── inventory/
│   │   │   ├── data/
│   │   │   ├── domain/
│   │   │   └── presentation/
│   │   ├── sales/
│   │   ├── debt/
│   │   ├── expenses/
│   │   ├── shifts/
│   │   ├── dashboard/
│   │   ├── audit/
│   │   ├── sync/
│   │   │   ├── data/
│   │   │   │   └── sync_worker.dart    # WorkManager / Workmanager bg task
│   │   │   ├── domain/
│   │   │   │   └── sync_event.dart     # freezed union
│   │   │   └── presentation/
│   │   │       └── sync_status_badge.dart
│   │   └── settings/
│   └── shared/
│       ├── widgets/
│       │   ├── primary_button.dart
│       │   ├── number_pad.dart         # large-touch numeric pad
│       │   ├── pin_dialog.dart         # owner PIN gate
│       │   └── empty_state.dart
│       └── utils/
├── assets/
│   ├── images/
│   └── l10n/
│       ├── app_en.arb
│       └── app_om.arb              # Afaan Oromoo
└── test/
    ├── unit/                       # use cases, services, mappers
    ├── widget/                     # critical widgets (number pad, cart)
    └── integration/                # offline-online sync flows
```

## Naming conventions

- **Files**: `snake_case.dart`
- **Classes**: `PascalCase`
- **Providers**: `xxxProvider` (Riverpod codegen produces this)
- **Use cases**: verb-named, one public `execute()`
- **DB tables**: `snake_case`, plural (`sale_items`, not `SaleItem`)
- **Backend modules**: singular for models (`product.py` defines `Product`), plural for routers (`products.py` mounts `/products`)

## Why feature-first, not layer-first

Layer-first (`/screens`, `/repositories`, `/models`) doesn't scale past 3 features — you cross-cut every layer to touch one user flow. Feature-first keeps a feature's surface area in one directory; deleting a feature means deleting one folder.
