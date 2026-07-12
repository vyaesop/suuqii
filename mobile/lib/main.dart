import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:suuqii/app/app.dart';
import 'package:suuqii/core/env/env.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/auth/presentation/providers.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dir = await getApplicationDocumentsDirectory();
  final dbFile = p.join(dir.path, 'suuqii.sqlite');
  final db = AppDatabase.openOn(dbFile);

  // Load prefs before the first frame so the persisted app locale applies
  // synchronously (no flash of the wrong language at startup).
  final prefs = await SharedPreferences.getInstance();

  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      sharedPrefsProvider.overrideWith((ref) => prefs),
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

  if (Env.sentryDsn.isNotEmpty) {
    await SentryFlutter.init(
      (o) => o.dsn = Env.sentryDsn,
      appRunner: () => _runApp(container),
    );
  } else {
    _runApp(container);
  }
}

void _runApp(ProviderContainer container) {
  runApp(UncontrolledProviderScope(
      container: container, child: const SuuqiiApp(),),);
}
