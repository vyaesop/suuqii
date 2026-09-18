import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/presentation/style_wizard_screen.dart';
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
    shopName: 'Bole Boutique',
    accessToken: 'token',
    shopType: 'boutique',
  );

  Widget buildSubject() {
    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => _TestAuthController(auth)),
        watchCategoriesProvider.overrideWith(
          (_) => Stream.value(const <String>['Jeans']),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const StyleWizardScreen(),
      ),
    );
  }

  Future<void> addColour(WidgetTester tester, String colour) async {
    await tester.enterText(find.widgetWithText(TextField, 'Colour'), colour);
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
  }

  testWidgets('letter set × 2 colours produces 14 variants', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    // Letter is the default preset: one variant per size.
    expect(find.text('7 variants'), findsOneWidget);

    await addColour(tester, 'Blue');
    await addColour(tester, 'ቀይ');
    expect(find.text('14 variants'), findsOneWidget);
    // The colour axis shows up as matrix row labels.
    expect(find.text('ቀይ'), findsWidgets);
  });

  testWidgets('deselecting a size shrinks the matrix', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    await addColour(tester, 'Blue');
    await addColour(tester, 'Red');
    expect(find.text('14 variants'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'XS'));
    await tester.pumpAndSettle();
    expect(find.text('12 variants'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, '3XL'));
    await tester.pumpAndSettle();
    expect(find.text('10 variants'), findsOneWidget);
  });

  testWidgets('custom sizes parse from comma-separated text', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'Custom'));
    await tester.pumpAndSettle();
    // No sizes typed yet → a single free-size variant.
    expect(find.text('1 variant'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Custom sizes'),
      'S, M ,L,,',
    );
    await tester.pumpAndSettle();
    expect(find.text('3 variants'), findsOneWidget);

    await addColour(tester, 'Blue');
    await addColour(tester, 'Red');
    expect(find.text('6 variants'), findsOneWidget);
  });

  testWidgets('a matrix over the 200-variant cap is flagged and blocks save',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Bangles',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Selling price'),
      '120',
    );
    await tester.tap(find.widgetWithText(ChoiceChip, 'Custom'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Custom sizes'),
      [for (var i = 0; i < 101; i++) 's$i'].join(','),
    );
    await tester.pumpAndSettle();
    await addColour(tester, 'Blue');
    await addColour(tester, 'Red');

    // 101 sizes × 2 colours = 202: the server would answer `invalid_payload`
    // and the reconciler would soft-delete the lot.
    expect(find.text('202 variants'), findsOneWidget);
    final count = tester.widget<Text>(find.text('202 variants'));
    final theme = Theme.of(tester.element(find.text('202 variants')));
    expect(count.style?.color, theme.colorScheme.error);
    expect(find.textContaining('at most 200 variants'), findsOneWidget);
    expect(find.text('Enter what you have per size and colour. Leave blank for none.'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Create style'));
    await tester.pumpAndSettle();
    // Blocked before any local write: the snackbar is the only outcome.
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('at most 200 variants'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('free size is a single variant per colour', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'Free size'));
    await tester.pumpAndSettle();
    expect(find.text('1 variant'), findsOneWidget);

    await addColour(tester, 'Black');
    await addColour(tester, 'Brown');
    expect(find.text('2 variants'), findsOneWidget);
  });
}
