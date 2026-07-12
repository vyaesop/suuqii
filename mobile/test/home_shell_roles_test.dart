import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:suuqii/app/home_shell.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/sync/presentation/sync_status_badge.dart';
import 'package:suuqii/l10n/app_localizations.dart';

class _TestAuthController extends AuthController {
  _TestAuthController(this.auth);

  final AuthState auth;

  @override
  Future<AuthState> build() async => auth;
}

Authenticated _auth(String role) => Authenticated(
      userId: 'user-1',
      shopId: 'shop-1',
      role: role,
      userName: 'User',
      shopName: 'Shop',
      accessToken: 'token',
    );

Widget _buildShell(Authenticated auth) {
  final router = GoRouter(
    initialLocation: '/pos',
    routes: [
      ShellRoute(
        builder: (_, __, child) => HomeShell(child: child),
        routes: [
          GoRoute(path: '/pos', builder: (_, __) => const Placeholder()),
        ],
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(() => _TestAuthController(auth)),
      pendingSyncCountProvider.overrideWith((_) => Stream.value(0)),
    ],
    child: MaterialApp.router(
      theme: AppTheme.light(),
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
}

void main() {
  testWidgets('cashier bottom navigation has no owner Dashboard item',
      (tester) async {
    await tester.pumpWidget(_buildShell(_auth('cashier')));
    await tester.pumpAndSettle();

    Finder navLabel(String label) => find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        );

    expect(find.text('Dashboard'), findsNothing);
    // Cashiers get the settings tab in the dashboard slot instead.
    expect(navLabel('Settings'), findsOneWidget);
    expect(navLabel('Sell'), findsOneWidget);
    expect(navLabel('Inventory'), findsOneWidget);
    expect(navLabel('Debts'), findsOneWidget);
    expect(navLabel('Shift'), findsOneWidget);
  });

  testWidgets('owner bottom navigation shows the Dashboard item',
      (tester) async {
    await tester.pumpWidget(_buildShell(_auth('owner')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Dashboard'),
      ),
      findsOneWidget,
    );
  });
}
