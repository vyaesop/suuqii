# 05 — Flutter app structure

## Layers per feature

Each feature is a self-contained module with three layers.

```
features/sales/
├── data/
│   ├── data_sources/
│   │   ├── sales_local_data_source.dart    # Drift DAO
│   │   └── sales_remote_data_source.dart   # Dio/Retrofit (rarely used directly)
│   ├── dtos/
│   │   └── sale_dto.dart                   # JSON serializable, freezed
│   ├── mappers/
│   │   └── sale_mapper.dart                # DTO <-> entity, Drift row <-> entity
│   └── repositories/
│       └── sales_repository_impl.dart      # implements domain interface
├── domain/
│   ├── entities/
│   │   ├── sale.dart                       # freezed, no JSON, pure
│   │   ├── sale_item.dart
│   │   └── payment_method.dart             # enum
│   ├── repositories/
│   │   └── sales_repository.dart           # abstract
│   └── usecases/
│       ├── submit_sale.dart
│       ├── refund_sale.dart
│       ├── watch_recent_sales.dart
│       └── compute_cart_totals.dart
└── presentation/
    ├── controllers/
    │   ├── cart_controller.dart            # Riverpod Notifier
    │   └── sales_history_controller.dart
    ├── screens/
    │   ├── pos_screen.dart                 # main register screen
    │   ├── checkout_sheet.dart
    │   └── sale_detail_screen.dart
    └── widgets/
        ├── product_grid_tile.dart
        ├── cart_line.dart
        └── checkout_bar.dart
```

## Dependency direction

```
presentation ──> domain ──> (interfaces only)
data ─────────────> domain
```

Never:
- `domain` importing `data` or `presentation`
- `data` importing `presentation`
- One feature's `data` or `domain` importing another feature's `data`

Cross-feature collaboration happens via:
1. Shared `domain/entities` lifted to `core/` if used by multiple features.
2. Riverpod providers exposed by feature A and consumed by feature B's presentation layer.

## Routing

```dart
// lib/app/router.dart
final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authStateProvider);
  return GoRouter(
    initialLocation: '/login',
    refreshListenable: auth.toListenable(),
    redirect: (ctx, state) {
      final loggedIn = auth.value?.isAuthenticated ?? false;
      final isOwner = auth.value?.role == Role.owner;
      if (!loggedIn && !_publicRoutes.contains(state.matchedLocation)) return '/login';
      if (loggedIn && state.matchedLocation == '/login') return '/pos';
      if (state.matchedLocation.startsWith('/owner') && !isOwner) return '/pos';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/register-shop', builder: (_, __) => const RegisterShopScreen()),
      ShellRoute(
        builder: (_, __, child) => HomeShell(child: child),  // bottom nav
        routes: [
          GoRoute(path: '/pos', builder: (_, __) => const PosScreen()),
          GoRoute(path: '/inventory', builder: (_, __) => const InventoryScreen()),
          GoRoute(path: '/debts', builder: (_, __) => const DebtsScreen()),
          GoRoute(path: '/shift', builder: (_, __) => const ShiftScreen()),
          GoRoute(path: '/owner', builder: (_, __) => const OwnerDashboardScreen()),
        ],
      ),
    ],
  );
});
```

## Bottom navigation

5 tabs, role-gated:

| Tab | Cashier | Owner |
|---|---|---|
| Sell (POS) | ✓ | ✓ |
| Inventory | view-only | full |
| Debts | view + collect | full |
| Shift | own only | all |
| Dashboard | hidden | ✓ |

For cashiers, the 5th tab is replaced by **Settings**.

## Theming

`app_theme.dart` exposes light + dark Material 3 themes with deliberately large defaults:
```dart
final ThemeData _base = ThemeData(
  useMaterial3: true,
  visualDensity: VisualDensity.comfortable, // not compact — touch targets
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      minimumSize: const Size.fromHeight(56), // 56dp minimum
      textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
    ),
  ),
  textTheme: GoogleFonts.notoSansEthiopicTextTheme(),  // supports Geez script for future Amharic
);
```

## i18n

`flutter gen-l10n` from `assets/l10n/app_en.arb` and `app_om.arb`. Every user-facing string flows through `AppLocalizations.of(context)`. Amharic ARB can be added later without code changes (`app_am.arb`).

Currency formatting uses `intl`'s `NumberFormat.currency(symbol: 'ETB ')`.

## Codegen

Single command in `Makefile` / `mobile/scripts/codegen.sh`:
```bash
dart run build_runner build --delete-conflicting-outputs
```
Run after editing any:
- `*.freezed.dart` source (entities, DTOs, sync events)
- `*.g.dart` source (JSON, Riverpod, Drift)
- Drift table change

## Why this structure scales

- Adding a feature = creating one folder under `features/`. Nothing else changes.
- Removing a feature = deleting one folder + removing route + nav entry. No leftover repository injection wiring (Riverpod auto-disposes orphan providers).
- Testing the domain layer requires no Flutter binding (`flutter_test` not needed for use cases).
- Swapping Drift for a different local DB only touches `data/data_sources/*_local_data_source.dart` files.
