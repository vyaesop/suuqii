import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/tables/sync_events_table.dart';
import 'package:suuqii/core/storage/tables/sync_meta_table.dart';
import 'package:uuid/uuid.dart';

part 'sync_queue_dao.g.dart';

@DriftAccessor(tables: [SyncEventsTable, SyncMetaTable])
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

  /// Events that need the user's attention: rejected by the server, retry
  /// budget exhausted, or lost a conflict (another device's change was kept).
  Stream<int> watchDeadLetterCount() {
    final q = selectOnly(syncEventsTable)
      ..addColumns([syncEventsTable.id.count()])
      ..where(syncEventsTable.status.isIn(['rejected', 'failed', 'conflict']));
    return q.watchSingle().map((r) => r.read(syncEventsTable.id.count()) ?? 0);
  }

  Stream<List<SyncEventRow>> watchDeadLettered({int limit = 20}) {
    final q = select(syncEventsTable)
      ..where((t) => t.status.isIn(['rejected', 'failed', 'conflict']))
      ..orderBy([(t) => OrderingTerm.desc(t.id)])
      ..limit(limit);
    return q.watch();
  }

  Future<void> markSynced(int id) =>
      (update(syncEventsTable)..where((t) => t.id.equals(id)))
          .write(const SyncEventsTableCompanion(status: Value('synced')));

  /// The server resolved this event against a newer state and kept its own
  /// version (e.g. a stale product edit). The event leaves the queue — it
  /// must never be retried — but stays visible so the user learns their
  /// change was not applied.
  Future<void> markConflict(int id, String? code, String? detail) =>
      (update(syncEventsTable)..where((t) => t.id.equals(id))).write(
        SyncEventsTableCompanion(
          status: const Value('conflict'),
          lastError: Value(detail ?? code ?? 'conflict'),
        ),
      );

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

  /// Sync bookkeeping key/value store (e.g. the server pull cursor).
  Future<String?> getMeta(String key) async {
    final row = await (select(syncMetaTable)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setMeta(String key, String value) =>
      into(syncMetaTable).insertOnConflictUpdate(
        SyncMetaTableCompanion.insert(key: key, value: value),
      );
}
