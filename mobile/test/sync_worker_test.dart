import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';

class _FakeConnectivity extends Fake implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

/// Fake Dio whose [handler] decides, per call, to return a response or throw.
class _FakeDio extends Fake implements Dio {
  _FakeDio(this.handler);

  final Future<Response<Map<String, dynamic>>> Function(
    int call,
    Object? data,
  ) handler;
  int calls = 0;

  @override
  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    calls++;
    return await handler(calls, data) as Response<T>;
  }
}

DioException _httpError(int status, {Object? body}) {
  final req = RequestOptions(path: '/v1/sync/push');
  return DioException(
    requestOptions: req,
    response: Response<dynamic>(
      requestOptions: req,
      statusCode: status,
      data: body,
    ),
    type: DioExceptionType.badResponse,
  );
}

Response<Map<String, dynamic>> _appliedResponse(Object? data) {
  final events =
      ((data! as Map<String, dynamic>)['events'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
  return Response<Map<String, dynamic>>(
    requestOptions: RequestOptions(path: '/v1/sync/push'),
    statusCode: 200,
    data: {
      'results': [
        for (final e in events)
          {'client_event_id': e['client_event_id'], 'status': 'applied'},
      ],
    },
  );
}

void main() {
  group('classifyFailure', () {
    test('network errors and 5xx/429 are retryable', () {
      expect(SyncWorker.classifyFailure(null), SyncFailureKind.retryable);
      expect(SyncWorker.classifyFailure(500), SyncFailureKind.retryable);
      expect(SyncWorker.classifyFailure(503), SyncFailureKind.retryable);
      expect(SyncWorker.classifyFailure(429), SyncFailureKind.retryable);
    });

    test('401 means auth is broken, never dead-letter', () {
      expect(SyncWorker.classifyFailure(401), SyncFailureKind.authBroken);
    });

    test('other 4xx are permanent', () {
      for (final status in [400, 403, 404, 409, 422]) {
        expect(
          SyncWorker.classifyFailure(status),
          SyncFailureKind.permanent,
          reason: 'http $status',
        );
      }
    });
  });

  group('kick', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    SyncWorker worker(Dio dio) => SyncWorker(
          db: db,
          dio: dio,
          connectivity: _FakeConnectivity(),
          deviceId: () async => 'test-device',
        );

    test('permanent 4xx dead-letters events and terminates', () async {
      await db.syncQueueDao.enqueue(op: 'sale.create', payload: {'id': 's1'});
      await db.syncQueueDao.enqueue(op: 'sale.create', payload: {'id': 's2'});

      final dio = _FakeDio(
        (call, data) => throw _httpError(422, body: {'detail': 'bad payload'}),
      );
      await worker(dio).kick().timeout(const Duration(seconds: 5));

      // Only one push: the batch is dead-lettered, not retried forever.
      expect(dio.calls, 1);
      expect(await db.syncQueueDao.pendingCount(), 0);
      final rows = await db.select(db.syncEventsTable).get();
      for (final row in rows) {
        expect(row.status, 'failed');
        expect(row.lastError, contains('http 422'));
        expect(row.lastError, contains('bad payload'));
      }
    });

    test('retryable failure dead-letters after max attempts', () async {
      await db.syncQueueDao.enqueue(op: 'sale.create', payload: {'id': 's1'});
      // One attempt away from the cap.
      await db.customStatement(
        'UPDATE sync_events SET attempts = ${SyncWorker.maxAttempts - 1}',
      );

      final dio = _FakeDio((call, data) => throw _httpError(503));
      await worker(dio).kick().timeout(const Duration(seconds: 5));

      expect(dio.calls, 1);
      final row = await db.select(db.syncEventsTable).getSingle();
      expect(row.status, 'failed');
      expect(row.lastError, contains('gave up after'));
    });

    test('401 backs off without burning retry budget, then succeeds',
        () async {
      await db.syncQueueDao.enqueue(op: 'sale.create', payload: {'id': 's1'});

      final dio = _FakeDio((call, data) async {
        if (call == 1) throw _httpError(401);
        return _appliedResponse(data);
      });
      final w = worker(dio);
      // Wake the backoff shortly after it starts so the test stays fast.
      unawaited(Future<void>.delayed(const Duration(milliseconds: 200), w.kick));
      await w.kick().timeout(const Duration(seconds: 10));

      expect(dio.calls, 2);
      final row = await db.select(db.syncEventsTable).getSingle();
      expect(row.status, 'synced');
      // 401 must not consume the event's retry budget.
      expect(row.attempts, 0);
    });

    test('successful push marks events synced', () async {
      await db.syncQueueDao.enqueue(op: 'product.create', payload: {'id': 'p'});

      final dio = _FakeDio((call, data) async => _appliedResponse(data));
      await worker(dio).kick().timeout(const Duration(seconds: 5));

      final row = await db.select(db.syncEventsTable).getSingle();
      expect(row.status, 'synced');
    });
  });
}
