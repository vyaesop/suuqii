import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/shifts/domain/entities/shift.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';
import 'package:uuid/uuid.dart';

part 'shifts_repository.g.dart';

class ShiftsRepository {
  ShiftsRepository({
    required this.db,
    required this.syncWorker,
    required this.userId,
    required this.shopId,
  });

  final AppDatabase db;
  final SyncWorker syncWorker;
  final String userId;
  final String shopId;

  Stream<Shift?> watchCurrent() {
    final q = db.select(db.shiftsTable)
      ..where((t) => t.userId.equals(userId) & t.closedAt.isNull())
      ..limit(1);
    return q
        .watchSingleOrNull()
        .map((row) => row == null ? null : _toDomain(row));
  }

  Future<Shift> open({required Decimal openingCash}) async {
    final existing = await (db.select(db.shiftsTable)
          ..where((t) => t.userId.equals(userId) & t.closedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) throw StateError('Shift already open');

    final id = const Uuid().v4();
    final openedAt = DateTime.now().toUtc();
    await db.transaction(() async {
      await db.into(db.shiftsTable).insert(
            ShiftsTableCompanion.insert(
              id: id,
              shopId: shopId,
              userId: userId,
              openedAt: openedAt,
              openingCash: santimFromDecimal(openingCash),
            ),
          );
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'shift.open',
              occurredAt: openedAt,
              payload: jsonEncode({
                'id': id,
                'opened_at': openedAt.toIso8601String(),
                'opening_cash': openingCash.toString(),
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
    final row = await (db.select(db.shiftsTable)..where((t) => t.id.equals(id)))
        .getSingle();
    return _toDomain(row);
  }

  Future<({ShiftBreakdown breakdown, Shift shift})> close({
    required String shiftId,
    required Decimal declaredCash,
    String? note,
  }) async {
    final row = await (db.select(db.shiftsTable)
          ..where((t) => t.id.equals(shiftId)))
        .getSingleOrNull();
    if (row == null) throw StateError('Shift not found');
    if (row.closedAt != null) throw StateError('Shift already closed');

    final breakdown = await computeBreakdown(
      shiftId,
      decimalFromSantim(row.openingCash),
    );
    final now = DateTime.now().toUtc();

    await db.transaction(() async {
      await (db.update(db.shiftsTable)..where((t) => t.id.equals(shiftId)))
          .write(
        ShiftsTableCompanion(
          declaredClosingCash: Value(santimFromDecimal(declaredCash)),
          expectedClosingCash: Value(santimFromDecimal(breakdown.expected)),
          closedAt: Value(now),
          note: Value(note),
          updatedAt: Value(now),
        ),
      );
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'shift.close',
              occurredAt: now,
              payload: jsonEncode({
                'id': shiftId,
                'declared_closing_cash': declaredCash.toString(),
                if (note != null) 'note': note,
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
    final updated = await (db.select(db.shiftsTable)
          ..where((t) => t.id.equals(shiftId)))
        .getSingle();
    return (breakdown: breakdown, shift: _toDomain(updated));
  }

  /// Returns the full cash-drawer math: opening + cash sales + debt collected
  /// − expenses − cash refunds = expected. Exposed so the UI can preview it
  /// before the cashier declares their count.
  Future<ShiftBreakdown> computeBreakdown(
    String shiftId,
    Decimal openingCash,
  ) async {
    // Money is stored as int64 santim, so each SUM below is exact
    // integer math and converts back losslessly.
    Decimal asDec(int? v) => decimalFromSantim(v ?? 0);

    final cashSales = await db.customSelect(
      'SELECT COALESCE(SUM(total), 0) AS t FROM sales '
      "WHERE shift_id = ? AND payment_method = 'cash' "
      "AND status = 'completed' AND deleted_at IS NULL",
      variables: [Variable.withString(shiftId)],
    ).getSingle();
    final cashRefunds = await db.customSelect(
      'SELECT COALESCE(SUM(total), 0) AS t FROM sales '
      "WHERE shift_id = ? AND payment_method = 'cash' AND status = 'refunded'",
      variables: [Variable.withString(shiftId)],
    ).getSingle();
    final debtCollected = await db.customSelect(
      'SELECT COALESCE(SUM(amount), 0) AS t FROM debt_payments '
      "WHERE shift_id = ? AND method = 'cash'",
      variables: [Variable.withString(shiftId)],
    ).getSingle();
    final expenses = await db.customSelect(
      'SELECT COALESCE(SUM(amount), 0) AS t FROM expenses '
      'WHERE shift_id = ? AND deleted_at IS NULL',
      variables: [Variable.withString(shiftId)],
    ).getSingle();

    return ShiftBreakdown(
      openingCash: openingCash,
      cashSales: asDec(cashSales.read<int?>('t')),
      debtCollected: asDec(debtCollected.read<int?>('t')),
      expenses: asDec(expenses.read<int?>('t')),
      cashRefunds: asDec(cashRefunds.read<int?>('t')),
    );
  }

  Shift _toDomain(ShiftRow r) => Shift(
        id: r.id,
        shopId: r.shopId,
        userId: r.userId,
        openedAt: r.openedAt,
        closedAt: r.closedAt,
        openingCash: decimalFromSantim(r.openingCash),
        declaredClosingCash: r.declaredClosingCash == null
            ? null
            : decimalFromSantim(r.declaredClosingCash!),
        expectedClosingCash: r.expectedClosingCash == null
            ? null
            : decimalFromSantim(r.expectedClosingCash!),
        note: r.note,
      );
}

@Riverpod(keepAlive: true)
ShiftsRepository shiftsRepository(ShiftsRepositoryRef ref) {
  final auth = ref.watch(authControllerProvider).valueOrNull;
  if (auth is! Authenticated) {
    throw StateError('ShiftsRepository requires authenticated user');
  }
  return ShiftsRepository(
    db: ref.watch(appDatabaseProvider),
    syncWorker: ref.watch(syncWorkerProvider),
    userId: auth.userId,
    shopId: auth.shopId,
  );
}

@riverpod
Stream<Shift?> currentShift(CurrentShiftRef ref) {
  return ref.watch(shiftsRepositoryProvider).watchCurrent();
}
