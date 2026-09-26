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
import 'package:suuqii/features/inventory/data/styles_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/domain/entities/style.dart';
import 'package:suuqii/features/sales/presentation/pos_catalog.dart';
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

  const boutiqueAuth = Authenticated(
    userId: 'user-1',
    shopId: 'shop-1',
    role: 'owner',
    userName: 'Owner',
    shopName: 'Boutique',
    accessToken: 'token',
    shopType: 'boutique',
  );

  Widget buildSubject(
    List<Product> products, {
    Authenticated authState = auth,
    List<Style> styles = const [],
    Map<String, List<Product>> queryResults = const {},
  }) {
    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(
          () => _TestAuthController(authState),
        ),
        productsSyncProvider.overrideWith(_NoopProductsSync.new),
        watchProductsProvider(query: '').overrideWith(
          (_) => Stream.value(products),
        ),
        for (final entry in queryResults.entries)
          watchProductsProvider(query: entry.key).overrideWith(
            (_) => Stream.value(entry.value),
          ),
        watchStylesProvider.overrideWith((_) => Stream.value(styles)),
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

    // No "added" snackbar: it used to sit over the cart bar's Checkout
    // button. The tile badge and the cart bar are the confirmation.
    expect(find.byType(SnackBar), findsNothing);
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
    // No wait: nothing may cover the cart bar right after adding.

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
    // No wait: nothing may cover the cart bar right after adding.

    await tester.tap(find.text('1 item across 1 line'));
    await tester.pumpAndSettle();

    expect(find.text('Continue to checkout'), findsOneWidget);
  });

  group('boutique', () {
    final style = Style(
      id: 'style-1',
      shopId: 'shop-1',
      name: 'Slim jeans',
      defaultSellingPrice: Decimal.parse('1200'),
      defaultPurchasePrice: Decimal.parse('800'),
      sizeSet: 'waist',
      skuPrefix: 'JN',
    );
    Product variant(String size, String color, int stock) => Product(
          id: 'v-$size-$color',
          shopId: 'shop-1',
          name: 'Slim jeans · $size · $color',
          purchasePrice: Decimal.parse('800'),
          sellingPrice: Decimal.parse('1200'),
          stock: Decimal.fromInt(stock),
          lowStockThreshold: Decimal.one,
          unit: 'piece',
          styleId: 'style-1',
          size: size,
          color: color,
          sku: 'JN-$size-${color.substring(0, 3).toUpperCase()}',
        );
    final belt = Product(
      id: 'belt',
      shopId: 'shop-1',
      name: 'Belt',
      purchasePrice: Decimal.parse('100'),
      sellingPrice: Decimal.parse('300'),
      stock: Decimal.fromInt(4),
      lowStockThreshold: Decimal.one,
      unit: 'piece',
    );
    final variants = [
      variant('32', 'Blue', 3),
      variant('34', 'Blue', 0),
      variant('32', 'Black', 2),
    ];

    test('groupCatalog collapses variants into one style tile', () {
      final entries = groupCatalog(
        [belt, ...variants],
        {style.id: style},
      );
      expect(entries, hasLength(2));
      expect(entries.first, isA<ProductEntry>());
      final s = entries.last as StyleEntry;
      expect(s.name, 'Slim jeans');
      expect(s.variants, hasLength(3));
      expect(s.stockTotal, Decimal.fromInt(5));
      expect(s.sizeCount, 2);
      expect(s.hasBrokenRun, isTrue);
    });

    test('groupCatalog ungroups an exact SKU hit', () {
      final entries = groupCatalog(
        [variants[1]],
        {style.id: style},
        query: 'jn-34-blu',
      );
      expect(entries.single, isA<ProductEntry>());
    });

    testWidgets('grid shows one tile per style with stock and size count',
        (tester) async {
      await tester.pumpWidget(
        buildSubject(
          [belt, ...variants],
          authState: boutiqueAuth,
          styles: [style],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Slim jeans'), findsOneWidget);
      expect(find.text('Belt'), findsOneWidget);
      // Variants are not tiles of their own.
      expect(find.text('Slim jeans · 32 · Blue'), findsNothing);
      expect(find.text('5 in stock · 2 sizes'), findsOneWidget);
    });

    testWidgets('tapping a style tile opens the variant picker; a size adds',
        (tester) async {
      await tester.pumpWidget(
        buildSubject(
          [belt, ...variants],
          authState: boutiqueAuth,
          styles: [style],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Slim jeans'));
      await tester.pumpAndSettle();
      expect(find.text('Blue'), findsOneWidget);
      expect(find.text('Black'), findsOneWidget);

      await tester.tap(find.text('32').first);
      await tester.pumpAndSettle();

      // Sheet closed, cart holds the exact variant.
      expect(find.text('Black'), findsNothing);
      expect(find.text('1 item across 1 line'), findsOneWidget);
      expect(find.text('ETB 1,200'), findsWidgets);
    });

    testWidgets('typing an exact SKU shows that variant as a plain tile',
        (tester) async {
      await tester.pumpWidget(
        buildSubject(
          [belt, ...variants],
          authState: boutiqueAuth,
          styles: [style],
          queryResults: {'JN-32-BLA': [variants[2]]},
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'JN-32-BLA');
      await tester.pumpAndSettle();

      expect(find.text('Slim jeans · 32 · Black'), findsOneWidget);
      expect(find.text('Slim jeans'), findsNothing);

      // One tap adds the variant directly (no picker in between). Stock 2 →
      // 1 crosses the threshold, so the POS shows the low-stock warning
      // (plain adds get no notice); the cart bar is the stable signal.
      await tester.tap(find.text('Slim jeans · 32 · Black'));
      await tester.pumpAndSettle();
      expect(find.text('1 item across 1 line'), findsOneWidget);
      expect(find.text('ETB 1,200'), findsWidgets);
    });
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
