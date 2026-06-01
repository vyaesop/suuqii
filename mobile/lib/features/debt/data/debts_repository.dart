import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/storage/app_database.dart';
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

  Future<int> refreshFromServer() async {
    // Pull both open + partial; paid ones are kept locally but stale is fine.
    final open = await remote.list(shopId: shopId, status: 'open');
    final partial = await remote.list(shopId: shopId, status: 'partial');
    final all = [...open, ...partial];
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
              amount: amount.toDouble(),
              paidAt: now,
              method: method,
              userId: userId,
              note: Value(note),
            ),
          );

      // Update local debt state (server is authoritative; we mirror eagerly)
      await (db.update(db.debtsTable)..where((t) => t.id.equals(debtId))).write(
        DebtsTableCompanion(
          amountPaid: Value(newPaid.toDouble()),
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
