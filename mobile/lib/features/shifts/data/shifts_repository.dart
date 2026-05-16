import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/storage/app_database.dart';
import '../../auth/domain/entities/auth_state.dart';
import '../../auth/presentation/controllers/auth_controller.dart';
import '../../sync/data/sync_worker.dart';
import '../domain/entities/shift.dart';

part 'shifts_repository.g.dart';

class ShiftsRepository {
  ShiftsRepository({
    required this.db,
    required this.kickSync,
    required this.userId,
    required this.shopId,
  });

  final AppDatabase db;
  final Future<void> Function() kickSync;
  final String userId;
  final String shopId;

  Stream<Shift?> watchCurrent() {
    final q = db.select(db.shiftsTable)
      ..where((t) => t.userId.equals(userId) & t.closedAt.isNull())
      ..limit(1);
    return q.watchSingleOrNull().map((row) => row == null ? null : _toDomain(row));
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
      await db.into(db.shiftsTable).insert(ShiftsTableCompanion.insert(
            id: id,
            shopId: shopId,
            userId: userId,
            openedAt: openedAt,
            openingCash: openingCash.toDouble(),
          ));
      await db.into(db.syncEventsTable).insert(SyncEventsTableCompanion.insert(
            clientEventId: const Uuid().v4(),
            op: 'shift.open',
            occurredAt: openedAt,
            payload: jsonEncode({
              'id': id,
              'opened_at': openedAt.toIso8601String(),
              'opening_cash': openingCash.toString(),
            }),
          ));
    });
    unawaited(kickSync());
    final row = await (db.select(db.shiftsTable)..where((t) => t.id.equals(id))).getSingle();
    return _toDomain(row);
  }

  Future<({Decimal expected, Shift shift})> close({
    required String shiftId,
    required Decimal declaredCash,
    String? note,
  }) async {
    final row = await (db.select(db.shiftsTable)..where((t) => t.id.equals(shiftId))).getSingleOrNull();
    if (row == null) throw StateError('Shift not found');
    if (row.closedAt != null) throw StateError('Shift already closed');

    final expected = await _computeExpectedCash(shiftId, Decimal.parse(row.openingCash.toString()));
    final now = DateTime.now().toUtc();

    await db.transaction(() async {
      await (db.update(db.shiftsTable)..where((t) => t.id.equals(shiftId))).write(
        ShiftsTableCompanion(
          declaredClosingCash: Value(declaredCash.toDouble()),
          expectedClosingCash: Value(expected.toDouble()),
          closedAt: Value(now),
          note: Value(note),
          updatedAt: Value(now),
        ),
      );
      await db.into(db.syncEventsTable).insert(SyncEventsTableCompanion.insert(
            clientEventId: const Uuid().v4(),
            op: 'shift.close',
            occurredAt: now,
            payload: jsonEncode({
              'id': shiftId,
              'declared_closing_cash': declaredCash.toString(),
              if (note != null) 'note': note,
            }),
          ));
    });
    unawaited(kickSync());
    final updated = await (db.select(db.shiftsTable)..where((t) => t.id.equals(shiftId))).getSingle();
    return (expected: expected, shift: _toDomain(updated));
  }

  Future<Decimal> _computeExpectedCash(String shiftId, Decimal openingCash) async {
    Decimal asDec(double? v) => Decimal.parse((v ?? 0).toString());

    final cashSales = await db.customSelect(
      "SELECT COALESCE(SUM(total), 0) AS t FROM sales "
      "WHERE shift_id = ? AND payment_method = 'cash' "
      "AND status = 'completed' AND deleted_at IS NULL",
      variables: [Variable.withString(shiftId)],
    ).getSingle();
    final cashRefunds = await db.customSelect(
      "SELECT COALESCE(SUM(total), 0) AS t FROM sales "
      "WHERE shift_id = ? AND payment_method = 'cash' AND status = 'refunded'",
      variables: [Variable.withString(shiftId)],
    ).getSingle();
    final debtCollected = await db.customSelect(
      "SELECT COALESCE(SUM(amount), 0) AS t FROM debt_payments "
      "WHERE shift_id = ? AND method = 'cash'",
      variables: [Variable.withString(shiftId)],
    ).getSingle();
    final expenses = await db.customSelect(
      "SELECT COALESCE(SUM(amount), 0) AS t FROM expenses "
      "WHERE shift_id = ? AND deleted_at IS NULL",
      variables: [Variable.withString(shiftId)],
    ).getSingle();

    return openingCash
        + asDec(cashSales.read<double?>('t'))
        + asDec(debtCollected.read<double?>('t'))
        - asDec(expenses.read<double?>('t'))
        - asDec(cashRefunds.read<double?>('t'));
  }

  Shift _toDomain(ShiftRow r) => Shift(
        id: r.id,
        shopId: r.shopId,
        userId: r.userId,
        openedAt: r.openedAt,
        closedAt: r.closedAt,
        openingCash: Decimal.parse(r.openingCash.toString()),
        declaredClosingCash: r.declaredClosingCash == null
            ? null
            : Decimal.parse(r.declaredClosingCash.toString()),
        expectedClosingCash: r.expectedClosingCash == null
            ? null
            : Decimal.parse(r.expectedClosingCash.toString()),
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
    kickSync: () => ref.read(syncWorkerProvider).kick(),
    userId: auth.userId,
    shopId: auth.shopId,
  );
}

@riverpod
Stream<Shift?> currentShift(CurrentShiftRef ref) {
  return ref.watch(shiftsRepositoryProvider).watchCurrent();
}
