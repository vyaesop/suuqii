import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:suuqii/app/home_shell.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/dashboard/data/dashboard_repository.dart';
import 'package:suuqii/features/dashboard/presentation/owner_dashboard_screen.dart';
import 'package:suuqii/features/sales/data/sales_repository.dart';
import 'package:suuqii/features/sales/presentation/recent_sales_screen.dart';
import 'package:suuqii/features/sync/presentation/sync_status_badge.dart';
import 'package:suuqii/l10n/app_localizations.dart';

class _TestAuthController extends AuthController {
  _TestAuthController(this.auth);

  final AuthState auth;

  @override
  Future<AuthState> build() async => auth;
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

  final recentSale = RecentSale(
    id: 'sale-1',
    total: Decimal.parse('130'),
    paymentMethod: 'cash',
    status: 'completed',
    occurredAt: DateTime.utc(2026, 5, 18, 10, 0),
    itemCount: 2,
  );

  final summary = DashboardSummary(
    range: 'today',
    revenue: Decimal.parse('130'),
    profit: Decimal.parse('30'),
    expenses: Decimal.zero,
    netProfit: Decimal.parse('30'),
    creditSales: Decimal.zero,
    outstandingDebt: Decimal.zero,
    lowStock: const [],
    spoilageCost: Decimal.zero,
    fetchedAt: DateTime.utc(2026, 5, 18, 10, 0),
  );

  Widget buildSubject({
    required String initialLocation,
    List<Override> overrides = const [],
  }) {
    final router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        ShellRoute(
          builder: (_, __, child) => HomeShell(child: child),
          routes: [
            GoRoute(
              path: '/recent-sales',
              builder: (_, __) => const RecentSalesScreen(),
            ),
            GoRoute(
              path: '/owner',
              builder: (_, __) => const OwnerDashboardScreen(),
            ),
          ],
        ),
      ],
    );

    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => _TestAuthController(auth)),
        pendingSyncCountProvider.overrideWith((_) => Stream.value(0)),
        ...overrides,
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
  }

  testWidgets('recent sales route renders through the home shell',
      (tester) async {
    await tester.pumpWidget(
      buildSubject(
        initialLocation: '/recent-sales',
        overrides: [
          watchRecentSalesProvider.overrideWith(
            (_) => Stream.value([recentSale]),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Recent sales'), findsOneWidget);
    expect(find.text('Refund'), findsOneWidget);
    expect(find.text('ETB 130'), findsOneWidget);
  });

  testWidgets('dashboard route renders through the home shell',
      (tester) async {
    await tester.pumpWidget(
      buildSubject(
        initialLocation: '/owner',
        overrides: [
          dashboardProvider(range: DashboardRange.today).overrideWith(
            (_) async => summary,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('NET PROFIT'), findsOneWidget);
    expect(find.text('ETB 30'), findsWidgets);
    expect(find.text('All stock healthy'), findsOneWidget);
  });
}
