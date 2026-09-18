import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the Afaan Oromo and Amharic experiences: every key in the English
/// template must have a real (non-empty, non-copied-metadata) value in each
/// translation, so no screen ever falls back to English mid-sentence. Run
/// from the package root (the default for `flutter test`).
void main() {
  Map<String, dynamic> readArb(String path) {
    // Strip a UTF-8 BOM if an editor added one.
    final raw = File(path).readAsStringSync().replaceFirst('﻿', '');
    return json.decode(raw) as Map<String, dynamic>;
  }

  Set<String> messageKeys(Map<String, dynamic> arb) =>
      arb.keys.where((k) => !k.startsWith('@')).toSet();

  for (final locale in ['om', 'am']) {
    test('every app_en.arb key has an app_$locale.arb translation', () {
      final en = readArb('assets/l10n/app_en.arb');
      final translated = readArb('assets/l10n/app_$locale.arb');

      final enKeys = messageKeys(en);
      final localeKeys = messageKeys(translated);

      final missing = enKeys.difference(localeKeys);
      expect(
        missing,
        isEmpty,
        reason: 'app_$locale.arb is missing translations for: '
            '${(missing.toList()..sort()).join(', ')}',
      );

      final orphans = localeKeys.difference(enKeys);
      expect(
        orphans,
        isEmpty,
        reason: 'app_$locale.arb has keys absent from the template: '
            '${(orphans.toList()..sort()).join(', ')}',
      );

      final empty = localeKeys
          .where(
            (k) =>
                translated[k] is! String ||
                (translated[k] as String).trim().isEmpty,
          )
          .toList()
        ..sort();
      expect(
        empty,
        isEmpty,
        reason: 'app_$locale.arb has empty values for: ${empty.join(', ')}',
      );

      // Every placeholder the template declares must survive translation —
      // a dropped {amount} or {name} silently produces broken sentences at
      // runtime. Checking for '{placeholder' (no closing brace) also accepts
      // ICU plural/select syntax like '{count, plural, …}'.
      final placeholderMisses = <String>[];
      for (final key in enKeys) {
        final meta = en['@$key'];
        if (meta is! Map<String, dynamic>) continue;
        final placeholders = meta['placeholders'];
        if (placeholders is! Map<String, dynamic>) continue;
        final value = translated[key];
        if (value is! String) continue;
        for (final name in placeholders.keys) {
          if (!value.contains('{$name')) {
            placeholderMisses.add('$key is missing {$name}');
          }
        }
      }
      expect(
        placeholderMisses,
        isEmpty,
        reason: 'app_$locale.arb drops placeholders: '
            '${placeholderMisses.join('; ')}',
      );
    });
  }

  // Keys whose value is legitimately locale-neutral (brand name, bare
  // placeholder compositions, language names shown in their own script).
  // A new key landing here unreviewed is usually an untranslated stub —
  // add it to this list only after confirming it needs no translation.
  const localeNeutralKeys = {
    'appTitle',
    'settingsProfileSubtitle',
    'settingsLanguageEnglish',
    'settingsLanguageOromo',
    'settingsLanguageAmharic',
    'suppliesTileSubtitleNoCost',
    'reportRank',
    'registerPhoneHint',
    'posQtyUnit',
    'posQtyTimes',
    'cartMinusAmount',
    'cartPricePerUnit',
    'receiptQtyUnitPrice',
    'receiptSaleNumber',
    'receiptShareLine',
    'saleDetailQtyPrice',
    // Bare placeholder compositions on receipts and return rows.
    'receiptShareLineWas',
    'receiptShareReturnLine',
    'saleDetailReturnLine',
    // "{stock} · ×{inCart}" — bare placeholder composition on a size chip.
    'variantChipStockInCart',
  };

  test('every translatable app_am.arb value is actually written in Ethiopic',
      () {
    final en = readArb('assets/l10n/app_en.arb');
    final am = readArb('assets/l10n/app_am.arb');
    final ethiopic = RegExp('[ሀ-፿]');

    final untranslated = messageKeys(am)
        .where((k) => !localeNeutralKeys.contains(k))
        .where((k) => am[k] is String && !ethiopic.hasMatch(am[k] as String))
        .toList()
      ..sort();
    // If a key is genuinely locale-neutral, add it to localeNeutralKeys;
    // otherwise it shipped as an English stub.
    expect(
      untranslated,
      isEmpty,
      reason: 'app_am.arb values with no Ethiopic script: '
          '${untranslated.join(', ')}',
    );
    final staleNeutral =
        localeNeutralKeys.difference(messageKeys(en)).toList()..sort();
    expect(
      staleNeutral,
      isEmpty,
      reason: 'localeNeutralKeys lists removed keys: ${staleNeutral.join(', ')}',
    );
  });
}
