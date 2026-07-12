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
import 'package:suuqii/features/expenses/data/expenses_remote_data_source.dart';
import 'package:suuqii/features/expenses/domain/entities/expense.dart';
import 'package:suuqii/features/shifts/data/shifts_repository.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';
import 'package:uuid/uuid.dart';

part 'expenses_repository.g.dart';

/// Mirrors Shop.expense_approval_threshold on the server (default 500 ETB;
/// there is currently no API to change it). Cashier expenses at or below the
/// threshold sync without a PIN; anything above needs an owner challenge, so
/// the UI collects the PIN upfront instead of failing at sync time.
final Decimal defaultExpenseApprovalThreshold = Decimal.parse('500');

class ExpensesRepository {
  ExpensesRepository({
    required this.db,
    required this.remote,
    required this.syncWorker,
    required this.shopId,
    required this.userId,
    required this.shiftId,
  });

  final AppDatabase db;
  final ExpensesRemoteDataSource remote;
  final SyncWorker syncWorker;
  final String shopId;
  final String userId;
  final String? shiftId;

  Stream<List<Expense>> watch() => db.expensesDao.watchAll(shopId: shopId);

  Future<int> refreshFromServer() async {
    final items = await remote.list(shopId: shopId);
    await db.expensesDao.upsertAll(items);
    return items.length;
  }

  Future<void> add({
    required String title,
    required Decimal amount,
    required String category,
    String? description,
    DateTime? occurredAt,
    String? ownerChallengeToken,
  }) async {
    if (amount <= Decimal.zero) throw StateError('Amount must be positive');
    final id = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final at = occurredAt ?? now;
    final shift = shiftId;

    await db.transaction(() async {
      await db.into(db.expensesTable).insert(
            ExpensesTableCompanion.insert(
              id: id,
              shopId: shopId,
              userId: userId,
              shiftId: Value(shift),
              title: title,
              amount: santimFromDecimal(amount),
              category: Value(category),
              description: Value(description),
              occurredAt: at,
            ),
          );
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'expense.create',
              occurredAt: at,
              payload: jsonEncode({
                'id': id,
                if (shift != null) 'shift_id': shift,
                'title': title,
                'amount': amount.toString(),
                'category': category,
                if (description != null) 'description': description,
                'occurred_at': at.toIso8601String(),
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
  }
}

@Riverpod(keepAlive: true)
ExpensesRepository expensesRepository(ExpensesRepositoryRef ref) {
  final auth = ref.watch(authControllerProvider).valueOrNull;
  if (auth is! Authenticated) {
    throw StateError('ExpensesRepository requires authenticated user');
  }
  final shift = ref.watch(currentShiftProvider).valueOrNull;
  return ExpensesRepository(
    db: ref.watch(appDatabaseProvider),
    remote: ExpensesRemoteDataSource(ref.watch(dioProvider)),
    syncWorker: ref.watch(syncWorkerProvider),
    shopId: auth.shopId,
    userId: auth.userId,
    shiftId: shift?.id,
  );
}

@riverpod
Stream<List<Expense>> watchExpenses(WatchExpensesRef ref) {
  return ref.watch(expensesRepositoryProvider).watch();
}

@riverpod
class ExpensesSync extends _$ExpensesSync {
  @override
  Future<void> build() async {}

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final auth = ref.read(authControllerProvider).valueOrNull;
      if (auth is! Authenticated) return;
      await ref.read(expensesRepositoryProvider).refreshFromServer();
    });
  }
}
