import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/debt/data/debts_remote_data_source.dart';
import 'package:suuqii/features/debt/domain/entities/debt.dart';
import 'package:suuqii/features/shifts/data/shifts_repository.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';
import 'package:uuid/uuid.dart';

part 'debts_repository.g.dart';

class DebtsRepository {
  DebtsRepository({
    required this.db,
    required this.remote,
    required this.syncWorker,
    required this.shopId,
    required this.userId,
    required this.shiftId,
  });

  final AppDatabase db;
  final DebtsRemoteDataSource remote;
  final SyncWorker syncWorker;
  final String shopId;
  final String userId;
  final String? shiftId;

  Stream<List<Debt>> watch({DebtStatus? status}) =>
      db.debtsDao.watchAll(shopId: shopId, status: status);

  Future<Debt?> byId(String id) => db.debtsDao.getById(id);

  Stream<List<DebtPayment>> watchPayments(String debtId) =>
      db.debtsDao.watchPayments(debtId);

  /// Total outstanding balance (amount_owed - amount_paid) for all open/partial
  /// debts linked to a given customer phone number. Used at checkout to warn
  /// the cashier before extending more credit to an already-indebted customer.
  Future<Decimal> outstandingByPhone(String phone) async {
    if (phone.isEmpty) return Decimal.zero;
    // Money is stored as int64 santim, so the SUM is exact integer math.
    final rows = await db.customSelect(
      'SELECT COALESCE(SUM(amount_owed - amount_paid), 0) AS outstanding '
      'FROM debts '
      'WHERE shop_id = ? AND customer_phone = ? '
      "AND status IN ('open', 'partial') AND deleted_at IS NULL",
      variables: [Variable.withString(shopId), Variable.withString(phone)],
      readsFrom: {db.debtsTable},
    ).get();
    final val = rows.firstOrNull?.read<int>('outstanding');
    if (val == null) return Decimal.zero;
    return decimalFromSantim(val);
  }

  Future<int> refreshFromServer() async {
    // Pull both open + partial; paid ones are kept locally but stale is fine.
    final open = await remote.list(shopId: shopId, status: 'open');
    final partial = await remote.list(shopId: shopId, status: 'partial');
    // Debts touched by still-pending sync events are skipped, mirroring the
    // products refresh: the server hasn't seen those local changes yet, so
    // its rows would revert an optimistic payment/write-off — the customer
    // would briefly show as owing money they already handed over.
    final dirty = await debtIdsWithPendingChanges(db);
    final all = [...open, ...partial]
        .where((d) => !dirty.contains(d.id))
        .toList();
    await db.debtsDao.upsertAll(all);
    return all.length;
  }

