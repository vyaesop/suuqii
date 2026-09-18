import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/shop_type/variant_naming.dart';

/// Name/SKU fixture copied verbatim from `backend/tests/test_variant_naming.py`
/// (docs/19 §13.2). It stays a JSON literal on both sides so the two lists can
/// be diffed by eye: change it in the Python test first, then here.
final nameFixture = (jsonDecode('''
[
  {"case": "name+size+color", "style": "Slim jeans", "size": "32", "color": "Blue",
   "prefix": "JN", "name": "Slim jeans · 32 · Blue", "sku": "JN-32-BLU"},
  {"case": "name+size only", "style": "Slim jeans", "size": "XL", "color": null,
   "prefix": "JN", "name": "Slim jeans · XL", "sku": "JN-XL"},
  {"case": "name+color only", "style": "Tote bag", "size": null, "color": "Black",
   "prefix": "BAG", "name": "Tote bag · Black", "sku": "BAG-BLA"},
  {"case": "name only", "style": "Silk scarf", "size": null, "color": null,
   "prefix": "SC", "name": "Silk scarf", "sku": "SC"},
  {"case": "whitespace trimming", "style": "  Slim jeans ", "size": " 3 2 ", "color": " Dark green ",
   "prefix": " jn ", "name": "Slim jeans · 3 2 · Dark green", "sku": "JN-32-DAR"},
  {"case": "empty strings behave as null", "style": "Slim jeans", "size": "", "color": "  ",
   "prefix": "JN", "name": "Slim jeans", "sku": "JN"},
  {"case": "ethiopic colour kept verbatim", "style": "ቲሸርት", "size": "M", "color": "ቀይ",
   "prefix": "TS", "name": "ቲሸርት · M · ቀይ", "sku": "TS-M-ቀይ"},
  {"case": "ethiopic colour with inner space", "style": "Tote bag", "size": null, "color": "ጥቁር ሰማያዊ",
   "prefix": "BAG", "name": "Tote bag · ጥቁር ሰማያዊ", "sku": "BAG-ጥቁርሰማያዊ"},
  {"case": "shoe size and lowercase colour", "style": "Runner", "size": "42", "color": "white",
   "prefix": "sh", "name": "Runner · 42 · white", "sku": "SH-42-WHI"},
  {"case": "null prefix gives no sku", "style": "Slim jeans", "size": "32", "color": "Blue",
   "prefix": null, "name": "Slim jeans · 32 · Blue", "sku": null},
  {"case": "blank prefix gives no sku", "style": "Slim jeans", "size": "32", "color": "Blue",
   "prefix": "   ", "name": "Slim jeans · 32 · Blue", "sku": null},
  {"case": "mixed colour not latin-only kept verbatim", "style": "Cap", "size": null, "color": "Red2",
   "prefix": "CP", "name": "Cap · Red2", "sku": "CP-Red2"}
]
''') as List)
    .cast<Map<String, dynamic>>();

/// Prefix-rewrite fixture, likewise verbatim from the backend test. Note the
/// two cases the mobile side used to get wrong: a SKU equal to the prefix, and
/// a cleared prefix (which drops the leading segment, or the whole SKU).
final prefixRewriteFixture = (jsonDecode('''
[
  {"case": "prefix swapped", "sku": "JN-32-BLU", "old": "JN", "new": "DN", "expected": "DN-32-BLU"},
  {"case": "prefix-only sku swapped", "sku": "JN", "old": "JN", "new": "DN", "expected": "DN"},
  {"case": "case-insensitive old prefix", "sku": "JN-XL", "old": "jn", "new": "dn", "expected": "DN-XL"},
  {"case": "hand-typed sku untouched", "sku": "CUSTOM-1", "old": "JN", "new": "DN", "expected": "CUSTOM-1"},
  {"case": "similar prefix not a match", "sku": "JNX-32", "old": "JN", "new": "DN", "expected": "JNX-32"},
  {"case": "null stays null", "sku": null, "old": "JN", "new": "DN", "expected": null},
  {"case": "no old prefix leaves sku alone", "sku": "32-BLU", "old": null, "new": "DN", "expected": "32-BLU"},
  {"case": "prefix removed drops the segment", "sku": "JN-32-BLU", "old": "JN", "new": null, "expected": "32-BLU"},
  {"case": "prefix removed from prefix-only sku", "sku": "JN", "old": "JN", "new": "", "expected": null}
]
''') as List)
    .cast<Map<String, dynamic>>();

