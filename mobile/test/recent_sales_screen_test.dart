import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/sales/data/sales_repository.dart';
import 'package:suuqii/features/sales/presentation/recent_sales_screen.dart';
import 'package:suuqii/l10n/app_localizations.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

class _TestAuthController extends AuthController {
  _TestAuthController(this.auth);

  final AuthState auth;

  @override
  Future<AuthState> build() async => auth;
}

RecentSale _sale(String id, String status) => RecentSale(
      id: id,
      total: Decimal.parse('1200'),
      paymentMethod: 'cash',
      status: status,
      occurredAt: DateTime.utc(2026, 9, 17, 10),
      itemCount: 2,
    );

void main() {
  const boutiqueAuth = Authenticated(
    userId: 'user-1',
    shopId: 'shop-1',
    role: 'owner',
    userName: 'Owner',
    shopName: 'Bole Boutique',
    accessToken: 'token',
    shopType: 'boutique',
  );

  Widget buildSubject(List<RecentSale> sales) {
    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(
          () => _TestAuthController(boutiqueAuth),
        ),
        watchRecentSalesProvider.overrideWith((_) => Stream.value(sales)),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const RecentSalesScreen(),
      ),
    );
  }

  testWidgets('a partially returned sale shows the chip and stays returnable',
      (tester) async {
    await tester.pumpWidget(buildSubject([_sale('s-1', 'partially_returned')]));
    await tester.pumpAndSettle();

    expect(find.text('PARTLY RETURNED'), findsOneWidget);
    expect(
      tester.widget<StatusPill>(find.byType(StatusPill)).intent,
      PillIntent.warning,
    );
    // Unlike a refunded sale, more lines can still come back.
    expect(find.text('Return'), findsOneWidget);
  });

  testWidgets('a refunded sale shows only the refunded chip', (tester) async {
    await tester.pumpWidget(buildSubject([_sale('s-2', 'refunded')]));
    await tester.pumpAndSettle();

    expect(find.text('REFUNDED'), findsOneWidget);
    expect(find.text('Return'), findsNothing);
  });

  testWidgets('a completed sale has no status chip', (tester) async {
    await tester.pumpWidget(buildSubject([_sale('s-3', 'completed')]));
    await tester.pumpAndSettle();

    expect(find.byType(StatusPill), findsNothing);
    expect(find.text('Return'), findsOneWidget);
  });
}
