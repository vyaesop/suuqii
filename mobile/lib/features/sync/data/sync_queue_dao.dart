import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/storage/tables/sync_events_table.dart';

part 'sync_queue_dao.g.dart';

@DriftAccessor(tables: [SyncEventsTable])
class SyncQueueDao extends DatabaseAccessor<AppDatabase> with _$SyncQueueDaoMixin {
  SyncQueueDao(super.db);

  Future<void> enqueue({
    required String op,
    required Map<String, dynamic> payload,
    DateTime? occurredAt,
  }) async {
    await into(syncEventsTable).insert(SyncEventsTableCompanion.insert(
      clientEventId: const Uuid().v4(),
      op: op,
      payload: jsonEncode(payload),
      occurredAt: occurredAt ?? DateTime.now().toUtc(),
    ));
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

  Future<void> bumpAttempts(List<int> ids, String error) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await customStatement(
      'UPDATE sync_events '
      'SET attempts = attempts + 1, last_attempt_at = ?, last_error = ? '
      'WHERE id IN ($placeholders)',
      [DateTime.now().toIso8601String(), error, ...ids],
    );
  }
}
