import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/sheet_snackbar_observer.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/sales/presentation/receipt_sheet.dart';
import 'package:suuqii/l10n/app_localizations.dart';

/// The "can't tap New sale" report: the POS lives inside the go_router
/// ShellRoute, so its sheets open on the shell's nested navigator while
/// snackbars paint on the outer (shell) Scaffold — on top of the sheet's
/// bottom buttons. These tests rebuild that layering.
void main() {
  final product = Product(
    id: 'p1',
    shopId: 'shop-1',
    name: 'Crop · M · Red',
    purchasePrice: Decimal.parse('1500'),
    sellingPrice: Decimal.parse('3200'),
    stock: Decimal.parse('5'),
    lowStockThreshold: Decimal.parse('1'),
    unit: 'piece',
  );

  Widget shell({List<NavigatorObserver> observers = const []}) {
    return MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        bottomNavigationBar: NavigationBar(
          destinations: const [
            NavigationDestination(icon: Icon(Icons.sell), label: 'Sell'),
            NavigationDestination(icon: Icon(Icons.inventory), label: 'Inv'),
          ],
        ),
        body: Navigator(
          observers: observers,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton(
                      onPressed: () =>
                          ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Low stock')),
                      ),
                      child: const Text('notify'),
                    ),
                    FilledButton(
                      onPressed: () => showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        builder: (_) => ReceiptSheet(
                          cart: Cart.empty().add(product),
                          paymentMethod: PaymentMethod.mobileMoney,
                          saleId: 'a5dcd521-0000-0000-0000-000000000000',
                          soldAt: DateTime.utc(2026, 9, 22, 7, 7),
                        ),
                      ),
                      child: const Text('open'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Taps the bottom edge of "New sale" — where a thumb usually lands, and
  /// where a floating snackbar above the bottom nav used to sit.
  Future<void> tapNewSaleBottomEdge(WidgetTester tester) async {
    final button = tester.getRect(
      find.ancestor(
        of: find.text('New sale'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    await tester.tapAt(Offset(button.center.dx, button.bottom - 2));
    await tester.pumpAndSettle();
  }

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  testWidgets('New sale still closes the receipt right after Copy',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(shell());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Sale recorded'), findsOneWidget);

    await tester.tap(find.text('Copy'));
    await tester.pump();
    // Confirmed on the button itself — no snackbar over the sheet.
    expect(find.text('Receipt copied'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    await tapNewSaleBottomEdge(tester);
    expect(find.text('Sale recorded'), findsNothing);
  });

  testWidgets('a snackbar left over from the page is cleared when a sheet '
      'opens', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(shell(observers: [SheetSnackBarObserver()]));

    await tester.tap(find.text('notify'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);

    await tapNewSaleBottomEdge(tester);
    expect(find.text('Sale recorded'), findsNothing);
  });
}
