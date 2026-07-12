import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the Afaan Oromo experience: every key in the English template must
/// have a real (non-empty, non-copied-metadata) value in app_om.arb, so no
/// screen ever falls back to English mid-sentence. Run from the package root
/// (the default for `flutter test`).
void main() {
  Map<String, dynamic> readArb(String path) {
    // Strip a UTF-8 BOM if an editor added one.
    final raw = File(path).readAsStringSync().replaceFirst('﻿', '');
    return json.decode(raw) as Map<String, dynamic>;
  }

  Set<String> messageKeys(Map<String, dynamic> arb) =>
      arb.keys.where((k) => !k.startsWith('@')).toSet();

  test('every app_en.arb key has an app_om.arb translation', () {
    final en = readArb('assets/l10n/app_en.arb');
    final om = readArb('assets/l10n/app_om.arb');

    final enKeys = messageKeys(en);
    final omKeys = messageKeys(om);

    final missing = enKeys.difference(omKeys);
    expect(
      missing,
      isEmpty,
      reason: 'app_om.arb is missing translations for: '
          '${(missing.toList()..sort()).join(', ')}',
    );

    final orphans = omKeys.difference(enKeys);
    expect(
      orphans,
      isEmpty,
      reason: 'app_om.arb has keys absent from the template: '
          '${(orphans.toList()..sort()).join(', ')}',
    );

    final empty = omKeys
        .where((k) => om[k] is! String || (om[k] as String).trim().isEmpty)
        .toList()
      ..sort();
    expect(
      empty,
      isEmpty,
      reason: 'app_om.arb has empty values for: ${empty.join(', ')}',
    );
  });
}
