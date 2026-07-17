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
    });
  }
}
