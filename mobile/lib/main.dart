import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:suuqii/app/app.dart';
import 'package:suuqii/core/env/app_version.dart';
import 'package:suuqii/core/env/env.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/auth/presentation/providers.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Sentry must come up before the DB is opened and the container is built,
  // so crashes during startup (failed migration, corrupt DB file, provider
  // construction) are captured too. No-op when the DSN is empty.
  if (Env.sentryDsn.isNotEmpty) {
    await SentryFlutter.init(
      (o) => o.dsn = Env.sentryDsn,
      appRunner: _bootstrap,
    );
  } else {
    await _bootstrap();
  }
}

Future<void> _bootstrap() async {
  final dir = await getApplicationDocumentsDirectory();
  final dbFile = p.join(dir.path, 'suuqii.sqlite');
  final db = AppDatabase.openOn(dbFile);

  // Load prefs before the first frame so the persisted app locale applies
  // synchronously (no flash of the wrong language at startup).
  final prefs = await SharedPreferences.getInstance();

  // Resolve the app version before the container exists so every API request
  // carries X-App-Version from the very first call (no async race).
  final packageInfo = await PackageInfo.fromPlatform();

  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      sharedPrefsProvider.overrideWith((ref) => prefs),
      appVersionProvider.overrideWithValue(packageInfo.version),
    ],
  );

  // Kick the sync worker whenever auth transitions to Authenticated.
  container.listen<AsyncValue<AuthState>>(
    authControllerProvider,
    (prev, next) {
      if (next.value is Authenticated) {
        container.read(syncWorkerProvider).kick();
      }
    },
    fireImmediately: true,
  );

  runApp(UncontrolledProviderScope(
      container: container, child: const SuuqiiApp(),),);
}
