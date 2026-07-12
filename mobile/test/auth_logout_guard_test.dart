import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/secure_storage.dart';
import 'package:suuqii/features/auth/data/auth_local_data_source.dart';
import 'package:suuqii/features/auth/data/auth_remote_data_source.dart';
import 'package:suuqii/features/auth/data/auth_repository_impl.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/auth/presentation/providers.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';

class _FakeSecureStorage extends SecureStorage {
  String? refresh;

  @override
  Future<String?> readRefresh() async => refresh;

  @override
  Future<void> writeRefresh(String value) async {
    refresh = value;
  }

  @override
  Future<void> clearRefresh() async {
    refresh = null;
  }
}

/// Sync worker whose kick() never drains anything — models a device that
/// cannot reach the server while the user tries to log out.
class _StuckSyncWorker extends SyncWorker {
  _StuckSyncWorker(AppDatabase db)
      : super(
          db: db,
          dio: Dio(),
          connectivity: Connectivity(),
          deviceId: () async => 'test-device',
        );

  @override
  Future<void> kick() async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('logout with pending sync events throws unless forced', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final prefs = await SharedPreferences.getInstance();
    final repo = AuthRepository(
      remote: AuthRemoteDataSource(Dio()),
      local: AuthLocalDataSource(_FakeSecureStorage(), prefs),
      tokens: TokenStore(),
    );

    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        syncWorkerProvider.overrideWithValue(_StuckSyncWorker(db)),
        authRepositoryProvider.overrideWith((ref) async => repo),
      ],
    );
    addTearDown(container.dispose);

    // Unsynced local sale queued for push.
    await db.syncQueueDao.enqueue(op: 'sale.create', payload: {'id': 's1'});

    await container.read(authControllerProvider.future);
    final controller = container.read(authControllerProvider.notifier);

    await expectLater(
      controller.logout,
      throwsA(
        isA<PendingSyncException>()
            .having((e) => e.pendingCount, 'pendingCount', 1),
      ),
    );

    // The queue must survive a blocked logout.
    expect(await db.syncQueueDao.pendingCount(), 1);

    // Forced logout discards the queue and signs out.
    await controller.logout(force: true);
    expect(await db.syncQueueDao.pendingCount(), 0);
    expect(
      container.read(authControllerProvider).value,
      isA<Unauthenticated>(),
    );
  });

  test('logout with an empty queue clears data without prompting', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final prefs = await SharedPreferences.getInstance();
    final repo = AuthRepository(
      remote: AuthRemoteDataSource(Dio()),
      local: AuthLocalDataSource(_FakeSecureStorage(), prefs),
      tokens: TokenStore(),
    );

    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        syncWorkerProvider.overrideWithValue(_StuckSyncWorker(db)),
        authRepositoryProvider.overrideWith((ref) async => repo),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authControllerProvider.future);
    await container.read(authControllerProvider.notifier).logout();

    expect(
      container.read(authControllerProvider).value,
      isA<Unauthenticated>(),
    );
  });
}
