import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/connectivity/connectivity_provider.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/secure_storage.dart';
import 'package:uuid/uuid.dart';

part 'sync_worker.g.dart';

@Riverpod(keepAlive: true)
SyncWorker syncWorker(SyncWorkerRef ref) => SyncWorker(
      db: ref.watch(appDatabaseProvider),
      dio: ref.watch(dioProvider),
      connectivity: ref.watch(connectivityProvider),
      secureStorage: ref.watch(secureStorageProvider),
    );

/// Drains the local sync_events queue. Idempotent; safe to call concurrently.
class SyncWorker {
  SyncWorker({
    required this.db,
    required this.dio,
    required this.connectivity,
    required this.secureStorage,
  });

  final AppDatabase db;
  final Dio dio;
  final Connectivity connectivity;
  final SecureStorage secureStorage;

  bool _running = false;

  Future<void> kick() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        if (!await _isOnline()) {
          await _waitForOnline();
          continue;
        }
        final batch = await db.syncQueueDao.takePending();
        if (batch.isEmpty) break;

        try {
          final deviceId = await _deviceId();
          final response = await dio.post<Map<String, dynamic>>(
            '/v1/sync/push',
            data: {
              'device_id': deviceId,
              'events': batch
                  .map(
                    (e) => {
                      'client_event_id': e.clientEventId,
                      'op': e.op,
                      'occurred_at': e.occurredAt.toIso8601String(),
                      'payload': jsonDecode(e.payload),
                    },
                  )
                  .toList(),
            },
          );
          if (response.statusCode != 200) {
            await db.syncQueueDao.bumpAttempts(
              batch.map((b) => b.id).toList(),
              'http ${response.statusCode}',
            );
            await _backoff(batch.first.attempts + 1);
            continue;
          }
          final results = (response.data!['results'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          await _applyResults(results, batch);
        } on DioException catch (e) {
          await db.syncQueueDao.bumpAttempts(
            batch.map((b) => b.id).toList(),
            e.message ?? 'network',
          );
          await _backoff(batch.first.attempts + 1);
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<bool> _isOnline() async {
    final r = await connectivity.checkConnectivity();
    return !r.contains(ConnectivityResult.none);
  }

  Future<void> _waitForOnline() async {
    await for (final r in connectivity.onConnectivityChanged) {
      if (!r.contains(ConnectivityResult.none)) return;
    }
  }

  Future<void> _applyResults(
    List<Map<String, dynamic>> results,
    List<SyncEventRow> batch,
  ) async {
    final byClientId = {
      for (final r in results) r['client_event_id'] as String: r,
    };
    for (final ev in batch) {
      final r = byClientId[ev.clientEventId];
      if (r == null) continue;
      final status = r['status'] as String;
      if (status == 'applied' ||
          status == 'duplicate' ||
          status == 'conflict') {
        await db.syncQueueDao.markSynced(ev.id);
      } else if (status == 'rejected') {
        await db.syncQueueDao.markRejected(
          ev.id,
          r['code'] as String?,
          r['detail'] as String?,
        );
      }
    }
  }

  Future<void> _backoff(int attempts) async {
    final base = math.min(math.pow(2, attempts).toInt(), 300);
    final jitter = math.Random().nextInt(base);
    await Future<void>.delayed(Duration(seconds: base + jitter));
  }

  Future<String> _deviceId() async {
    final existing = await secureStorage.readDeviceFingerprint();
    if (existing != null && existing.isNotEmpty) return existing;
    final fp = const Uuid().v4();
    await secureStorage.writeDeviceFingerprint(fp);
    return fp;
  }
}
