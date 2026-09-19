import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sales/presentation/cart_controller.dart';
import 'package:suuqii/features/sales/presentation/cart_review_sheet.dart';
import 'package:suuqii/l10n/app_localizations.dart';

/// Haggling was built per line but nobody could find it: the only affordance
/// was an underline on grey text, three screens deep. These tests pin the
/// control down as a labelled row so a refactor cannot quietly hide it again.

class _TestAuthController extends AuthController {
  _TestAuthController(this.auth);

  final AuthState auth;

  @override
  Future<AuthState> build() async => auth;
}

const _boutiqueOwner = Authenticated(
  userId: 'u-1',
  shopId: 'shop-1',
  role: 'owner',
  userName: 'Owner',
  shopName: 'Boutique',
  accessToken: 'token',
  shopType: 'boutique',
);

const _boutiqueCashier = Authenticated(
  userId: 'u-2',
  shopId: 'shop-1',
  role: 'cashier',
  userName: 'Cashier',
  shopName: 'Boutique',
  accessToken: 'token',
  shopType: 'boutique',
);

/// A regular shop has no line pricing at all — the price must stay inert.
const _regularCashier = Authenticated(
  userId: 'u-3',
  shopId: 'shop-2',
  role: 'cashier',
  userName: 'Cashier',
  shopName: 'Kiosk',
  accessToken: 'token',
);

final _jeans = Product(
  id: 'jeans-32',
  shopId: 'shop-1',
  name: 'Slim jeans · 32 · Blue',
  purchasePrice: Decimal.parse('1000'),
  sellingPrice: Decimal.parse('2000'),
  minSellingPrice: Decimal.parse('1500'),
  stock: Decimal.parse('5'),
  lowStockThreshold: Decimal.one,
  unit: 'piece',
  styleId: 'style-1',
  size: '32',
  color: 'Blue',
);

Widget _subject(AuthState auth) => ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => _TestAuthController(auth)),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: CartReviewSheet()),
      ),
    );

/// The sheet closes itself on an empty cart, so every case seeds a line
/// through the real controller before the first frame settles.
Future<void> _pumpWithLine(WidgetTester tester, AuthState auth) async {
  final widget = _subject(auth);
  await tester.pumpWidget(widget);
  final element = tester.element(find.byType(CartReviewSheet));
  ProviderScope.containerOf(element)
      .read(cartControllerProvider.notifier)
      .addProduct(_jeans);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the price reads as a control, not as text', (tester) async {
    await _pumpWithLine(tester, _boutiqueCashier);

    // Label, pencil and chevron together are what make it look tappable.
    expect(find.text('Price'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(find.text('ETB 2,000 / piece'), findsOneWidget);
  });

  testWidgets('tapping it opens the negotiated-price dialog with the minimum '
      'already visible', (tester) async {
    await _pumpWithLine(tester, _boutiqueCashier);

    await tester.tap(find.text('Price'));
    await tester.pumpAndSettle();

    expect(find.text('Sold at'), findsOneWidget);
    expect(find.text('Negotiated price'), findsOneWidget);
    // The cashier must know their room to move before typing, so they never
    // burn the owner's PIN discovering where the floor is.
    expect(find.textContaining('Minimum ETB 1,500'), findsOneWidget);
    expect(find.textContaining('List price ETB 2,000'), findsOneWidget);
  });

  testWidgets('a negotiated price shows the tag price struck through',
      (tester) async {
    await _pumpWithLine(tester, _boutiqueOwner);
    final element = tester.element(find.byType(CartReviewSheet));
    ProviderScope.containerOf(element)
        .read(cartControllerProvider.notifier)
        .setUnitPrice(_jeans.id, Decimal.parse('1600'));
    await tester.pumpAndSettle();

    expect(find.text('ETB 1,600 / piece'), findsOneWidget);
    expect(find.text('was ETB 2,000'), findsOneWidget);
    // 1,600 clears the 1,500 floor, so no approval warning belongs here.
    expect(
      find.textContaining('Below the minimum'),
      findsNothing,
    );
  });

  testWidgets('below the floor a cashier is warned before checkout',
      (tester) async {
    await _pumpWithLine(tester, _boutiqueCashier);
    final element = tester.element(find.byType(CartReviewSheet));
    ProviderScope.containerOf(element)
        .read(cartControllerProvider.notifier)
        .setUnitPrice(_jeans.id, Decimal.parse('1400'));
    await tester.pumpAndSettle();

    expect(
      find.text('Below the minimum — owner PIN needed at checkout'),
      findsOneWidget,
    );
  });

  testWidgets('a shop without line pricing gets plain, inert price text',
      (tester) async {
    await _pumpWithLine(tester, _regularCashier);

    expect(find.text('ETB 2,000 / piece'), findsOneWidget);
    expect(find.text('Price'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
  });
}
