import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sync/data/sync_reconciler.dart';
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
/// [pullHandler] serves GET /v1/sync/pull; defaults to an empty feed.
class _FakeDio extends Fake implements Dio {
  _FakeDio(this.handler, {this.pullHandler});

  final Future<Response<Map<String, dynamic>>> Function(
    int call,
    Object? data,
  ) handler;
  final Map<String, dynamic> Function(int call, Map<String, dynamic>? query)?
      pullHandler;
  int calls = 0;
  int pullCalls = 0;

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

  @override
  Future<Response<T>> get<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onReceiveProgress,
  }) async {
    pullCalls++;
    final body = pullHandler?.call(pullCalls, queryParameters) ??
        {'events': <Object>[], 'next_cursor': 0, 'has_more': false};
    return Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: body,
    ) as Response<T>;
  }
}

/// Reconciler over the real in-memory DB with recorded snapshot refreshes.
SyncReconciler _reconciler(AppDatabase db, List<SyncDomain> refreshed) {
  Future<void> Function() record(SyncDomain d) =>
      () async => refreshed.add(d);
  return SyncReconciler(
    db: db,
    shopId: () => 'shop-1',
    refreshProducts: record(SyncDomain.products),
    refreshLots: record(SyncDomain.lots),
    refreshDebts: record(SyncDomain.debts),
    refreshExpenses: record(SyncDomain.expenses),
    refreshSupplies: record(SyncDomain.supplies),
    refreshStyles: record(SyncDomain.styles),
  );
}

