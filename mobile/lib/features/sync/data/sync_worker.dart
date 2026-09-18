import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/connectivity/connectivity_provider.dart';
import 'package:suuqii/core/device/device_id.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/sync/data/sync_reconciler.dart';

part 'sync_worker.g.dart';

@Riverpod(keepAlive: true)
SyncWorker syncWorker(SyncWorkerRef ref) => SyncWorker(
      db: ref.watch(appDatabaseProvider),
      dio: ref.watch(dioProvider),
      connectivity: ref.watch(connectivityProvider),
      deviceId: () => ref.read(deviceFingerprintProvider.future),
      reconciler: ref.watch(syncReconcilerProvider),
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

/// Drains the local sync_events queue, then pulls other devices' events.
/// Idempotent; safe to call concurrently.
class SyncWorker {
  SyncWorker({
    required this.db,
    required this.dio,
    required this.connectivity,
    required this.deviceId,
    this.reconciler,
  });

  final AppDatabase db;
  final Dio dio;
  final Connectivity connectivity;

  /// Applies remote events and undoes locally-discarded writes. Optional so
  /// push-only unit tests don't need the repository graph; in the app it is
  /// always provided.
  final SyncReconciler? reconciler;

  /// Stable per-install fingerprint; shared with [deviceFingerprintProvider].
  final Future<String> Function() deviceId;

  /// Retryable failures allowed per event before it is dead-lettered.
  static const int maxAttempts = 10;

  /// Safety cap per sync cycle; a shop with a deeper backlog finishes on the
  /// next kick rather than looping unbounded.
  static const int maxPullPages = 20;

  static const String _pullCursorKey = 'pull_cursor';

  bool _running = false;
  int _authFailures = 0;
  Completer<void>? _wake;

  /// Snapshot domains invalidated during the current kick; re-mirrored once
  /// at the end of the cycle instead of after every batch/page.
  final Set<SyncDomain> _staleDomains = {};

  static SyncFailureKind classifyFailure(int? statusCode) {
    if (statusCode == 401) return SyncFailureKind.authBroken;
    if (statusCode == null || statusCode >= 500 || statusCode == 429) {
      return SyncFailureKind.retryable;
    }
    return SyncFailureKind.permanent;
  }

  /// Drift resolves the engine from the current [Zone], and async
  /// continuations inherit zone values — so a `kick()` started inside
  /// `db.transaction` would keep running its queries on that still-open
  /// transaction and push rows the caller may still roll back. Repositories
  /// kick after their transaction returns; this is the guard that makes a
  /// missed one harmless (the next kick picks the work up anyway).
  bool get _insideTransaction =>
      Zone.current[#DatabaseConnectionUser] != null;

  Future<void> kick() async {
    if (_insideTransaction) return;
    if (_running) {
      // Interrupt an in-progress backoff / offline wait so new work is
      // picked up promptly instead of being ignored until the sleep ends.
      final wake = _wake;
      if (wake != null && !wake.isCompleted) wake.complete();
      return;
    }
    _running = true;
    _staleDomains.clear();
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
                await _reconcileDiscarded(ev);
              }
          }
        }
      }
      // Queue drained (or empty): replicate what other devices did since the
      // last cycle, then re-mirror every snapshot this cycle invalidated.
      await _pull();
      await _flushStaleDomains();
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
        await _reconcileDiscarded(ev);
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
    // conflict + integrity_error is the server's "a dependency hasn't synced
    // yet — retry later" signal (see backend SyncService.apply). It must stay
    // pending; every other conflict means the server kept a newer state and
    // this event must never be retried.
    final retryConflicts = <SyncEventRow>[];
    for (final ev in batch) {
      final r = byClientId[ev.clientEventId];
      if (r == null) continue;
      final status = r['status'] as String;
      final code = r['code'] as String?;
      switch (status) {
        case 'applied' || 'duplicate':
          await db.syncQueueDao.markSynced(ev.id);
        case 'conflict' when code == 'integrity_error':
          retryConflicts.add(ev);
        case 'conflict':
          await db.syncQueueDao.markConflict(ev.id, code, r['detail'] as String?);
          await _reconcileDiscarded(ev);
        case 'rejected':
          await db.syncQueueDao.markRejected(
            ev.id,
            code,
            r['detail'] as String?,
          );
          await _reconcileDiscarded(ev);
      }
    }
    if (retryConflicts.isNotEmpty) {
      // Same budget/backoff as transient failures: dependencies usually land
      // within a few cycles; events whose dependency never arrives (e.g. a
      // rejected product.create) dead-letter instead of looping forever.
      await _handleRetryable(retryConflicts, 'conflict: waiting for dependency');
    }
  }

  /// The server permanently refused [ev]; let the reconciler undo the
  /// optimistic local write and queue the affected snapshots for re-mirror.
  Future<void> _reconcileDiscarded(SyncEventRow ev) async {
    final rec = reconciler;
    if (rec == null) return;
    try {
      final payload = (jsonDecode(ev.payload) as Map).cast<String, dynamic>();
      _staleDomains.addAll(await rec.onLocalDiscarded(ev.op, payload));
    } catch (e) {
      debugPrint('sync discard reconcile failed for ${ev.op}: $e');
    }
  }

  /// Replicate other devices' events since the persisted cursor. Network
  /// errors are swallowed — the next kick retries from the same cursor. The
  /// cursor is advanced only after a page is fully applied, and appliers are
  /// idempotent, so a crash mid-page is safe.
  Future<void> _pull() async {
    final rec = reconciler;
    if (rec == null) return;
    try {
      var cursor = int.tryParse(
            await db.syncQueueDao.getMeta(_pullCursorKey) ?? '',
          ) ??
          0;
      for (var page = 0; page < maxPullPages; page++) {
        final response = await dio.get<Map<String, dynamic>>(
          '/v1/sync/pull',
          queryParameters: {'cursor': cursor, 'limit': 200},
        );
        final data = response.data;
        if (data == null) return;
        final events =
            (data['events'] as List<dynamic>).cast<Map<String, dynamic>>();
        for (final e in events) {
          final op = e['op'] as String;
          final payload = (e['payload'] as Map).cast<String, dynamic>();
          try {
            await rec.applyRemoteEvent(
              op: op,
              payload: payload,
              userId: e['user_id'] as String,
              occurredAt: DateTime.tryParse(
                    e['occurred_at'] as String? ?? '',
                  )?.toUtc() ??
                  DateTime.now().toUtc(),
            );
          } catch (err) {
            // One malformed event must not block the feed — its state still
            // converges via the snapshot refresh below.
            debugPrint('sync pull apply failed for $op: $err');
          }
          _staleDomains.addAll(SyncReconciler.domainsForOp(op, payload));
        }
        cursor = (data['next_cursor'] as num).toInt();
        await db.syncQueueDao.setMeta(_pullCursorKey, '$cursor');
        if (data['has_more'] != true) return;
      }
    } on DioException catch (e) {
      debugPrint('sync pull failed: ${e.response?.statusCode ?? e.message}');
    }
  }

  Future<void> _flushStaleDomains() async {
    final rec = reconciler;
    if (rec == null || _staleDomains.isEmpty) return;
    final domains = Set<SyncDomain>.from(_staleDomains);
    _staleDomains.clear();
    await rec.refreshDomains(domains);
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
