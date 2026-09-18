import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/data/styles_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/domain/entities/style.dart';
import 'package:suuqii/features/inventory/presentation/style_screen.dart';
import 'package:suuqii/features/inventory/presentation/style_sheets.dart';
import 'package:suuqii/l10n/app_localizations.dart';

class _TestAuthController extends AuthController {
  _TestAuthController(this.auth);

  final AuthState auth;

  @override
  Future<AuthState> build() async => auth;
}

const _ownerAuth = Authenticated(
  userId: 'user-1',
  shopId: 'shop-1',
  role: 'owner',
  userName: 'Owner',
  shopName: 'Bole Boutique',
  accessToken: 'token',
  shopType: 'boutique',
);

const _cashierAuth = Authenticated(
  userId: 'user-2',
  shopId: 'shop-1',
  role: 'cashier',
  userName: 'Cashier',
  shopName: 'Bole Boutique',
  accessToken: 'token',
  shopType: 'boutique',
);

final _style = Style(
  id: 'style-1',
  shopId: 'shop-1',
  name: 'Slim jeans',
  defaultSellingPrice: Decimal.parse('1200'),
  defaultPurchasePrice: Decimal.parse('800'),
  sizeSet: 'waist',
);

Product _variant(String id, {required String size, required int stock}) =>
    Product(
      id: id,
      shopId: 'shop-1',
      name: 'Slim jeans · $size',
      purchasePrice: Decimal.parse('800'),
      sellingPrice: Decimal.parse('1200'),
      stock: Decimal.fromInt(stock),
      lowStockThreshold: Decimal.one,
      unit: 'piece',
      styleId: 'style-1',
      size: size,
    );

void main() {
  Widget buildStyleScreen(
    List<Product> variants, {
    Authenticated auth = _ownerAuth,
  }) {
    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => _TestAuthController(auth)),
        watchStyleProvider('style-1').overrideWith(
          (_) => Stream.value(_style),
        ),
        watchVariantsProvider('style-1').overrideWith(
          (_) => Stream.value(variants),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const StyleScreen(styleId: 'style-1'),
      ),
    );
  }

  Widget buildEditSheetHost({required bool isOwner}) {
    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(
          () => _TestAuthController(isOwner ? _ownerAuth : _cashierAuth),
        ),
        watchCategoriesProvider.overrideWith(
          (_) => Stream.value(const <String>['Jeans']),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showStyleEditSheet(
                context,
                style: _style,
                isOwner: isOwner,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('"sizes missing" counts a size at its threshold, not only zero',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 1 unit left at a threshold of 1 is "missing" for the summary query and
    // for the server (docs/19 §13.4); the screen must not disagree by using
    // stock <= 0.
    await tester.pumpWidget(
      buildStyleScreen([
        _variant('v-32', size: '32', stock: 5),
        _variant('v-34', size: '34', stock: 1),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sizes missing'), findsOneWidget);
  });

  testWidgets('a fully stocked run shows no "sizes missing" pill',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildStyleScreen([
        _variant('v-32', size: '32', stock: 5),
        _variant('v-34', size: '34', stock: 4),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sizes missing'), findsNothing);
  });

  testWidgets('a cashier is not offered the mark-down switch', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildEditSheetHost(isOwner: false));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'open'));
    await tester.pumpAndSettle();
    // `_style_update` answers `forbidden` for a cashier, so offering the
    // switch would only make the new prices revert at the next sync.
    expect(find.text('Apply price to every size and colour'), findsNothing);
    // The rest of the sheet is still theirs to edit.
    expect(find.text('Name'), findsOneWidget);
  });

  testWidgets('the owner keeps the mark-down switch', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildEditSheetHost(isOwner: true));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'open'));
    await tester.pumpAndSettle();
    expect(find.text('Apply price to every size and colour'), findsOneWidget);
  });

  testWidgets('a cashier is not offered the mark-down action', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(
            () => _TestAuthController(_cashierAuth),
          ),
          watchStyleProvider('style-1').overrideWith(
            (_) => Stream.value(_style),
          ),
          watchVariantsProvider('style-1').overrideWith(
            (_) => Stream.value([_variant('v-32', size: '32', stock: 5)]),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const StyleScreen(styleId: 'style-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Mark down'), findsNothing);
    expect(find.text('Edit style'), findsOneWidget);
  });

  testWidgets('the owner can open the size curve for the style',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildStyleScreen([_variant('v-32', size: '32', stock: 5)]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Size curve'), findsOneWidget);
  });

  testWidgets('a cashier gets no size curve — it is an owner report',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildStyleScreen(
        [_variant('v-32', size: '32', stock: 5)],
        auth: _cashierAuth,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Size curve'), findsNothing);
    // The stock actions a cashier does have are untouched.
    expect(find.text('Receive shipment'), findsOneWidget);
  });
}
