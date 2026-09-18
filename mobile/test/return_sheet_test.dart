import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/sales/data/sales_repository.dart';
import 'package:suuqii/features/sales/domain/entities/sale_return.dart';
import 'package:suuqii/features/sales/presentation/return_sheet.dart';
import 'package:suuqii/l10n/app_localizations.dart';

void main() {
  /// Two jeans lines: 2 × size 32 (nothing back yet) and 1 × size 34
  /// already fully returned on an earlier return.
  SaleReceiptData sale() => SaleReceiptData(
        id: 'abcd1234efgh',
        subtotal: Decimal.parse('3600'),
        discount: Decimal.zero,
        total: Decimal.parse('3600'),
        paymentMethod: 'cash',
        status: 'partially_returned',
        occurredAt: DateTime.utc(2026, 9, 15, 10),
        items: [
          SaleReceiptItem(
            id: 'i1',
            productId: 'p32',
            name: 'Slim jeans · 32 · Blue',
            quantity: 2,
            unitPrice: Decimal.parse('1200'),
            listPrice: Decimal.parse('1200'),
          ),
          SaleReceiptItem(
            id: 'i2',
            productId: 'p34',
            name: 'Slim jeans · 34 · Blue',
            quantity: 1,
            unitPrice: Decimal.parse('1200'),
            returnedQuantity: 1,
          ),
        ],
      );

  const fullCredit = ReturnCreditCalculator(
    subtotalSantim: 360000,
    effectiveTotalSantim: 360000,
  );

  /// One line of 2 with 1.5 already back: half a unit left to return.
  SaleReceiptData fractionalSale() => SaleReceiptData(
        id: 'abcd1234efgh',
        subtotal: Decimal.parse('2400'),
        discount: Decimal.zero,
        total: Decimal.parse('2400'),
        paymentMethod: 'cash',
        status: 'partially_returned',
        occurredAt: DateTime.utc(2026, 9, 15, 10),
        items: [
          SaleReceiptItem(
            id: 'i1',
            productId: 'p32',
            name: 'Ankara fabric',
            quantity: 2,
            unitPrice: Decimal.parse('1200'),
            returnedQuantity: 1.5,
          ),
        ],
      );

  Widget buildSubject({
    ReturnCreditCalculator calculator = fullCredit,
    bool outsideWindow = false,
    ValueChanged<ReturnSheetResult?>? onResult,
    SaleReceiptData? data,
  }) {
    return MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                final result = await showReturnSheet(
                  context,
                  sale: data ?? sale(),
                  calculator: calculator,
                  outsideWindow: outsideWindow,
                  returnWindowDays: 7,
                );
                onResult?.call(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder checkboxOf(String name) => find.descendant(
        of: find.ancestor(of: find.text(name), matching: find.byType(Row)).first,
        matching: find.byType(Checkbox),
      );

  testWidgets('a reason is required before refunding', (tester) async {
    ReturnSheetResult? result;
    await tester.pumpWidget(buildSubject(onResult: (r) => result = r));
    await open(tester);

    // Nothing ticked: both actions are disabled and the credit reads zero.
    expect(find.text('Credit'), findsOneWidget);
    expect(find.text('ETB 0'), findsWidgets);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
      isNull,
    );

    await tester.tap(checkboxOf('Slim jeans · 32 · Blue'));
    await tester.pumpAndSettle();
    expect(find.text('Refund ETB 1,200'), findsOneWidget);

    await tester.ensureVisible(find.text('Refund ETB 1,200'));
    await tester.tap(find.text('Refund ETB 1,200'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a reason'), findsOneWidget);
    expect(result, isNull);
    // The sheet is still open.
    expect(find.text('Return / exchange'), findsOneWidget);
  });

  testWidgets('quantity is capped at what is left to return', (tester) async {
    await tester.pumpWidget(buildSubject());
    await open(tester);

    // Fully returned line cannot be ticked.
    expect(find.text('Fully returned'), findsOneWidget);
    expect(
      tester.widget<Checkbox>(checkboxOf('Slim jeans · 34 · Blue')).onChanged,
      isNull,
    );

    await tester.tap(checkboxOf('Slim jeans · 32 · Blue'));
    await tester.pumpAndSettle();
    final plus = find.byKey(const ValueKey('return_plus_i1'));
    expect(tester.widget<IconButton>(plus).onPressed, isNotNull);
    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(find.text('ETB 2,400'), findsWidgets);
    // Two sold, two ticked: no third.
    expect(tester.widget<IconButton>(plus).onPressed, isNull);

    // Stepping down to zero unticks the line again.
    final minus = find.byKey(const ValueKey('return_minus_i1'));
    await tester.tap(minus);
    await tester.pumpAndSettle();
    await tester.tap(minus);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('return_plus_i1')), findsNothing);
    expect(
      tester.widget<Checkbox>(checkboxOf('Slim jeans · 32 · Blue')).value,
      isFalse,
    );
  });

  testWidgets('"Return everything" ticks every remaining unit', (tester) async {
    await tester.pumpWidget(buildSubject());
    await open(tester);
    await tester.tap(find.text('Return everything'));
    await tester.pumpAndSettle();
    expect(find.text('Refund ETB 2,400'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('return_plus_i1')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('refund carries amount and method; amount is bounded by credit',
      (tester) async {
    ReturnSheetResult? result;
    await tester.pumpWidget(buildSubject(onResult: (r) => result = r));
    await open(tester);

    await tester.tap(checkboxOf('Slim jeans · 32 · Blue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Damaged'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Defect'));
    await tester.pumpAndSettle();

    final amount = find.widgetWithText(TextField, 'Refund amount');
    await tester.ensureVisible(amount);
    // Over the credit → refused with the ceiling in the message.
    await tester.enterText(amount, '1500');
    await tester.pump();
    await tester.tap(find.text('Refund ETB 1,500'));
    await tester.pumpAndSettle();
    expect(find.text('Refund must be between 0 and ETB 1,200'), findsOneWidget);
    expect(result, isNull);

    // Partial refund of the credit is fine (store credit for the rest).
    await tester.enterText(amount, '500');
    await tester.pump();
    await tester.tap(find.text('Mobile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refund ETB 500'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.isExchange, isFalse);
    expect(result!.refundAmount, Decimal.parse('500'));
    expect(result!.refundMethod, RefundMethod.mobileMoney);
    expect(result!.reason, ReturnReason.defect);
    expect(result!.credit, Decimal.parse('1200'));
    expect(result!.items.single.saleItemId, 'i1');
    expect(result!.items.single.quantity, Decimal.one);
    expect(result!.items.single.condition, ReturnCondition.damaged);
  });

  testWidgets('exchange hands the ticked lines and credit to the POS',
      (tester) async {
    ReturnSheetResult? result;
    await tester.pumpWidget(buildSubject(onResult: (r) => result = r));
    await open(tester);

    await tester.tap(checkboxOf('Slim jeans · 32 · Blue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wrong size'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Note (optional)'),
      'wants a 34',
    );
    await tester.ensureVisible(find.text('Exchange'));
    await tester.tap(find.text('Exchange'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.isExchange, isTrue);
    expect(result!.refundAmount, isNull);
    expect(result!.credit, Decimal.parse('1200'));
    expect(result!.reason, ReturnReason.wrongSize);
    expect(result!.note, 'wants a 34');
  });

  testWidgets('a fractional remainder is ticked as the remainder, not 1',
      (tester) async {
    ReturnSheetResult? result;
    await tester.pumpWidget(
      buildSubject(data: fractionalSale(), onResult: (r) => result = r),
    );
    await open(tester);

    await tester.tap(checkboxOf('Ankara fabric'));
    await tester.pumpAndSettle();
    // Half a unit is all that is left; seeding 1 would bounce off the server
    // with `return_exceeds_sold`.
    expect(find.text('Refund ETB 600'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('return_plus_i1')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('Defect'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Refund ETB 600'));
    await tester.tap(find.text('Refund ETB 600'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.items.single.quantity, Decimal.parse('0.5'));
    expect(result!.credit, Decimal.parse('600'));
  });

  testWidgets('credit follows the proportional rule and the window warning',
      (tester) async {
    // 10% off on the original sale: 1200 → 1080 per unit.
    const discounted = ReturnCreditCalculator(
      subtotalSantim: 360000,
      effectiveTotalSantim: 324000,
    );
    await tester.pumpWidget(
      buildSubject(calculator: discounted, outsideWindow: true),
    );
    await open(tester);
    expect(
      find.textContaining('older than the 7-day return window'),
      findsOneWidget,
    );
    await tester.tap(checkboxOf('Slim jeans · 32 · Blue'));
    await tester.pumpAndSettle();
    expect(find.text('Refund ETB 1,080'), findsOneWidget);
    expect(find.text('Up to ETB 1,080'), findsOneWidget);
  });
}
