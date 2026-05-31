import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/presentation/product_edit_screen.dart';

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

  testWidgets('new product form shows the image URL field', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(() => _TestAuthController(auth)),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ProductEditScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Image URL (optional)'), findsOneWidget);
    expect(find.text('Paste a public image link'), findsOneWidget);
  });
}
