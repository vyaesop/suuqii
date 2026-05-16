# 09 — State management

## Stack

- **Riverpod 2** with codegen (`riverpod_generator`).
- **`AsyncNotifier`** for async state, **`Notifier`** for sync.
- **No** `ChangeNotifier`, no `BuildContext`-bound state, no inherited widgets for app state.
- **Drift streams → Riverpod `StreamProvider`** for reactive local data.

## Provider categories

### 1. Infrastructure (singletons, eager)
Bootstrapped in `main.dart`, overridden in tests.
```dart
@Riverpod(keepAlive: true)
AppDatabase appDatabase(AppDatabaseRef ref) => throw UnimplementedError();  // overridden

@Riverpod(keepAlive: true)
Dio dio(DioRef ref) => buildDio(ref);

@Riverpod(keepAlive: true)
SecureStorage secureStorage(SecureStorageRef ref) => SecureStorage();
```

### 2. Repositories (singletons, lazy)
```dart
@Riverpod(keepAlive: true)
SalesRepository salesRepository(SalesRepositoryRef ref) => SalesRepositoryImpl(
  local: SalesLocalDataSource(ref.watch(appDatabaseProvider)),
  remote: SalesRemoteDataSource(ref.watch(dioProvider)),
  sync: ref.watch(syncQueueProvider),
);
```

### 3. Use cases (lazy, cheap to recreate)
```dart
@riverpod
SubmitSale submitSale(SubmitSaleRef ref) => SubmitSale(ref.watch(salesRepositoryProvider));
```

### 4. Controllers (per-screen state)
```dart
@riverpod
class CartController extends _$CartController {
  @override
  Cart build() => const Cart.empty();

  void addItem(Product p, {double qty = 1}) {
    state = state.add(p, qty);
  }

  Future<Sale> checkout(PaymentMethod method, {String? customerName}) async {
    final submit = ref.read(submitSaleProvider);
    final sale = await submit.execute(state, method, customerName: customerName);
    state = const Cart.empty();
    return sale;
  }
}
```

### 5. Reactive queries (Drift streams)
```dart
@riverpod
Stream<List<Product>> products(ProductsRef ref, {String? query}) {
  return ref.watch(appDatabaseProvider).productsDao.watchAll(query: query);
}

@riverpod
Stream<List<Product>> lowStockProducts(LowStockProductsRef ref) {
  return ref.watch(appDatabaseProvider).productsDao.watchLowStock();
}
```
Widgets `ref.watch` these — they rebuild automatically when the local DB changes.

### 6. Auth (cross-cutting)
```dart
@Riverpod(keepAlive: true)
class AuthController extends _$AuthController {
  @override
  Future<AuthState> build() async {
    final stored = await ref.read(secureStorageProvider).readRefresh();
    if (stored == null) return const AuthState.unauthenticated();
    final user = await ref.read(authRepositoryProvider).resume(stored);
    return AuthState.authenticated(user: user.user, shop: user.shop, accessToken: user.access);
  }

  Future<void> login(String phone, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => ref.read(authRepositoryProvider).login(phone, password));
  }

  Future<void> logout() async {
    await ref.read(authRepositoryProvider).logout();
    state = const AsyncData(AuthState.unauthenticated());
  }
}
```

## Why this pattern

- **No global mutable singletons.** All state is accessed via `ref`.
- **Disposable graphs.** When the user logs out, the auth state changes; downstream providers that depended on `accessToken` auto-invalidate.
- **Override anywhere for tests.** A widget test can replace `salesRepositoryProvider` with a fake in one line.
- **Codegen catches errors.** Renaming a use case rename breaks the build, not runtime.

## Anti-patterns we're avoiding

| Anti-pattern | What we do instead |
|---|---|
| `Provider.of(context, listen: true)` everywhere | `ref.watch` in a `ConsumerWidget` |
| Manual `StreamController` ferrying | `StreamProvider` over Drift's `watch...` |
| God-providers exposing dozens of methods | One controller per screen; cross-screen via shared repos |
| Storing the access token in Drift | Refresh in secure storage, access in RAM only |
| Updating the UI by polling | Drift streams + `ref.watch` |

## Where state lives

| State | Lives in | Persisted? |
|---|---|---|
| Cart (current sale being built) | `CartController` (RAM) | ❌ — losing a half-built sale on crash is acceptable |
| Auth state | `AuthController` (RAM) + tokens (secure storage) + user/shop (Drift) | ✓ |
| Open shift | `ShiftController` (RAM, sourced from Drift) | ✓ Drift |
| Products / sales / debts | Drift | ✓ |
| Sync queue | Drift `sync_events` | ✓ |
| Pending owner challenge token | RAM only (5 min TTL) | ❌ |
| Preferences (theme, language) | `shared_preferences` | ✓ |

## Testing strategy

1. **Domain layer (use cases)**: pure Dart, no Flutter dep. `dart test`.
2. **Data layer (repos)**: integration test against in-memory Drift + Dio MockAdapter.
3. **Presentation (controllers)**: Riverpod `ProviderContainer` + provider overrides.
4. **Widgets**: only critical ones — number pad, cart line, owner PIN dialog.
5. **End-to-end**: one `integration_test` per critical flow (sale, refund, debt collection, shift close).
