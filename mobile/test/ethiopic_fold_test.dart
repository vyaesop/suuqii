import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/utils/ethiopic.dart';

void main() {
  group('foldForSearch', () {
    test('folds ሠ-series to ሰ-series (soap: ሣሙና finds ሳሙና)', () {
      expect(foldForSearch('ሣሙና'), foldForSearch('ሳሙና'));
      expect(matchesSearch('ሳሙና ትልቅ', 'ሣሙና'), isTrue);
    });

    test('folds ሐ/ኀ/ሃ-series to ሀ-series (milk: ሐሊብ finds ሃሊብ/ሀሊብ)', () {
      expect(foldForSearch('ሐሊብ'), foldForSearch('ሃሊብ'));
      expect(foldForSearch('ኃይል'), foldForSearch('ሀይል'));
      expect(foldForSearch('ኅብስት'), foldForSearch('ህብስት'));
    });

    test('folds ዐ-series to አ-series (ዓለም finds አለም)', () {
      expect(foldForSearch('ዓለም'), foldForSearch('አለም'));
      expect(foldForSearch('ዕቃ'), foldForSearch('እቃ'));
    });

    test('folds ፀ-series to ጸ-series (ፀጉር finds ጸጉር)', () {
      expect(foldForSearch('ፀጉር'), foldForSearch('ጸጉር'));
      expect(foldForSearch('ፅዳት'), foldForSearch('ጽዳት'));
    });

    test('folds ዉ to ው (ነዉ finds ነው)', () {
      expect(foldForSearch('ነዉ'), foldForSearch('ነው'));
    });

    test('folds labialized variants (ሧ→ሷ, ሗ→ኋ)', () {
      expect(foldForSearch('ሧ'), foldForSearch('ሷ'));
      expect(foldForSearch('ሗላ'), foldForSearch('ኋላ'));
    });

    test('keeps genuinely different letters apart', () {
      expect(foldForSearch('ሱቅ'), isNot(foldForSearch('ስቅ')));
      expect(foldForSearch('ዳቦ'), isNot(foldForSearch('ደቦ')));
      expect(matchesSearch('ሽንኩርት', 'ስኳር'), isFalse);
    });

    test('Latin stays case-insensitive (previous SQL LIKE behavior)', () {
      expect(matchesSearch('Coca Cola 500ml', 'coca'), isTrue);
      expect(matchesSearch('pasta', 'PAS'), isTrue);
      expect(matchesSearch('pasta', 'rice'), isFalse);
    });

    test('Ethiopic wordspace ፡ matches a regular space', () {
      expect(matchesSearch('ቀይ፡ሽንኩርት', 'ቀይ ሽንኩርት'), isTrue);
    });

    test('mixed-script names fold both parts', () {
      expect(matchesSearch('ሳሙና Lux 100g', 'ሣሙና lux'), isTrue);
    });
  });
}
