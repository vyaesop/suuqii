import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/sales/data/sale_returns_dao.dart';
import 'package:suuqii/features/sales/data/sales_repository.dart';
import 'package:suuqii/features/sales/domain/entities/sale_return.dart';
import 'package:suuqii/features/sales/presentation/sale_detail_screen.dart';
import 'package:suuqii/l10n/app_localizations.dart';

class _TestAuthController extends AuthController {
  _TestAuthController(this.auth);

  final AuthState auth;

  @override
  Future<AuthState> build() async => auth;
}

void main() {
  const regularAuth = Authenticated(
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

  SaleReceiptData receipt({
    String status = 'completed',
    double breadReturned = 0,
    List<SaleReturnView> returns = const [],
  }) =>
      SaleReceiptData(
        id: 'abcd1234efgh',
        subtotal: Decimal.parse('80'),
        discount: Decimal.parse('5'),
        total: Decimal.parse('75'),
        paymentMethod: 'cash',
        status: status,
        occurredAt: DateTime.utc(2026, 5, 18, 10),
        items: [
          SaleReceiptItem(
            id: 'i-bread',
            name: 'Bread',
            quantity: 2,
            unitPrice: Decimal.parse('25'),
            returnedQuantity: breadReturned,
          ),
          SaleReceiptItem(
            id: 'i-milk',
            name: 'Milk',
            quantity: 1.5,
            unitPrice: Decimal.parse('20'),
          ),
        ],
        returns: returns,
      );

  Widget buildSubject(
    SaleReceiptData? data, {
    Authenticated auth = regularAuth,
  }) {
    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => _TestAuthController(auth)),
        saleReceiptProvider('abcd1234efgh').overrideWith((_) async => data),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const SaleDetailScreen(saleId: 'abcd1234efgh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
  }

  testWidgets('shows every line with quantity, price and totals',
      (tester) async {
    await tester.pumpWidget(buildSubject(receipt()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Sale details'), findsOneWidget);
    // Lines: name, qty x unit price, line total.
    expect(find.text('Bread'), findsOneWidget);
    expect(find.text('2 x ETB 25'), findsOneWidget);
    expect(find.text('ETB 50'), findsOneWidget);
    expect(find.text('Milk'), findsOneWidget);
    expect(find.text('1.50 x ETB 20'), findsOneWidget);
    expect(find.text('ETB 30'), findsOneWidget);
    // Totals card: subtotal, discount, grand total (header shows it too).
    expect(find.text('ETB 80'), findsOneWidget);
    expect(find.text('-ETB 5'), findsOneWidget);
    expect(find.text('ETB 75'), findsNWidgets(2));
    // Short sale reference (sits at the very bottom of the lazy list).
    await tester.scrollUntilVisible(find.text('#abcd1234'), 200);
    expect(find.text('#abcd1234'), findsOneWidget);
    expect(find.text('REFUNDED'), findsNothing);
  });

  testWidgets('refunded sale carries the REFUNDED pill', (tester) async {
    await tester.pumpWidget(buildSubject(receipt(status: 'refunded')));
    await tester.pumpAndSettle();

    expect(find.text('REFUNDED'), findsOneWidget);
  });

  testWidgets('unknown sale falls back to the not-found state',
      (tester) async {
    await tester.pumpWidget(buildSubject(null));
    await tester.pumpAndSettle();

    expect(find.text('Sale not found'), findsOneWidget);
  });

  group('Return / exchange button', () {
    testWidgets('is hidden for shops without returns', (tester) async {
      await tester.pumpWidget(buildSubject(receipt()));
      await tester.pumpAndSettle();
      expect(find.text('Return / exchange'), findsNothing);
      expect(find.text('Share'), findsOneWidget);
    });

    testWidgets('shows for a boutique sale that still has units to return',
        (tester) async {
      await tester.pumpWidget(buildSubject(receipt(), auth: boutiqueAuth));
      await tester.pumpAndSettle();
      expect(find.text('Return / exchange'), findsOneWidget);
    });

    testWidgets('stays for a partially returned sale, with the pill and '
        'returned quantities', (tester) async {
      await tester.pumpWidget(
        buildSubject(
          receipt(
            status: 'partially_returned',
            breadReturned: 1,
            returns: [
              SaleReturnView(
                id: 'ret-1',
                occurredAt: DateTime.utc(2026, 5, 19, 9),
                refundAmount: Decimal.parse('25'),
                refundMethod: RefundMethod.cash,
                exchangeSaleId: null,
                reason: ReturnReason.defect,
                note: null,
                items: [
                  SaleReturnItemView(
                    saleItemId: 'i-bread',
                    productName: 'Bread',
                    quantity: 1,
                    condition: ReturnCondition.damaged,
                    creditUnit: Decimal.fromInt(25),
                  ),
                ],
              ),
            ],
          ),
          auth: boutiqueAuth,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('PARTLY RETURNED'), findsOneWidget);
      expect(find.text('1 returned'), findsOneWidget);
      expect(find.text('Return / exchange'), findsOneWidget);
      // Returns block: header, the line, condition, refund. It sits below
      // the fold of the lazy list.
      await tester.scrollUntilVisible(find.text('RETURNS'), 200);
      expect(find.text('RETURNS'), findsOneWidget);
      expect(find.text('1 x Bread'), findsOneWidget);
      expect(find.text('Damaged'), findsOneWidget);
      expect(find.text('Refunded ETB 25'), findsOneWidget);
      expect(find.text('Defect'), findsOneWidget);
    });

    testWidgets('is hidden once the sale is fully refunded', (tester) async {
      await tester.pumpWidget(
        buildSubject(receipt(status: 'refunded'), auth: boutiqueAuth),
      );
      await tester.pumpAndSettle();
      expect(find.text('REFUNDED'), findsOneWidget);
      expect(find.text('Return / exchange'), findsNothing);
    });

    testWidgets('haggled lines show the tag price struck through',
        (tester) async {
      final data = SaleReceiptData(
        id: 'abcd1234efgh',
        subtotal: Decimal.parse('1000'),
        discount: Decimal.zero,
        total: Decimal.parse('1000'),
        paymentMethod: 'cash',
        status: 'completed',
        occurredAt: DateTime.utc(2026, 9, 1, 10),
        items: [
          SaleReceiptItem(
            id: 'i1',
            name: 'Slim jeans · 32 · Blue',
            quantity: 1,
            unitPrice: Decimal.parse('1000'),
            listPrice: Decimal.parse('1200'),
          ),
        ],
      );
      await tester.pumpWidget(buildSubject(data, auth: boutiqueAuth));
      await tester.pumpAndSettle();
      expect(find.text('was ETB 1,200'), findsOneWidget);
      final was = tester.widget<Text>(find.text('was ETB 1,200'));
      expect(was.style?.decoration, TextDecoration.lineThrough);
    });
  });
}
