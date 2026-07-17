import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/debt/data/debts_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/sales/presentation/cart_controller.dart';
import 'package:suuqii/features/sales/presentation/checkout_sheet.dart';
import 'package:suuqii/l10n/app_localizations.dart';

class _SeededCartController extends CartController {
  _SeededCartController(this._cart);

  final Cart _cart;

  @override
  Cart build() => _cart;
}

/// Counts outstanding-balance lookups so the debounce test can assert one
/// query per pause, not one per keystroke.
class _CountingDebtsRepository implements DebtsRepository {
  int lookups = 0;

  @override
  Future<Decimal> outstandingByPhone(String phone) async {
    lookups++;
    return Decimal.zero;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final product = Product(
    id: 'p1',
    shopId: 'shop-1',
    name: 'Coffee',
    purchasePrice: Decimal.parse('40'),
    sellingPrice: Decimal.parse('70'),
    stock: Decimal.parse('5'),
    lowStockThreshold: Decimal.parse('1'),
    unit: 'pack',
  );

  Widget buildSubject({
    required Cart cart,
    DebtsRepository? debts,
    ValueChanged<CheckoutResult?>? onResult,
  }) {
    return ProviderScope(
      overrides: [
        cartControllerProvider.overrideWith(() => _SeededCartController(cart)),
        if (debts != null) debtsRepositoryProvider.overrideWithValue(debts),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  final result = await showModalBottomSheet<CheckoutResult>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => const CheckoutSheet(),
                  );
                  onResult?.call(result);
                },
                child: const Text('open checkout'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('open checkout'));
    await tester.pumpAndSettle();
  }

  Finder tenderedField() =>
      find.widgetWithText(TextField, 'Tendered amount');

  testWidgets('change due updates live as the cashier types', (tester) async {
    final cart = Cart.empty().add(product); // total ETB 70

    await tester.pumpWidget(buildSubject(cart: cart));
    await openSheet(tester);

    // Pre-filled with the exact total -> change due 0 already visible.
    expect(find.text('Change due ETB 0'), findsOneWidget);

    // Typing "100" for a 70 ETB sale must update change due immediately,
    // with no unrelated rebuild needed (regression: stale change display).
    await tester.enterText(tenderedField(), '100');
    await tester.pump();
    expect(find.text('Change due ETB 30'), findsOneWidget);

    // Under-tendering flips to the shortfall message just as promptly.
    await tester.enterText(tenderedField(), '50');
    await tester.pump();
    expect(find.text('Short by ETB 20'), findsOneWidget);
    expect(find.text('Change due ETB 30'), findsNothing);
  });

  testWidgets('cash is pre-filled with the exact total; Exact chip is first',
      (tester) async {
    final cart = Cart.empty().add(product);

    await tester.pumpWidget(buildSubject(cart: cart));
    await openSheet(tester);

    final field = tester.widget<TextField>(tenderedField());
    expect(field.controller!.text, '70');
    // Fully selected so typing replaces the prefill instead of appending.
    expect(field.controller!.selection.baseOffset, 0);
    expect(field.controller!.selection.extentOffset, 2);

    // "Exact" quick chip present, rendered first among the quick chips.
    final exactChip = find.text('Exact ETB 70');
    expect(exactChip, findsOneWidget);
    expect(
      find.descendant(of: find.byType(ActionChip).first, matching: exactChip),
      findsOneWidget,
    );
  });

  testWidgets('exact-cash sale confirms with zero extra input',
      (tester) async {
    final cart = Cart.empty().add(product);
    CheckoutResult? result;

    await tester.pumpWidget(
      buildSubject(cart: cart, onResult: (r) => result = r),
    );
    await openSheet(tester);

    await tester.ensureVisible(find.text('Confirm - ETB 70'));
    await tester.tap(find.text('Confirm - ETB 70'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.paymentMethod, PaymentMethod.cash);
    expect(result!.amountTendered, Decimal.parse('70'));
    expect(result!.changeDue, Decimal.zero);
  });

  testWidgets('customer phone lookup is debounced (~300ms, one query)',
      (tester) async {
    final cart = Cart.empty().add(product);
    final debts = _CountingDebtsRepository();

    await tester.pumpWidget(buildSubject(cart: cart, debts: debts));
    await openSheet(tester);

    await tester.tap(find.text('Credit'));
    await tester.pumpAndSettle();

    final phoneField = find.widgetWithText(TextField, 'Phone (optional)');
    await tester.ensureVisible(phoneField);

    // Three quick keystrokes: no query fires while typing continues.
    await tester.enterText(phoneField, '0911');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(phoneField, '09112');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(phoneField, '091123');
    await tester.pump(const Duration(milliseconds: 100));
    expect(debts.lookups, 0);

    // After the pause, exactly one lookup for the final value.
    await tester.pump(const Duration(milliseconds: 300));
    expect(debts.lookups, 1);
    await tester.pumpAndSettle();
  });
}