Response<Map<String, dynamic>> _resultsResponse(
  Object? data,
  Map<String, dynamic> Function(Map<String, dynamic> event) result,
) {
  final events = ((data! as Map<String, dynamic>)['events'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  return Response<Map<String, dynamic>>(
    requestOptions: RequestOptions(path: '/v1/sync/push'),
    statusCode: 200,
    data: {'results': [for (final e in events) result(e)]},
  );
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

    test('a kick started inside a transaction does nothing', () async {
      await db.syncQueueDao.enqueue(op: 'sale.create', payload: {'id': 's1'});
      final dio = _FakeDio((call, data) async => _appliedResponse(data));
      final w = worker(dio);

      await db.transaction(() async {
        // Drift resolves the engine from the zone, so a push started here
        // would run on the open transaction and could send rows the caller
        // still rolls back.
        await w.kick().timeout(const Duration(seconds: 5));
      });
      expect(dio.calls, 0);
      expect(await db.syncQueueDao.pendingCount(), 1);

      // Outside the transaction the very same worker drains normally.
      await w.kick().timeout(const Duration(seconds: 5));
      expect(dio.calls, 1);
      expect(await db.syncQueueDao.pendingCount(), 0);
    });

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

  group('conflict handling', () {
    late AppDatabase db;
    late List<SyncDomain> refreshed;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      refreshed = [];
    });

    tearDown(() async {
      await db.close();
    });

    SyncWorker worker(Dio dio) => SyncWorker(
          db: db,
          dio: dio,
          connectivity: _FakeConnectivity(),
          deviceId: () async => 'test-device',
          reconciler: _reconciler(db, refreshed),
        );

    test(
        'integrity_error conflict stays pending and is retried, '
        'never dropped as synced', () async {
      await db.syncQueueDao.enqueue(op: 'sale.create', payload: {'id': 's1'});

      final dio = _FakeDio((call, data) async {
        if (call == 1) {
          // Server: referenced entity hasn't synced yet — retry later.
          return _resultsResponse(
            data,
            (e) => {
              'client_event_id': e['client_event_id'],
              'status': 'conflict',
              'code': 'integrity_error',
              'detail': 'fk violation',
            },
          );
        }
        return _appliedResponse(data);
      });
      final w = worker(dio);
      // Wake the backoff shortly after it starts so the test stays fast.
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 200), w.kick),
      );
      await w.kick().timeout(const Duration(seconds: 10));

      expect(dio.calls, 2);
      final row = await db.select(db.syncEventsTable).getSingle();
      expect(row.status, 'synced');
      // The failed attempt consumed retry budget so a dependency that never
      // arrives dead-letters eventually instead of looping forever.
      expect(row.attempts, 1);
    });

    test('integrity_error conflict dead-letters after max attempts', () async {
      await db.syncQueueDao.enqueue(op: 'sale.create', payload: {'id': 's1'});
      await db.customStatement(
        'UPDATE sync_events SET attempts = ${SyncWorker.maxAttempts - 1}',
      );

      final dio = _FakeDio(
        (call, data) async => _resultsResponse(
          data,
          (e) => {
            'client_event_id': e['client_event_id'],
            'status': 'conflict',
            'code': 'integrity_error',
          },
        ),
      );
      await worker(dio).kick().timeout(const Duration(seconds: 5));

      expect(dio.calls, 1);
      final row = await db.select(db.syncEventsTable).getSingle();
      expect(row.status, 'failed');
      expect(row.lastError, contains('gave up after'));
    });

    test('server-wins conflict marks event conflict and re-mirrors snapshots',
        () async {
      await db.syncQueueDao.enqueue(
        op: 'product.update',
        payload: {'id': 'p1', 'name': 'stale edit'},
      );

      final dio = _FakeDio(
        (call, data) async => _resultsResponse(
          data,
          (e) => {
            'client_event_id': e['client_event_id'],
            'status': 'conflict',
            'code': 'conflict',
            'detail': 'newer server version exists',
          },
        ),
      );
      await worker(dio).kick().timeout(const Duration(seconds: 5));

      // Never retried, but never silently "synced" either.
      expect(dio.calls, 1);
      final row = await db.select(db.syncEventsTable).getSingle();
      expect(row.status, 'conflict');
      expect(row.lastError, contains('newer server version'));
      expect(await db.syncQueueDao.pendingCount(), 0);
      // Local row returns to server truth via the snapshot re-mirror.
      expect(refreshed, contains(SyncDomain.products));
    });

    test('rejected product.create soft-deletes the local ghost row', () async {
      await db.productsDao.upsertAll([
        Product(
          id: 'p1',
          shopId: 'shop-1',
          name: 'Ghost',
          purchasePrice: Decimal.parse('10'),
          sellingPrice: Decimal.parse('15'),
          stock: Decimal.parse('5'),
          lowStockThreshold: Decimal.one,
          unit: 'piece',
        ),
      ]);
      await db.syncQueueDao.enqueue(
        op: 'product.create',
        payload: {'id': 'p1', 'name': 'Ghost'},
      );

      final dio = _FakeDio(
        (call, data) async => _resultsResponse(
          data,
          (e) => {
            'client_event_id': e['client_event_id'],
            'status': 'rejected',
            'code': 'owner_pin_required',
          },
        ),
      );
      await worker(dio).kick().timeout(const Duration(seconds: 5));

      final row = await db.select(db.syncEventsTable).getSingle();
      expect(row.status, 'rejected');
      // The product never existed server-side; it must stop being sellable.
      final product = await (db.select(db.productsTable)
            ..where((t) => t.id.equals('p1')))
          .getSingle();
      expect(product.deletedAt, isNotNull);
    });
  });

  group('pull', () {
    late AppDatabase db;
    late List<SyncDomain> refreshed;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      refreshed = [];
    });

    tearDown(() async {
      await db.close();
    });

    SyncWorker worker(Dio dio) => SyncWorker(
          db: db,
          dio: dio,
          connectivity: _FakeConnectivity(),
          deviceId: () async => 'test-device',
          reconciler: _reconciler(db, refreshed),
        );

    Map<String, dynamic> saleEvent() => {
          'server_id': 7,
          'op': 'sale.create',
          'user_id': 'user-2',
          'occurred_at': '2026-07-17T09:00:00Z',
          'applied_at': '2026-07-17T09:00:05Z',
          'payload': {
            'id': 'sale-remote-1',
            'shift_id': null,
            'subtotal': '70.00',
            'discount': '0',
            'total': '70.00',
            'cost_total': '40.00',
            'payment_method': 'cash',
            'occurred_at': '2026-07-17T09:00:00Z',
            'items': [
              {
                'id': 'item-1',
                'product_id': 'p1',
                'product_name_snapshot': 'Sugar 1kg',
                'quantity': '2',
                'unit_price': '35.00',
                'unit_cost': '20.00',
              },
            ],
          },
        };

    test("replicates another device's sale and persists the cursor",
        () async {
      final dio = _FakeDio(
        (call, data) async => _appliedResponse(data),
        pullHandler: (call, query) => {
          'events': [saleEvent()],
          'next_cursor': 7,
          'has_more': false,
        },
      );
      await worker(dio).kick().timeout(const Duration(seconds: 5));

      final sale = await (db.select(db.salesTable)
            ..where((t) => t.id.equals('sale-remote-1')))
          .getSingle();
      expect(sale.userId, 'user-2');
      expect(sale.total, 7000); // santim
      expect(sale.synced, isTrue);
      final item = await (db.select(db.saleItemsTable)
            ..where((t) => t.saleId.equals('sale-remote-1')))
          .getSingle();
      expect(item.quantity, 2);
      expect(item.unitPrice, 3500);

      expect(await db.syncQueueDao.getMeta('pull_cursor'), '7');
      // Stock changed server-side → products/lots snapshots re-mirrored.
      expect(refreshed, containsAll([SyncDomain.products, SyncDomain.lots]));
    });

    test('is idempotent: replaying the same page duplicates nothing',
        () async {
      final dio = _FakeDio(
        (call, data) async => _appliedResponse(data),
        pullHandler: (call, query) => {
          'events': [saleEvent()],
          'next_cursor': 7,
          'has_more': false,
        },
      );
      final w = worker(dio);
      await w.kick().timeout(const Duration(seconds: 5));
      // Simulate a lost cursor write → same events arrive again.
      await db.syncQueueDao.setMeta('pull_cursor', '0');
      await w.kick().timeout(const Duration(seconds: 5));

      final sales = await db.select(db.salesTable).get();
      final items = await db.select(db.saleItemsTable).get();
      expect(sales.length, 1);
      expect(items.length, 1);
    });

    test('resumes from the persisted cursor and follows has_more', () async {
      final requestedCursors = <Object?>[];
      await db.syncQueueDao.setMeta('pull_cursor', '3');
      final dio = _FakeDio(
        (call, data) async => _appliedResponse(data),
        pullHandler: (call, query) {
          requestedCursors.add(query?['cursor']);
          return {
            'events': <Object>[],
            'next_cursor': call == 1 ? 5 : 5,
            'has_more': call == 1,
          };
        },
      );
      await worker(dio).kick().timeout(const Duration(seconds: 5));

      expect(requestedCursors, [3, 5]);
      expect(await db.syncQueueDao.getMeta('pull_cursor'), '5');
    });

    test('applies shift open/close from other devices', () async {
      final dio = _FakeDio(
        (call, data) async => _appliedResponse(data),
        pullHandler: (call, query) => {
          'events': [
            {
              'server_id': 1,
              'op': 'shift.open',
              'user_id': 'user-2',
              'occurred_at': '2026-07-17T08:00:00Z',
              'applied_at': '2026-07-17T08:00:02Z',
              'payload': {
                'id': 'shift-1',
                'opened_at': '2026-07-17T08:00:00Z',
                'opening_cash': '200.00',
              },
            },
            {
              'server_id': 2,
              'op': 'shift.close',
              'user_id': 'user-2',
              'occurred_at': '2026-07-17T17:00:00Z',
              'applied_at': '2026-07-17T17:00:02Z',
              'payload': {
                'id': 'shift-1',
                'declared_closing_cash': '950.00',
              },
            },
          ],
          'next_cursor': 2,
          'has_more': false,
        },
      );
      await worker(dio).kick().timeout(const Duration(seconds: 5));

      final shift = await (db.select(db.shiftsTable)
            ..where((t) => t.id.equals('shift-1')))
          .getSingle();
      expect(shift.userId, 'user-2');
      expect(shift.openingCash, 20000);
      expect(shift.declaredClosingCash, 95000);
      expect(shift.closedAt, isNotNull);
    });

    test('propagates product deletion from another device', () async {
      await db.productsDao.upsertAll([
        Product(
          id: 'p9',
          shopId: 'shop-1',
          name: 'Discontinued',
          purchasePrice: Decimal.parse('10'),
          sellingPrice: Decimal.parse('15'),
          stock: Decimal.zero,
          lowStockThreshold: Decimal.one,
          unit: 'piece',
        ),
      ]);
      final dio = _FakeDio(
        (call, data) async => _appliedResponse(data),
        pullHandler: (call, query) => {
          'events': [
            {
              'server_id': 1,
              'op': 'product.delete',
              'user_id': 'user-2',
              'occurred_at': '2026-07-17T10:00:00Z',
              'applied_at': '2026-07-17T10:00:01Z',
              'payload': {'id': 'p9'},
            },
          ],
          'next_cursor': 1,
          'has_more': false,
        },
      );
      await worker(dio).kick().timeout(const Duration(seconds: 5));

      final row = await (db.select(db.productsTable)
            ..where((t) => t.id.equals('p9')))
          .getSingle();
      // Snapshot refreshes never remove rows, so the delete must land here.
      expect(row.deletedAt, isNotNull);
    });

    test('one malformed event does not block the rest of the feed', () async {
      final dio = _FakeDio(
        (call, data) async => _appliedResponse(data),
        pullHandler: (call, query) => {
          'events': [
            {
              'server_id': 1,
              'op': 'sale.create',
              'user_id': 'user-2',
              'occurred_at': '2026-07-17T09:00:00Z',
              'applied_at': '2026-07-17T09:00:05Z',
              'payload': {'id': 'broken'}, // missing every required field
            },
            saleEvent(),
          ],
          'next_cursor': 7,
          'has_more': false,
        },
      );
      await worker(dio).kick().timeout(const Duration(seconds: 5));

      final sales = await db.select(db.salesTable).get();
      expect(sales.map((s) => s.id), ['sale-remote-1']);
      expect(await db.syncQueueDao.getMeta('pull_cursor'), '7');
    });
  });
}
