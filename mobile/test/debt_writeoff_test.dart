import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/debt/data/debts_remote_data_source.dart';
import 'package:suuqii/features/debt/data/debts_repository.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';

class _FakeConnectivity extends Fake implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [ConnectivityResult.none];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

/// Sync worker whose [kick] is a no-op: these tests exercise the local
/// (offline) writes only — pushing is covered by sync_worker_test.dart.
class _NoopSyncWorker extends SyncWorker {
  _NoopSyncWorker(AppDatabase db)
      : super(
          db: db,
          dio: Dio(),
          connectivity: _FakeConnectivity(),
          deviceId: () async => 'test-device',
        );

  @override
  Future<void> kick() async {}
}

const shopId = 'shop-1';
const userId = 'user-1';

void main() {
  late AppDatabase db;
  late DebtsRepository debts;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    debts = DebtsRepository(
      db: db,
      remote: DebtsRemoteDataSource(Dio()),
      syncWorker: _NoopSyncWorker(db),
      shopId: shopId,
      userId: userId,
      shiftId: null,
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> insertDebt({
    String id = 'd1',
    String status = 'partial',
    int owedSantim = 20000, // 200.00 birr
    int paidSantim = 5000, // 50.00 birr
  }) {
    return db.into(db.debtsTable).insert(
          DebtsTableCompanion.insert(
            id: id,
            shopId: shopId,
            customerName: 'Abebe',
            amountOwed: owedSantim,
            amountPaid: Value(paidSantim),
            status: Value(status),
          ),
        );
  }

  group('debt.writeoff', () {
    test(
        'marks the debt written_off, books a local bad-debt expense for the '
        'remaining balance, and enqueues only a debt.writeoff event', () async {
      await insertDebt();

      await debts.writeOff(debtId: 'd1', ownerChallengeToken: 'challenge-123');

      final row = await (db.select(db.debtsTable)
            ..where((t) => t.id.equals('d1')))
          .getSingle();
      expect(row.status, 'written_off');

      // Local bad-debt expense mirrors the server's own booking:
      // remaining 200.00 − 50.00 = 150.00 birr = 15000 santim.
      final expense = await db.select(db.expensesTable).getSingle();
      expect(expense.title, 'Bad debt write-off: Abebe');
      expect(expense.amount, 15000);
      expect(expense.category, 'other');
      expect(expense.shiftId, null);

      // Exactly one sync event: debt.writeoff with the owner challenge
      // embedded. No expense.create — the server books the expense itself
      // from the writeoff, so a second event would double-book it.
      final events = await db.select(db.syncEventsTable).get();
      expect(events, hasLength(1));
      expect(events.single.op, 'debt.writeoff');
      expect(events.single.payload, contains('"debt_id":"d1"'));
      expect(
        events.single.payload,
        contains('"owner_challenge":"challenge-123"'),
      );
    });

    test('owner write-off (no challenge) omits owner_challenge', () async {
      await insertDebt(status: 'open', paidSantim: 0);

      await debts.writeOff(debtId: 'd1');

      final event = await db.select(db.syncEventsTable).getSingle();
      expect(event.op, 'debt.writeoff');
      expect(event.payload, isNot(contains('owner_challenge')));

      // Nothing collected → the whole 200.00 becomes bad debt.
      final expense = await db.select(db.expensesTable).getSingle();
      expect(expense.amount, 20000);
    });

    test('refuses paid and already written-off debts', () async {
      await insertDebt(id: 'paid', status: 'paid', paidSantim: 20000);
      await insertDebt(id: 'gone', status: 'written_off');

      expect(() => debts.writeOff(debtId: 'paid'), throwsStateError);
      expect(() => debts.writeOff(debtId: 'gone'), throwsStateError);
      expect(await db.select(db.expensesTable).get(), isEmpty);
      expect(await db.select(db.syncEventsTable).get(), isEmpty);
    });
  });
}
