import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/connectivity/connectivity_provider.dart';
import 'package:suuqii/core/device/device_id.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/storage/app_database.dart';

part 'sync_worker.g.dart';

@Riverpod(keepAlive: true)
SyncWorker syncWorker(SyncWorkerRef ref) => SyncWorker(
      db: ref.watch(appDatabaseProvider),
      dio: ref.watch(dioProvider),
      connectivity: ref.watch(connectivityProvider),
      deviceId: () => ref.read(deviceFingerprintProvider.future),
    );

/// How a failed push should be handled.
enum SyncFailureKind {
  /// Transient (network error, 5xx, 429): bump attempts and back off.
  retryable,

  /// 401 after the interceptor already tried to refresh: auth is temporarily
  /// broken. Back off without burning the events' retry budget — never
  /// dead-letter sales because auth was down.
  authBroken,

  /// Other 4xx (400/403/404/409/422…): the server will never accept this
  /// request as-is. Dead-letter so the queue keeps draining.
  permanent,
}

/// Drains the local sync_events queue. Idempotent; safe to call concurrently.
class SyncWorker {
  SyncWorker({
    required this.db,
    required this.dio,
    required this.connectivity,
    required this.deviceId,
  });

  final AppDatabase db;
  final Dio dio;
  final Connectivity connectivity;

  /// Stable per-install fingerprint; shared with [deviceFingerprintProvider].
  final Future<String> Function() deviceId;

  /// Retryable failures allowed per event before it is dead-lettered.
  static const int maxAttempts = 10;

  bool _running = false;
  int _authFailures = 0;
  Completer<void>? _wake;

  static SyncFailureKind classifyFailure(int? statusCode) {
    if (statusCode == 401) return SyncFailureKind.authBroken;
    if (statusCode == null || statusCode >= 500 || statusCode == 429) {
      return SyncFailureKind.retryable;
    }
    return SyncFailureKind.permanent;
  }

  Future<void> kick() async {
    if (_running) {
      // Interrupt an in-progress backoff / offline wait so new work is
      // picked up promptly instead of being ignored until the sleep ends.
      final wake = _wake;
      if (wake != null && !wake.isCompleted) wake.complete();
      return;
    }
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
          final device = await deviceId();
          final response = await dio.post<Map<String, dynamic>>(
            '/v1/sync/push',
            data: {
              'device_id': device,
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
            // Unexpected non-error status; treat as transient.
            await _handleRetryable(batch, 'http ${response.statusCode}');
            continue;
          }
          _authFailures = 0;
          final results = (response.data!['results'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          await _applyResults(results, batch);
        } on DioException catch (e) {
          final status = e.response?.statusCode;
          switch (classifyFailure(status)) {
            case SyncFailureKind.authBroken:
              _authFailures = math.min(_authFailures + 1, 8);
              await _backoff(_authFailures);
            case SyncFailureKind.retryable:
              await _handleRetryable(
                batch,
                status == null ? (e.message ?? 'network') : 'http $status',
              );
            case SyncFailureKind.permanent:
              // Dead-letter and continue with the next pending events.
              final error = _describeRejection(e, status);
              for (final ev in batch) {
                await db.syncQueueDao.markFailed(ev.id, error);
              }
          }
        }
      }
    } finally {
      _running = false;
    }
  }

  /// Bump attempts; dead-letter events that exhausted [maxAttempts] and only
  /// back off when something retryable is left, so the queue keeps moving.
  Future<void> _handleRetryable(
    List<SyncEventRow> batch,
    String error,
  ) async {
    await db.syncQueueDao.bumpAttempts(batch.map((b) => b.id).toList(), error);
    var exhausted = 0;
    for (final ev in batch) {
      if (ev.attempts + 1 >= maxAttempts) {
        await db.syncQueueDao.markFailed(
          ev.id,
          'gave up after ${ev.attempts + 1} attempts: $error',
        );
        exhausted++;
      }
    }
    if (exhausted < batch.length) {
      await _backoff(batch.first.attempts + 1);
    }
  }

  String _describeRejection(DioException e, int? status) {
    final data = e.response?.data;
    if (data is Map && data['detail'] is String) {
      return 'http $status: ${data['detail']}';
    }
    return 'http $status';
  }

  Future<bool> _isOnline() async {
    final r = await connectivity.checkConnectivity();
    return !r.contains(ConnectivityResult.none);
  }

  Future<void> _waitForOnline() async {
    final wake = _wake = Completer<void>();
    try {
      await Future.any<void>([
        wake.future,
        connectivity.onConnectivityChanged
            .firstWhere((r) => !r.contains(ConnectivityResult.none)),
      ]);
    } finally {
      _wake = null;
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
    final wake = _wake = Completer<void>();
    try {
      await Future.any<void>([
        Future<void>.delayed(Duration(seconds: base + jitter)),
        wake.future,
      ]);
    } finally {
      _wake = null;
    }
  }
}