  Future<void> recordPayment({
    required String debtId,
    required Decimal amount,
    required String method, // 'cash' | 'mobile_money'
    String? note,
  }) async {
    if (amount <= Decimal.zero) {
      throw StateError('Payment must be positive');
    }
    final debt = await db.debtsDao.getById(debtId);
    if (debt == null) throw StateError('Debt not found');

    final paymentId = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final shift = shiftId;

    // Compute resulting status locally.
    final newPaid = debt.amountPaid + amount;
    final newStatus = newPaid >= debt.amountOwed
        ? DebtStatus.paid
        : DebtStatus.partial;

    await db.transaction(() async {
      // Insert payment row
      await db.into(db.debtPaymentsTable).insert(
            DebtPaymentsTableCompanion.insert(
              id: paymentId,
              debtId: debtId,
              shopId: shopId,
              shiftId: Value(shift),
              amount: santimFromDecimal(amount),
              paidAt: now,
              method: method,
              userId: userId,
              note: Value(note),
            ),
          );

      // Update local debt state (server is authoritative; we mirror eagerly)
      await (db.update(db.debtsTable)..where((t) => t.id.equals(debtId))).write(
        DebtsTableCompanion(
          amountPaid: Value(santimFromDecimal(newPaid)),
          status: Value(debtStatusKey(newStatus)),
          updatedAt: Value(now),
        ),
      );

      // Enqueue sync event
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'debt.payment.create',
              occurredAt: now,
              payload: jsonEncode({
                'id': paymentId,
                'debt_id': debtId,
                if (shift != null) 'shift_id': shift,
                'amount': amount.toString(),
                'paid_at': now.toIso8601String(),
                'method': method,
                if (note != null) 'note': note,
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
  }

  /// Writes off an open/partial debt: marks it written_off locally, books the
  /// uncollected balance as a local bad-debt expense, and enqueues a single
  /// `debt.writeoff` sync event. The server creates its own bad-debt expense
  /// from that event, so we deliberately do NOT enqueue `expense.create` —
  /// doing so would double-book the expense server-side.
  ///
  /// Sensitive op (docs/17-roles.md): cashiers must pass an
  /// [ownerChallengeToken]; owners may pass null.
  Future<void> writeOff({
    required String debtId,
    String? ownerChallengeToken,
  }) async {
    final debt = await db.debtsDao.getById(debtId);
    if (debt == null) throw StateError('Debt not found');
    if (debt.status != DebtStatus.open && debt.status != DebtStatus.partial) {
      throw StateError('Only open or partial debts can be written off');
    }

    final now = DateTime.now().toUtc();
    final remaining = debt.remaining;

    await db.transaction(() async {
      await (db.update(db.debtsTable)..where((t) => t.id.equals(debtId))).write(
        DebtsTableCompanion(
          status: Value(debtStatusKey(DebtStatus.writtenOff)),
          updatedAt: Value(now),
        ),
      );

      // Local mirror of the server-side bad-debt expense. Title/category
      // match what the server books so the next expenses pull upserts over
      // this row instead of duplicating it visually.
      await db.into(db.expensesTable).insert(
            ExpensesTableCompanion.insert(
              id: const Uuid().v4(),
              shopId: shopId,
              userId: userId,
              title: 'Bad debt write-off: ${debt.customerName}',
              amount: santimFromDecimal(remaining),
              category: const Value('other'),
              occurredAt: now,
            ),
          );

      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'debt.writeoff',
              occurredAt: now,
              payload: jsonEncode({
                'debt_id': debtId,
                'occurred_at': now.toIso8601String(),
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
  }
}

/// Debt ids referenced by pending sync events (payments, write-offs, and
/// credit sales that create a debt). Server snapshots must not clobber these
/// rows until the queue drains — local wins while its change is in flight.
Future<Set<String>> debtIdsWithPendingChanges(AppDatabase db) async {
  final pending = await (db.select(db.syncEventsTable)
        ..where((t) => t.status.equals('pending')))
      .get();
  final ids = <String>{};
  for (final ev in pending) {
    final payload = jsonDecode(ev.payload) as Map<String, dynamic>;
    final id = switch (ev.op) {
      'debt.payment.create' || 'debt.writeoff' => payload['debt_id'],
      'debt.create' => payload['id'],
      'sale.create' => payload['debt_id'], // credit sale creating a debt
      _ => null,
    };
    if (id is String) ids.add(id);
  }
  return ids;
}

@Riverpod(keepAlive: true)
DebtsRepository debtsRepository(DebtsRepositoryRef ref) {
  final auth = ref.watch(authControllerProvider).valueOrNull;
  if (auth is! Authenticated) {
    throw StateError('DebtsRepository requires authenticated user');
  }
  final shift = ref.watch(currentShiftProvider).valueOrNull;
  return DebtsRepository(
    db: ref.watch(appDatabaseProvider),
    remote: DebtsRemoteDataSource(ref.watch(dioProvider)),
    syncWorker: ref.watch(syncWorkerProvider),
    shopId: auth.shopId,
    userId: auth.userId,
    shiftId: shift?.id,
  );
}

@riverpod
Stream<List<Debt>> watchDebts(WatchDebtsRef ref, {DebtStatus? status}) {
  return ref.watch(debtsRepositoryProvider).watch(status: status);
}

@riverpod
Stream<List<DebtPayment>> watchDebtPayments(
  WatchDebtPaymentsRef ref,
  String debtId,
) {
  return ref.watch(debtsRepositoryProvider).watchPayments(debtId);
}

@riverpod
class DebtsSync extends _$DebtsSync {
  @override
  Future<void> build() async {}

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final auth = ref.read(authControllerProvider).valueOrNull;
      if (auth is! Authenticated) return;
      await ref.read(debtsRepositoryProvider).refreshFromServer();
    });
  }
}
