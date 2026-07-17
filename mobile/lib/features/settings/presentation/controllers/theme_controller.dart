import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/features/auth/presentation/providers.dart';

/// SharedPreferences key holding the user's explicit theme choice
/// ('light' | 'dark'). Absent → follow the system brightness.
const String themeModePrefKey = 'app_theme_mode';

/// The user's explicit theme, defaulting to [ThemeMode.system].
///
/// Watched by the app root (MaterialApp.themeMode) and set from the Settings
/// screen. Mirrors the persistence pattern of the locale controller.
final themeModeControllerProvider =
    NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    // main.dart overrides sharedPrefsProvider with an already-loaded
    // instance, so this is available synchronously on first build (no
    // theme flash at startup).
    final prefs = ref.watch(sharedPrefsProvider).valueOrNull;
    return switch (prefs?.getString(themeModePrefKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  /// Persist and apply an explicit theme, or [ThemeMode.system] to follow
  /// the device setting.
  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    final prefs = await ref.read(sharedPrefsProvider.future);
    if (mode == ThemeMode.system) {
      await prefs.remove(themeModePrefKey);
    } else {
      await prefs.setString(themeModePrefKey, mode.name);
    }
  }
}
