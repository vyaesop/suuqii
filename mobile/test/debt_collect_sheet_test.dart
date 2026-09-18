import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/debt/data/debts_repository.dart';
import 'package:suuqii/features/debt/domain/entities/debt.dart';
import 'package:suuqii/features/debt/presentation/debt_detail_screen.dart';
import 'package:suuqii/l10n/app_localizations.dart';

void main() {
  const debtId = 'debt-1';

  Debt debt({String owed = '130', String paid = '0'}) => Debt(
        id: debtId,
        shopId: 'shop-1',
        customerName: 'Abebe',
        amountOwed: Decimal.parse(owed),
        amountPaid: Decimal.parse(paid),
        status: DebtStatus.open,
      );

  Widget buildSubject(Debt d) {
    return ProviderScope(
      overrides: [
        watchDebtsProvider().overrideWith((_) => Stream.value([d])),
        watchDebtPaymentsProvider(debtId)
            .overrideWith((_) => Stream.value(const <DebtPayment>[])),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const DebtDetailScreen(debtId: debtId),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
  }

  String amountFieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).controller!.text;

  Future<void> openSheet(WidgetTester tester, Debt d) async {
    await tester.pumpWidget(buildSubject(d));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Collect payment'));
    await tester.pumpAndSettle();
  }

  testWidgets('half chip fills half the remaining balance with a preview',
      (tester) async {
    await openSheet(tester, debt());

    // Prefilled with the full remaining balance; nothing would remain.
    expect(amountFieldText(tester), '130');
    expect(
      find.textContaining('Remaining after this payment'),
      findsNothing,
    );

    await tester.tap(find.text('Half'));
    await tester.pumpAndSettle();

    expect(amountFieldText(tester), '65');
    expect(
      find.text('Remaining after this payment: ETB 65'),
      findsOneWidget,
    );

    await tester.tap(find.text('Full'));
    await tester.pumpAndSettle();

    expect(amountFieldText(tester), '130');
    expect(
      find.textContaining('Remaining after this payment'),
      findsNothing,
    );
  });

  testWidgets('half of an odd remainder rounds up to a whole santim',
      (tester) async {
    // Remaining 100.01 birr = 10001 santim → half rounds up to 50.01.
    await openSheet(tester, debt(owed: '100.01'));

    await tester.tap(find.text('Half'));
    await tester.pumpAndSettle();

    expect(amountFieldText(tester), '50.01');
    expect(
      find.text('Remaining after this payment: ETB 50'),
      findsOneWidget,
    );
  });

  testWidgets('manual edits keep the live remaining-after preview',
      (tester) async {
    await openSheet(tester, debt());

    await tester.enterText(find.byType(TextField).first, '30');
    await tester.pumpAndSettle();

    expect(
      find.text('Remaining after this payment: ETB 100'),
      findsOneWidget,
    );
  });
}
