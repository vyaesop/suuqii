import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/debt/data/debts_repository.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('collects debt ids from pending payment/writeoff/credit-sale events',
      () async {
    await db.syncQueueDao.enqueue(
      op: 'debt.payment.create',
      payload: {'id': 'pay-1', 'debt_id': 'debt-1', 'amount': '50.00'},
    );
    await db.syncQueueDao.enqueue(
      op: 'debt.writeoff',
      payload: {'debt_id': 'debt-2'},
    );
    await db.syncQueueDao.enqueue(
      op: 'sale.create',
      payload: {'id': 'sale-1', 'debt_id': 'debt-3'},
    );
    // Cash sale (no debt) and non-debt ops must not contribute.
    await db.syncQueueDao.enqueue(
      op: 'sale.create',
      payload: {'id': 'sale-2'},
    );
    await db.syncQueueDao.enqueue(
      op: 'product.update',
      payload: {'id': 'not-a-debt'},
    );

    expect(
      await debtIdsWithPendingChanges(db),
      {'debt-1', 'debt-2', 'debt-3'},
    );
  });

  test('ignores events that are no longer pending', () async {
    await db.syncQueueDao.enqueue(
      op: 'debt.payment.create',
      payload: {'id': 'pay-1', 'debt_id': 'debt-1', 'amount': '50.00'},
    );
    final row = await db.select(db.syncEventsTable).getSingle();
    await db.syncQueueDao.markSynced(row.id);

    expect(await debtIdsWithPendingChanges(db), isEmpty);
  });
}