void main() {
  group('backend parity fixture', () {
    for (final f in nameFixture) {
      test('name + sku — ${f['case']}', () {
        expect(
          composeVariantName(
            f['style'] as String,
            f['size'] as String?,
            f['color'] as String?,
          ),
          f['name'],
        );
        expect(
          composeSku(
            f['prefix'] as String?,
            f['size'] as String?,
            f['color'] as String?,
          ),
          f['sku'],
        );
      });
    }

    for (final f in prefixRewriteFixture) {
      test('rewriteSkuPrefix — ${f['case']}', () {
        expect(
          rewriteSkuPrefix(
            f['sku'] as String?,
            f['old'] as String?,
            f['new'] as String?,
          ),
          f['expected'],
        );
      });
    }

    test('the fixtures cover the cases both sides promise', () {
      expect(
        nameFixture.map((f) => f['case']),
        containsAll([
          'name+size+color',
          'whitespace trimming',
          'ethiopic colour kept verbatim',
          'null prefix gives no sku',
        ]),
      );
      expect(
        prefixRewriteFixture.map((f) => f['case']),
        containsAll([
          'prefix-only sku swapped',
          'prefix removed drops the segment',
          'prefix removed from prefix-only sku',
        ]),
      );
    });
  });

  group('composeVariantName', () {
    test('name + size + colour joins with " · "', () {
      expect(
        composeVariantName('Slim jeans', '32', 'Blue'),
        'Slim jeans · 32 · Blue',
      );
    });

    test('size only', () {
      expect(composeVariantName('Slim jeans', '32', null), 'Slim jeans · 32');
    });

    test('colour only', () {
      expect(composeVariantName('Tote', null, 'ቀይ'), 'Tote · ቀይ');
    });

    test('name only', () {
      expect(composeVariantName('Scarf', null, null), 'Scarf');
      expect(composeVariantName('Scarf', '', '  '), 'Scarf');
    });

    test('whitespace is trimmed from every part', () {
      expect(
        composeVariantName('  Slim jeans ', ' 32 ', ' Blue  '),
        'Slim jeans · 32 · Blue',
      );
    });
  });

  group('composeSku', () {
    test('Latin colour abbreviates to 3 upper-case letters', () {
      expect(composeSku('JN', '32', 'Blue'), 'JN-32-BLU');
      expect(composeSku('jn', 'xl', 'navy blue'), 'JN-XL-NAV');
    });

    test('size code strips whitespace and upper-cases', () {
      expect(composeSku('KD', '0–3 m', null), 'KD-0–3M');
      expect(composeSku('JN', ' XL ', null), 'JN-XL');
    });

    test('Ethiopic colour is kept verbatim', () {
      expect(composeSku('BAG', null, 'ቀይ'), 'BAG-ቀይ');
      expect(composeSku('BAG', null, 'ጥቁር ሰማያዊ'), 'BAG-ጥቁርሰማያዊ');
    });

    test('null or blank prefix means no SKU', () {
      expect(composeSku(null, '32', 'Blue'), isNull);
      expect(composeSku('  ', '32', 'Blue'), isNull);
    });

    test('prefix alone when there is neither size nor colour', () {
      expect(composeSku('SC', null, null), 'SC');
    });
  });

  group('resolveSkuCollisions', () {
    test('distinct cells keep their base codes', () {
      final skus = resolveSkuCollisions('JN', [
        (size: '32', color: 'Blue'),
        (size: '34', color: 'Blue'),
        (size: '32', color: 'Black'),
      ]);
      expect(skus, ['JN-32-BLU', 'JN-34-BLU', 'JN-32-BLA']);
    });

    test('collision widens the Latin colour code BLU → BLUE → …', () {
      final skus = resolveSkuCollisions('JN', [
        (size: '32', color: 'Blue'),
        (size: '32', color: 'Blush'),
        (size: '32', color: 'Bluebell'),
      ]);
      expect(skus, ['JN-32-BLU', 'JN-32-BLUS', 'JN-32-BLUE']);
    });

    test('falls back to a numeric suffix when the word runs out of letters',
        () {
      final skus = resolveSkuCollisions('JN', [
        (size: '32', color: 'Blue'),
        (size: '32', color: 'Blu'),
      ]);
      // "Blu" has only three letters, so widening cannot help → "2".
      expect(skus, ['JN-32-BLU', 'JN-32-BLU2']);
    });

    test('numeric suffix keeps counting past taken codes', () {
      final skus = resolveSkuCollisions(
        'JN',
        [(size: '32', color: 'Blu')],
        taken: {'JN-32-BLU', 'JN-32-BLU2'},
      );
      expect(skus, ['JN-32-BLU3']);
    });

    test('Ethiopic collisions go straight to the numeric suffix', () {
      final skus = resolveSkuCollisions('BAG', [
        (size: null, color: 'ቀይ'),
        (size: null, color: 'ቀ ይ'),
      ]);
      expect(skus, ['BAG-ቀይ', 'BAG-ቀይ2']);
    });

    test('null prefix yields all-null SKUs', () {
      final skus = resolveSkuCollisions(null, [
        (size: '32', color: 'Blue'),
        (size: '34', color: 'Blue'),
      ]);
      expect(skus, [null, null]);
    });
  });

  group('rewriteSkuPrefix', () {
    test('swaps the old head for the new one', () {
      expect(rewriteSkuPrefix('JN-32-BLU', 'JN', 'JEAN'), 'JEAN-32-BLU');
    });

    test('an unrelated or prefix-less SKU is left alone', () {
      expect(rewriteSkuPrefix('X-1', 'JN', 'JEAN'), 'X-1');
      expect(rewriteSkuPrefix('JN-32-BLU', null, 'JEAN'), 'JN-32-BLU');
    });

    test('clearing the prefix drops the head, or the whole SKU', () {
      // An empty new prefix reads as "replace the old prefix with nothing",
      // exactly as the server does, so a prefix-only SKU disappears.
      expect(rewriteSkuPrefix('JN-32-BLU', 'JN', '  '), '32-BLU');
      expect(rewriteSkuPrefix('JN', 'JN', ''), isNull);
    });
  });
}
