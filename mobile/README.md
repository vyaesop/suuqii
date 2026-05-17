# Suuqii mobile

Flutter 3.24+, Dart 3.5+. Material 3, Riverpod 2 with codegen, Drift for local SQLite, GoRouter.

## Get running

```bash
cd mobile
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000     # Android emulator → host machine
```

## Codegen

Re-run whenever you edit:
- Drift table classes
- Riverpod-annotated providers
- Freezed entities / DTOs

```bash
dart run build_runner build --delete-conflicting-outputs
```

Or watch:
```bash
dart run build_runner watch --delete-conflicting-outputs
```

## Layout

```
lib/
├── main.dart              # bootstrap
├── app/                   # router, theme, shell
├── core/                  # env, http, storage (Drift), errors
├── features/              # one folder per feature, clean-arch inside
│   ├── auth/
│   ├── sales/
│   ├── inventory/
│   ├── debt/
│   ├── expenses/
│   ├── shifts/
│   ├── dashboard/
│   ├── audit/
│   ├── sync/              # offline queue + worker
│   └── settings/
└── shared/                # cross-cutting widgets
```

See [../docs/05-flutter-structure.md](../docs/05-flutter-structure.md) for the full guide.

## Build APK

```bash
flutter build apk --release \
  --dart-define=API_BASE_URL=https://suuqii.vercel.app \
  --dart-define=SENTRY_DSN=...
```
