import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/shop_type/shop_features.dart';
import 'package:suuqii/core/shop_type/size_presets.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/domain/entities/shop_option.dart';

void main() {
  group('ShopFeatures.of', () {
    test('regular: expiry tracked, nothing else', () {
      final f = ShopFeatures.of('regular');
      expect(f.hasSupplies, isFalse);
      expect(f.hasProduction, isFalse);
      expect(f.hasHandovers, isFalse);
      expect(f.tracksExpiry, isTrue);
      expect(f.allowsOversell, isFalse);
      expect(f.hasVariants, isFalse);
      expect(f.hasLinePricing, isFalse);
      expect(f.hasReturns, isFalse);
      expect(f.locksUnit, isFalse);
      expect(f.spoilageLabelKey, ShopFeatures.spoilageLabelSpoilage);
    });

    test('bakery: supplies, production, handovers, oversell', () {
      final f = ShopFeatures.of('bakery');
      expect(f.hasSupplies, isTrue);
      expect(f.hasProduction, isTrue);
      expect(f.hasHandovers, isTrue);
      expect(f.tracksExpiry, isTrue);
      expect(f.allowsOversell, isTrue);
      expect(f.hasVariants, isFalse);
      expect(f.locksUnit, isFalse);
      expect(f.spoilageLabelKey, ShopFeatures.spoilageLabelSpoilage);
    });

    test('boutique: variants, line pricing, returns, locked unit, no expiry',
        () {
      final f = ShopFeatures.of('boutique');
      expect(f.hasSupplies, isFalse);
      expect(f.hasProduction, isFalse);
      expect(f.hasHandovers, isFalse);
      expect(f.tracksExpiry, isFalse);
      expect(f.allowsOversell, isFalse);
      expect(f.hasVariants, isTrue);
      expect(f.hasLinePricing, isTrue);
      expect(f.hasReturns, isTrue);
      expect(f.locksUnit, isTrue);
      expect(f.defaultUnit, 'piece');
      expect(f.spoilageLabelKey, ShopFeatures.spoilageLabelDamagedLost);
      expect(f.isDamagedLostWording, isTrue);
    });

    test('unknown type fails safe to regular', () {
      expect(ShopFeatures.of('pharmacy'), same(ShopFeatures.regular));
      expect(ShopFeatures.of(''), same(ShopFeatures.regular));
    });

    test('default unit is piece for every type', () {
      for (final type in ShopFeatures.knownTypes) {
        expect(ShopFeatures.of(type).defaultUnit, 'piece', reason: type);
      }
    });
  });

  group('features getters', () {
    test('Authenticated.features follows shopType; isBakery alias agrees', () {
      const boutique = Authenticated(
        userId: 'u',
        shopId: 's',
        role: 'owner',
        userName: 'U',
        shopName: 'S',
        accessToken: 't',
        shopType: 'boutique',
      );
      const bakery = Authenticated(
        userId: 'u',
        shopId: 's',
        role: 'owner',
        userName: 'U',
        shopName: 'S',
        accessToken: 't',
        shopType: 'bakery',
      );
      expect(boutique.features.hasVariants, isTrue);
      expect(boutique.isBakery, isFalse);
      expect(bakery.features.hasSupplies, isTrue);
      expect(bakery.isBakery, isTrue);
    });

    test('ShopOption.features parses shop_type from JSON', () {
      final shop = ShopOption.fromJson(const {
        'id': 's',
        'name': 'Bole Boutique',
        'shop_type': 'boutique',
        'role': 'owner',
        'is_active': true,
      });
      expect(shop.features.locksUnit, isTrue);
      expect(shop.isBakery, isFalse);
    });
  });

  group('size presets', () {
    test('letter run has 7 sizes and the keys match the wire values', () {
      expect(letterSizes.sizes, ['XS', 'S', 'M', 'L', 'XL', 'XXL', '3XL']);
      expect(
        sizePresets.map((p) => p.key),
        ['letter', 'numeric', 'waist', 'shoe_eu', 'kids_age', 'free', 'custom'],
      );
    });

    test('custom sizes parse, trim and de-duplicate', () {
      expect(parseCustomSizes('S, M ,L,,M\n 38;40'), ['S', 'M', 'L', '38', '40']);
    });

    test('orderSizes follows the preset run and appends extras', () {
      expect(
        orderSizes(['XL', 'S', 'Tall', 'M'], presetKey: 'letter'),
        ['S', 'M', 'XL', 'Tall'],
      );
      expect(orderSizes(['40', '38']), ['40', '38']);
    });
  });
}
