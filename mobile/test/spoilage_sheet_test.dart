import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/core/shop_type/shop_features.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/stock_lot.dart';
import 'package:suuqii/features/inventory/presentation/spoilage_sheet.dart';
import 'package:suuqii/l10n/app_localizations.dart';

/// The reason list follows the damaged/lost *wording* feature, not the
/// unit lock: a shop can round quantities without selling goods that never
/// expire (docs/19 §13.1).
void main() {
  Widget buildSheet({required bool damagedLostWording}) {
    return ProviderScope(
      overrides: [
        watchProductLotsProvider('p-1').overrideWith(
          (_) => Stream.value(const <StockLot>[]),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SpoilageSheet(
            productId: 'p-1',
            productUnit: 'piece',
            integerOnly: true,
            damagedLostWording: damagedLostWording,
          ),
        ),
      ),
    );
  }

  Future<List<String>> reasons(WidgetTester tester) async {
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    // Each item is rendered twice while the menu is open (button + menu), so
    // dedupe before comparing.
    return tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .toSet()
        .toList();
  }

  testWidgets('a boutique offers damaged / theft / other', (tester) async {
    await tester.pumpWidget(buildSheet(damagedLostWording: true));
    await tester.pumpAndSettle();
    final labels = await reasons(tester);
    expect(labels, containsAll(<String>['damaged', 'theft', 'other']));
    expect(labels, isNot(contains('expired')));
    expect(labels, isNot(contains('day-old')));
  });

  testWidgets('every other shop keeps expired / damaged / day-old / other',
      (tester) async {
    await tester.pumpWidget(buildSheet(damagedLostWording: false));
    await tester.pumpAndSettle();
    final labels = await reasons(tester);
    expect(
      labels,
      containsAll(<String>['expired', 'damaged', 'day-old', 'other']),
    );
    expect(labels, isNot(contains('theft')));
  });

  test('the boutique feature set asks for the damaged / lost wording', () {
    expect(ShopFeatures.boutique.isDamagedLostWording, isTrue);
    expect(ShopFeatures.bakery.isDamagedLostWording, isFalse);
    // Locking units is a different question from the wording.
    expect(ShopFeatures.boutique.locksUnit, isTrue);
  });
}
