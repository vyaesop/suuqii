import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sales/presentation/cart_controller.dart';
import 'package:suuqii/features/sales/presentation/variant_picker_sheet.dart';
import 'package:suuqii/l10n/app_localizations.dart';

Product _variant(String id, String size, String color, int stock) => Product(
      id: id,
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
    );

void main() {
  final variants = [
    _variant('v-32-blue', '32', 'Blue', 3),
    _variant('v-34-blue', '34', 'Blue', 0),
    _variant('v-32-black', '32', 'Black', 1),
  ];

  Widget buildSubject(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: VariantPickerSheet(
            styleName: 'Slim jeans',
            imageUrl: null,
            variants: variants,
            sizeSet: 'waist',
          ),
        ),
      ),
    );
  }

  testWidgets('renders colour rows with size chips and their stock',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(buildSubject(container));
    await tester.pumpAndSettle();

    expect(find.text('Slim jeans'), findsOneWidget);
    expect(find.text('Blue'), findsOneWidget);
    expect(find.text('Black'), findsOneWidget);
    // Two "32" chips (one per colour row) and one "34".
    expect(find.text('32'), findsNWidgets(2));
    expect(find.text('34'), findsOneWidget);
  });

  testWidgets('a 0-stock chip is disabled (hard stock gate)', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(buildSubject(container));
    await tester.pumpAndSettle();

    final chip = find.ancestor(
      of: find.text('34'),
      matching: find.byType(InkWell),
    );
    expect(tester.widget<InkWell>(chip.first).onTap, isNull);

    await tester.tap(find.text('34'));
    await tester.pumpAndSettle();
    expect(container.read(cartControllerProvider).isEmpty, isTrue);
  });

  testWidgets('tapping a size adds exactly that variant to the cart',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // The cart provider is autoDispose: once the sheet pops, nothing watches
    // it and a bare read would build a fresh empty cart. Pin it like the POS
    // screen does in the real app.
    container.listen(cartControllerProvider, (_, __) {});
    await tester.pumpWidget(buildSubject(container));
    await tester.pumpAndSettle();

    // The "32" under the Black row is the second "32" chip in layout order.
    await tester.tap(find.text('32').last);
    await tester.pumpAndSettle();

    final cart = container.read(cartControllerProvider);
    expect(cart.lineCount, 1);
    expect(cart.lines.single.product.id, 'v-32-black');
    expect(cart.lines.single.qty, Decimal.one);
  });

  testWidgets('long-press adds and keeps the sheet open', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(buildSubject(container));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('32').first);
    await tester.pumpAndSettle();

    expect(container.read(cartControllerProvider).qtyFor('v-32-blue'), Decimal.one);
    // Still visible: the sheet did not pop.
    expect(find.text('Slim jeans'), findsOneWidget);
    expect(find.text('Slim jeans · 32 · Blue added to cart'), findsOneWidget);
  });
}
