import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/features/auth/presentation/providers.dart';

/// SharedPreferences key holding the user's explicit language choice
/// ('en' | 'om'). Absent → follow the device locale (resolving to English
/// when the device language isn't supported, since `en` is listed first in
/// supportedLocales).
const String localePrefKey = 'app_locale';

/// The user's explicit UI language, or null to follow the system locale.
///
/// Watched by the app root (MaterialApp.locale) and set from the Settings
/// screen. The device-level choice wins for UI language; the shop locale sent
/// at registration only seeds the server side.
final localeControllerProvider =
    NotifierProvider<LocaleController, Locale?>(LocaleController.new);

class LocaleController extends Notifier<Locale?> {
  @override
  Locale? build() {
    // main.dart overrides sharedPrefsProvider with an already-loaded
    // instance, so this is available synchronously on first build (no
    // locale flash at startup).
    final prefs = ref.watch(sharedPrefsProvider).valueOrNull;
    final tag = prefs?.getString(localePrefKey);
    return (tag == null || tag.isEmpty) ? null : Locale(tag);
  }

  /// Persist and apply an explicit language, or null to follow the system.
  Future<void> setLocale(Locale? locale) async {
    state = locale;
    final prefs = await ref.read(sharedPrefsProvider.future);
    if (locale == null) {
      await prefs.remove(localePrefKey);
    } else {
      await prefs.setString(localePrefKey, locale.languageCode);
    }
  }
}
