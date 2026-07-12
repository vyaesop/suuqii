import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/presentation/product_edit_screen.dart';
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

  const cashierAuth = Authenticated(
    userId: 'user-2',
    shopId: 'shop-1',
    role: 'cashier',
    userName: 'Cashier',
    shopName: 'Shop',
    accessToken: 'token',
  );

  Widget buildSubject(Authenticated authState) {
    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(
          () => _TestAuthController(authState),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ProductEditScreen(),
      ),
    );
  }

  testWidgets('new product form shows the photo upload control', (tester) async {
    await tester.pumpWidget(buildSubject(auth));
    await tester.pumpAndSettle();

    expect(find.text('Upload photo'), findsOneWidget);
  });

  testWidgets('owner sees the purchase price field', (tester) async {
    await tester.pumpWidget(buildSubject(auth));
    await tester.pumpAndSettle();

    expect(find.text('Purchase'), findsOneWidget);
    expect(find.text('Selling price'), findsOneWidget);
  });

  testWidgets('cashier never sees the purchase price field', (tester) async {
    await tester.pumpWidget(buildSubject(cashierAuth));
    await tester.pumpAndSettle();

    expect(find.text('Purchase'), findsNothing);
    // The rest of the form is still available (PIN is collected on save).
    expect(find.text('Selling price'), findsOneWidget);
  });
}
