import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:suuqii/app/home_shell.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sales/presentation/pos_screen.dart';
import 'package:suuqii/features/sync/presentation/sync_status_badge.dart';
import 'package:suuqii/l10n/app_localizations.dart';

class _TestAuthController extends AuthController {
  _TestAuthController(this.auth);

  final AuthState auth;

  @override
  Future<AuthState> build() async => auth;
}

class _NoopProductsSync extends ProductsSync {
  @override
  Future<void> build() async {}

  @override
  Future<void> refresh() async {}
}

void main() {
  const auth = Authenticated(
    userId: 'user-1',
    shopId: 'shop-1',
    role: 'owner',
    userName: 'Owner',
    shopName: 'Shop',
    accessToken: 'token',
  );

  Widget buildSubject(List<Product> products) {
    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(
          () => _TestAuthController(auth),
        ),
        productsSyncProvider.overrideWith(_NoopProductsSync.new),
        watchProductsProvider(query: '').overrideWith(
          (_) => Stream.value(products),
        ),
        watchCategoriesProvider.overrideWith(
          (_) => Stream.value(const <String>[]),
        ),
        watchRecentProductsProvider.overrideWith(
          (_) => Stream.value(const <Product>[]),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: PosScreen(),
        ),
      ),
    );
  }

  Widget buildRoutedSubject(List<Product> products) {
    final router = GoRouter(
      initialLocation: '/pos',
      routes: [
        ShellRoute(
          builder: (_, __, child) => HomeShell(child: child),
          routes: [
            GoRoute(
              path: '/pos',
              builder: (_, __) => const PosScreen(),
            ),
          ],
        ),
      ],
    );

    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(
          () => _TestAuthController(auth),
        ),
        productsSyncProvider.overrideWith(_NoopProductsSync.new),
        pendingSyncCountProvider.overrideWith((_) => Stream.value(0)),
        watchProductsProvider(query: '').overrideWith(
          (_) => Stream.value(products),
        ),
        watchCategoriesProvider.overrideWith(
          (_) => Stream.value(const <String>[]),
        ),
        watchRecentProductsProvider.overrideWith(
          (_) => Stream.value(const <Product>[]),
        ),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
  }

  testWidgets('sell screen shows useful empty state when no products exist',
      (tester) async {
    await tester.pumpWidget(buildSubject(const []));
    await tester.pumpAndSettle();

    expect(find.text('Search products'), findsOneWidget);
    expect(find.text('No products available to sell'), findsOneWidget);
    expect(
      find.text('Cart is empty - tap a product to add it'),
      findsOneWidget,
    );
    expect(find.text('Load products'), findsOneWidget);
  });

  testWidgets('tapping a product adds it to the cart', (tester) async {
    final product = Product(
      id: 'p1',
      shopId: 'shop-1',
      name: 'Coffee',
      purchasePrice: Decimal.parse('10'),
      sellingPrice: Decimal.parse('25'),
      stock: Decimal.parse('5'),
      lowStockThreshold: Decimal.parse('1'),
      unit: 'pack',
    );

    await tester.pumpWidget(buildSubject([product]));
    await tester.pumpAndSettle();

    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('ETB 0'), findsOneWidget);

    await tester.tap(find.text('Coffee'));
    await tester.pumpAndSettle();

    expect(find.text('Coffee added to cart'), findsOneWidget);
    expect(find.text('ETB 25'), findsWidgets);
    // Proper ICU plural now renders "1 item" (was "1 items").
    expect(find.text('1 item across 1 line'), findsOneWidget);
  });

  testWidgets('tapping a selected product removes it from the cart',
      (tester) async {
    final product = Product(
      id: 'p1',
      shopId: 'shop-1',
      name: 'Coffee',
      purchasePrice: Decimal.parse('10'),
      sellingPrice: Decimal.parse('25'),
      stock: Decimal.parse('5'),
      lowStockThreshold: Decimal.parse('1'),
      unit: 'pack',
    );

    await tester.pumpWidget(buildSubject([product]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Coffee'));
    await tester.pumpAndSettle();
    // Proper ICU plural now renders "1 item" (was "1 items").
    expect(find.text('1 item across 1 line'), findsOneWidget);

    await tester.tap(find.text('Coffee'));
    await tester.pumpAndSettle();

    expect(find.text('Coffee removed from cart'), findsOneWidget);
    expect(find.text('Cart is empty - tap a product to add it'), findsOneWidget);
    expect(find.text('ETB 0'), findsOneWidget);
  });

  testWidgets(
      'cart bar Checkout button goes straight to the checkout sheet, '
      'skipping review', (tester) async {
    final product = Product(
      id: 'p1',
      shopId: 'shop-1',
      name: 'Coffee',
      purchasePrice: Decimal.parse('10'),
      sellingPrice: Decimal.parse('25'),
      stock: Decimal.parse('5'),
      lowStockThreshold: Decimal.parse('1'),
      unit: 'pack',
    );

    await tester.pumpWidget(buildSubject([product]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Coffee'));
    await tester.pumpAndSettle();
    // Let the "added to cart" snackbar expire so it cannot cover the bar.
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();

    // Primary button: direct to checkout (product -> Checkout -> Confirm).
    await tester.tap(find.widgetWithText(FilledButton, 'Checkout'));
    await tester.pumpAndSettle();

    // Checkout sheet is open; the review sheet was skipped.
    expect(find.text('Confirm - ETB 25'), findsOneWidget);
    expect(find.text('Continue to checkout'), findsNothing);
    // Exact-cash prefill makes Confirm work with zero extra input.
    expect(find.text('Change due ETB 0'), findsOneWidget);
  });

  testWidgets('tapping the cart bar summary still opens the review sheet',
      (tester) async {
    final product = Product(
      id: 'p1',
      shopId: 'shop-1',
      name: 'Coffee',
      purchasePrice: Decimal.parse('10'),
      sellingPrice: Decimal.parse('25'),
      stock: Decimal.parse('5'),
      lowStockThreshold: Decimal.parse('1'),
      unit: 'pack',
    );

    await tester.pumpWidget(buildSubject([product]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Coffee'));
    await tester.pumpAndSettle();
    // Let the "added to cart" snackbar expire so it cannot cover the bar.
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();

    await tester.tap(find.text('1 item across 1 line'));
    await tester.pumpAndSettle();

    expect(find.text('Continue to checkout'), findsOneWidget);
  });

  testWidgets('sell route renders through the home shell', (tester) async {
    await tester.pumpWidget(buildRoutedSubject(const []));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Sell'), findsWidgets);
    expect(find.text('Search products'), findsOneWidget);
    expect(find.text('No products available to sell'), findsOneWidget);
    expect(find.text('Synced'), findsOneWidget);
  });
}
