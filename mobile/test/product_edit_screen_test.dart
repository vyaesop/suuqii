import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/presentation/product_edit_screen.dart';
import 'package:suuqii/l10n/app_localizations.dart';

class _TestAuthController extends AuthController {
  _TestAuthController(this.auth);

  final AuthState auth;

  @override
  Future<AuthState> build() async => auth;
}

/// Answers the SKU-uniqueness question without a database — the query itself
/// is covered by the DAO test in `styles_db_test.dart`, and real sqlite I/O
/// does not settle inside `testWidgets`' fake async zone. Creating a product
/// is the only other repository call this screen makes, and this test never
/// gets that far.
class _StubProductsRepository extends Fake implements ProductsRepository {
  static const takenSku = 'JN-32-BLU';

  @override
  Future<bool> isSkuTaken(String sku, {String? excludingProductId}) async =>
      sku.trim().toUpperCase() == takenSku;
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

  const boutiqueAuth = Authenticated(
    userId: 'user-1',
    shopId: 'shop-1',
    role: 'owner',
    userName: 'Owner',
    shopName: 'Boutique',
    accessToken: 'token',
    shopType: 'boutique',
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

  testWidgets('regular shop shows the unit picker and no SKU / floor fields',
      (tester) async {
    await tester.pumpWidget(buildSubject(auth));
    await tester.pumpAndSettle();

    expect(find.text('Unit'), findsOneWidget);
    expect(find.text('SKU (optional)'), findsNothing);
    expect(find.text('Minimum selling price (optional)'), findsNothing);
  });

  testWidgets('boutique hides the unit picker and shows SKU + floor price',
      (tester) async {
    await tester.pumpWidget(buildSubject(boutiqueAuth));
    await tester.pumpAndSettle();

    // Unit is locked to piece (docs/19 §13.1): no picker at all.
    expect(find.text('Unit'), findsNothing);
    expect(find.text('SKU (optional)'), findsOneWidget);
    expect(find.text('Minimum selling price (optional)'), findsOneWidget);
    // Cost stays an explicit purchase price (no recipe) for the owner.
    expect(find.text('Purchase'), findsOneWidget);
  });

  testWidgets('cashier never sees the purchase price field', (tester) async {
    await tester.pumpWidget(buildSubject(cashierAuth));
    await tester.pumpAndSettle();

    expect(find.text('Purchase'), findsNothing);
    // The rest of the form is still available (PIN is collected on save).
    expect(find.text('Selling price'), findsOneWidget);
  });

  testWidgets('a hand-typed SKU already in use is refused inline',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(
            () => _TestAuthController(boutiqueAuth),
          ),
          productsRepositoryProvider.overrideWithValue(
            _StubProductsRepository(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ProductEditScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Tee');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Purchase'),
      '800',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Selling price'),
      '1200',
    );
    // Typed in another case: the SKU goes to the server upper-cased, so this
    // is the duplicate that would come back as a terminal `sku_collision`.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'SKU (optional)'),
      'jn-32-blu',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create product'));
    await tester.pumpAndSettle();

    expect(
      find.text('That SKU is already used by another product'),
      findsOneWidget,
    );

    // Editing the field clears the error so the next attempt is judged fresh.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'SKU (optional)'),
      'JN-34-BLU',
    );
    await tester.pumpAndSettle();
    expect(
      find.text('That SKU is already used by another product'),
      findsNothing,
    );
  });
}
