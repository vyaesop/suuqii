import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suuqii/features/auth/presentation/providers.dart';
import 'package:suuqii/features/settings/presentation/controllers/theme_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> makeContainer() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // Let the async prefs provider resolve so build() sees the instance.
    await container.read(sharedPrefsProvider.future);
    return container;
  }

  test('defaults to system when nothing is persisted', () async {
    SharedPreferences.setMockInitialValues({});
    final container = await makeContainer();
    expect(container.read(themeModeControllerProvider), ThemeMode.system);
  });

  test('setMode persists the choice and updates state', () async {
    SharedPreferences.setMockInitialValues({});
    final container = await makeContainer();

    await container
        .read(themeModeControllerProvider.notifier)
        .setMode(ThemeMode.dark);

    expect(container.read(themeModeControllerProvider), ThemeMode.dark);
    final prefs = await container.read(sharedPrefsProvider.future);
    expect(prefs.getString(themeModePrefKey), 'dark');
  });

  test('persisted choice survives a restart (new container)', () async {
    SharedPreferences.setMockInitialValues({themeModePrefKey: 'light'});
    final container = await makeContainer();
    expect(container.read(themeModeControllerProvider), ThemeMode.light);
  });

  test('choosing system clears the persisted key', () async {
    SharedPreferences.setMockInitialValues({themeModePrefKey: 'dark'});
    final container = await makeContainer();
    expect(container.read(themeModeControllerProvider), ThemeMode.dark);

    await container
        .read(themeModeControllerProvider.notifier)
        .setMode(ThemeMode.system);

    expect(container.read(themeModeControllerProvider), ThemeMode.system);
    final prefs = await container.read(sharedPrefsProvider.future);
    expect(prefs.getString(themeModePrefKey), isNull);
  });
}
