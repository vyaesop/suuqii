import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/domain/entities/stock_lot.dart'
    show expiryDateString;
import 'package:suuqii/features/supplies/domain/entities/supply.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';
import 'package:uuid/uuid.dart';

part 'supplies_repository.g.dart';

class SuppliesRepository {
  SuppliesRepository({
    required this.db,
    required this.syncWorker,
    required this.shopId,
    required this.userId,
  });

  final AppDatabase db;
  final SyncWorker syncWorker;
  final String shopId;
  final String userId;

  Stream<List<Supply>> watch() => db.suppliesDao.watchAll(shopId: shopId);

  Future<List<Supply>> getAll() => db.suppliesDao.getAllByShop(shopId);

  Future<Supply?> getById(String id) => db.suppliesDao.getById(id);

  Future<Supply> create({
    required String name,
    required String unit,
    required Decimal quantityOnHand,
    required Decimal reorderThreshold,
    required Decimal costPerUnit,
    DateTime? expiryDate,
    String? ownerChallengeToken,
  }) async {
    final id = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final supply = Supply(
      id: id,
      shopId: shopId,
      name: name,
      unit: unit,
      quantityOnHand: quantityOnHand,
      reorderThreshold: reorderThreshold,
      costPerUnit: costPerUnit,
      expiryDate: expiryDate,
    );

    await db.transaction(() async {
      await db.suppliesDao.upsertAll([supply]);
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'supply.create',
              occurredAt: now,
              payload: jsonEncode({
                'id': id,
                'name': name,
                'unit': unit,
                'quantity_on_hand': quantityOnHand.toString(),
                'reorder_threshold': reorderThreshold.toString(),
                'cost_per_unit': costPerUnit.toString(),
                if (expiryDate != null)
                  'expiry_date': expiryDateString(expiryDate),
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
    return supply;
  }

  Future<void> update({
    required String id,
    required String name,
    required String unit,
    required Decimal quantityOnHand,
    required Decimal reorderThreshold,
    required Decimal costPerUnit,
    DateTime? expiryDate,
    String? ownerChallengeToken,
  }) async {
    final existing = await db.suppliesDao.getById(id);
    if (existing == null) throw StateError('Supply not found');
    final now = DateTime.now().toUtc();
    final updated = Supply(
      id: id,
      shopId: existing.shopId,
      name: name,
      unit: unit,
      quantityOnHand: quantityOnHand,
      reorderThreshold: reorderThreshold,
      costPerUnit: costPerUnit,
      expiryDate: expiryDate,
    );

    await db.transaction(() async {
      await db.suppliesDao.upsertAll([updated]);
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'supply.update',
              occurredAt: now,
              payload: jsonEncode({
                'id': id,
                'name': name,
                'unit': unit,
                'quantity_on_hand': quantityOnHand.toString(),
                'reorder_threshold': reorderThreshold.toString(),
                'cost_per_unit': costPerUnit.toString(),
                // Always sent (null clears): the server only touches
                // expiry_date when the key is present in the payload.
                'expiry_date':
                    expiryDate == null ? null : expiryDateString(expiryDate),
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
  }

  Future<void> delete(String id, {String? ownerChallengeToken}) async {
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await db.customStatement(
        'UPDATE supplies SET deleted_at = ? WHERE id = ?',
        [sqliteDateTimeParam(now), id],
      );
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'supply.delete',
              occurredAt: now,
              payload: jsonEncode({
                'id': id,
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
SuppliesRepository suppliesRepository(SuppliesRepositoryRef ref) {
  final auth = ref.watch(authControllerProvider).valueOrNull;
  if (auth is! Authenticated) {
    throw StateError('SuppliesRepository requires authenticated user');
  }
  return SuppliesRepository(
    db: ref.watch(appDatabaseProvider),
    syncWorker: ref.watch(syncWorkerProvider),
    shopId: auth.shopId,
    userId: auth.userId,
  );
}

@riverpod
Stream<List<Supply>> watchSupplies(WatchSuppliesRef ref) {
  return ref.watch(suppliesRepositoryProvider).watch();
}

@riverpod
Stream<List<Supply>> watchLowSupplies(WatchLowSuppliesRef ref) {
  return ref
      .watch(suppliesRepositoryProvider)
      .watch()
      .map((list) => list.where((s) => s.isLow).toList());
}
