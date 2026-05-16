import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app/app.dart';
import 'core/env/env.dart';
import 'core/storage/app_database.dart';
import 'features/auth/domain/entities/auth_state.dart';
import 'features/auth/presentation/controllers/auth_controller.dart';
import 'features/sync/data/sync_worker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dir = await getApplicationDocumentsDirectory();
  final dbFile = p.join(dir.path, 'suuqii.sqlite');
  final db = AppDatabase.openOn(dbFile);

  final container = ProviderContainer(overrides: [
    appDatabaseProvider.overrideWithValue(db),
  ]);

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
  runApp(UncontrolledProviderScope(container: container, child: const SuuqiiApp()));
}
