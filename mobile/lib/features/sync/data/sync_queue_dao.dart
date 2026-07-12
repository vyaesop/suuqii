import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/tables/sync_events_table.dart';
import 'package:uuid/uuid.dart';

part 'sync_queue_dao.g.dart';

@DriftAccessor(tables: [SyncEventsTable])
class SyncQueueDao extends DatabaseAccessor<AppDatabase>
    with _$SyncQueueDaoMixin {
  SyncQueueDao(super.db);

  Future<void> enqueue({
    required String op,
    required Map<String, dynamic> payload,
    DateTime? occurredAt,
  }) async {
    await into(syncEventsTable).insert(
      SyncEventsTableCompanion.insert(
        clientEventId: const Uuid().v4(),
        op: op,
        payload: jsonEncode(payload),
        occurredAt: occurredAt ?? DateTime.now().toUtc(),
      ),
    );
  }

  Future<List<SyncEventRow>> takePending({int limit = 50}) {
    final q = select(syncEventsTable)
      ..where((t) => t.status.equals('pending'))
      ..orderBy([(t) => OrderingTerm.asc(t.id)])
      ..limit(limit);
    return q.get();
  }

  Stream<int> watchPendingCount() {
    final q = selectOnly(syncEventsTable)
      ..addColumns([syncEventsTable.id.count()])
      ..where(syncEventsTable.status.equals('pending'));
    return q.watchSingle().map((r) => r.read(syncEventsTable.id.count()) ?? 0);
  }

  /// One-shot count of events still waiting to be pushed. Used by the
  /// logout / shop-switch guard before local data is wiped.
  Future<int> pendingCount() async {
    final q = selectOnly(syncEventsTable)
      ..addColumns([syncEventsTable.id.count()])
      ..where(syncEventsTable.status.equals('pending'));
    final r = await q.getSingle();
    return r.read(syncEventsTable.id.count()) ?? 0;
  }

  /// Events the server rejected or that exhausted their retries.
  Stream<int> watchDeadLetterCount() {
    final q = selectOnly(syncEventsTable)
      ..addColumns([syncEventsTable.id.count()])
      ..where(syncEventsTable.status.isIn(['rejected', 'failed']));
    return q.watchSingle().map((r) => r.read(syncEventsTable.id.count()) ?? 0);
  }

  Stream<List<SyncEventRow>> watchDeadLettered({int limit = 20}) {
    final q = select(syncEventsTable)
      ..where((t) => t.status.isIn(['rejected', 'failed']))
      ..orderBy([(t) => OrderingTerm.desc(t.id)])
      ..limit(limit);
    return q.watch();
  }

  Future<void> markSynced(int id) =>
      (update(syncEventsTable)..where((t) => t.id.equals(id)))
          .write(const SyncEventsTableCompanion(status: Value('synced')));

  Future<void> markRejected(int id, String? code, String? detail) =>
      (update(syncEventsTable)..where((t) => t.id.equals(id))).write(
        SyncEventsTableCompanion(
          status: const Value('rejected'),
          lastError: Value(detail ?? code ?? 'rejected'),
        ),
      );

  /// Dead-letter: permanent client-side failure (non-retryable 4xx or
  /// retry budget exhausted). The queue moves on past these events.
  Future<void> markFailed(int id, String error) =>
      (update(syncEventsTable)..where((t) => t.id.equals(id))).write(
        SyncEventsTableCompanion(
          status: const Value('failed'),
          lastError: Value(error),
        ),
      );

  Future<void> bumpAttempts(List<int> ids, String error) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await customStatement(
      'UPDATE sync_events '
      'SET attempts = attempts + 1, last_attempt_at = ?, last_error = ? '
      'WHERE id IN ($placeholders)',
      [sqliteDateTimeParam(DateTime.now()), error, ...ids],
    );
  }
}
