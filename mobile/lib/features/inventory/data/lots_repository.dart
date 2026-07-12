import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/core/utils/unit_conversion.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/lots_dao.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/stock_lot.dart';
import 'package:suuqii/features/supplies/domain/entities/supply.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';
import 'package:uuid/uuid.dart';

part 'lots_repository.g.dart';

/// One row of the owner batch report (GET /v1/reports/batches): the exact
/// economics of a single purchase/production batch.
class BatchReportEntry {
  const BatchReportEntry({
    required this.lotId,
    required this.productId,
    required this.productName,
    required this.receivedAt,
    required this.unitCost,
    required this.qtyReceived,
    required this.qtySold,
    required this.qtySpoiled,
    required this.qtyRemaining,
    required this.revenue,
    required this.margin,
    required this.spoilageCost,
    this.expiryDate,
    this.note,
  });

  factory BatchReportEntry.fromJson(Map<String, dynamic> j) =>
      BatchReportEntry(
        lotId: j['lot_id'] as String,
        productId: j['product_id'] as String,
        productName: j['product_name'] as String,
        receivedAt: DateTime.parse(j['received_at'] as String),
        expiryDate: j['expiry_date'] == null
            ? null
            : DateTime.parse(j['expiry_date'] as String),
        unitCost: Decimal.parse(j['unit_cost'] as String),
        qtyReceived: Decimal.parse(j['qty_received'] as String),
        qtySold: Decimal.parse(j['qty_sold'] as String),
        qtySpoiled: Decimal.parse(j['qty_spoiled'] as String),
        qtyRemaining: Decimal.parse(j['qty_remaining'] as String),
        revenue: Decimal.parse(j['revenue'] as String),
        margin: Decimal.parse(j['margin'] as String),
        spoilageCost: Decimal.parse(j['spoilage_cost'] as String),
        note: j['note'] as String?,
      );

  final String lotId;
  final String productId;
  final String productName;
  final DateTime receivedAt;
  final DateTime? expiryDate;
  final Decimal unitCost;
  final Decimal qtyReceived;
  final Decimal qtySold;
  final Decimal qtySpoiled;
  final Decimal qtyRemaining;
  final Decimal revenue;
  final Decimal margin;
  final Decimal spoilageCost;
  final String? note;
}

class LotsRemoteDataSource {
  LotsRemoteDataSource(this._dio);
  final Dio _dio;

  /// GET /v1/products/lots — open lots for local mirroring. unit_cost is "0"
  /// for cashiers (server masks costs); stored as-is, owner-only UI shows it.
  Future<List<StockLot>> listLots() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/products/lots');
    final items =
        (res.data?['items'] as List? ?? []).cast<Map<String, dynamic>>();
    return items
        .map(
          (j) => StockLot(
            id: j['id'] as String,
            productId: j['product_id'] as String,
            qtyReceived: Decimal.parse(j['qty_received'] as String),
            qtyRemaining: Decimal.parse(j['qty_remaining'] as String),
            unitCost: Decimal.parse(j['unit_cost'] as String),
            expiryDate: j['expiry_date'] == null
                ? null
                : DateTime.parse(j['expiry_date'] as String),
            receivedAt: DateTime.parse(j['received_at'] as String),
            note: j['note'] as String?,
          ),
        )
        .toList();
  }

  /// GET /v1/reports/batches — owner-only per-batch economics.
  Future<List<BatchReportEntry>> batchReport({String? productId}) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/reports/batches',
      queryParameters: {if (productId != null) 'product_id': productId},
    );
    final items =
        (res.data?['items'] as List? ?? []).cast<Map<String, dynamic>>();
    return items.map(BatchReportEntry.fromJson).toList();
  }
}

/// Lot-level domain operations: receiving batches, recording spoilage,
/// bakery production, and mirroring server lots. All local writes and their
/// sync events commit in one Drift transaction (docs/16-inventory-lots.md).
class LotsRepository {
  LotsRepository({
    required this.db,
    required this.remote,
    required this.syncWorker,
    required this.shopId,
    required this.userId,
  });

  final AppDatabase db;
  final LotsRemoteDataSource remote;
  final SyncWorker syncWorker;
  final String shopId;
  final String userId;

  Stream<List<StockLot>> watchProductLots(String productId) =>
      db.lotsDao.watchOpenLots(productId);

  Stream<List<ExpiringLot>> watchExpiring({int days = 7}) =>
      db.lotsDao.watchExpiring(shopId: shopId, days: days);

  /// Mirror open lots from the server, skipping products with pending local
  /// sync events (same guard as the products mirror — local wins until the
  /// queue drains).
  Future<int> refreshFromServer() async {
    final lots = await remote.listLots();
    final dirty = await productIdsWithPendingChanges(db);
    await db.lotsDao.replaceFromServer(lots, dirty);
    return lots.length;
  }

  Future<List<BatchReportEntry>> batchReport({String? productId}) =>
      remote.batchReport(productId: productId);

  /// Receive a stock batch: creates the local lot, nets out units spoiled on
  /// arrival, bumps stock, mirrors the product's last cost, and enqueues
  /// `stock.receive` — all atomically.
  Future<void> receiveStock({
    required String productId,
    required Decimal quantity,
    required Decimal unitCost,
    DateTime? expiryDate,
    Decimal? spoiledQuantity,
    String? note,
    String? ownerChallengeToken,
  }) async {
    final spoiled = spoiledQuantity ?? Decimal.zero;
    if (quantity <= Decimal.zero) {
      throw StateError('Receive quantity must be positive');
    }
    if (spoiled < Decimal.zero || spoiled > quantity) {
      throw StateError('Spoiled quantity out of range');
    }
    final lotId = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final costSantim = santimFromDecimal(unitCost);
    final expiry = expiryDate == null ? null : expiryDateString(expiryDate);
    final net = quantity - spoiled;

    await db.transaction(() async {
      await db.lotsDao.insertLot(
        id: lotId,
        productId: productId,
        quantity: quantity,
        unitCostSantim: costSantim,
        expiryDate: expiry,
        receivedAt: now,
        note: note,
      );
      await db.into(db.inventoryLogsTable).insert(
            InventoryLogsTableCompanion.insert(
              id: const Uuid().v4(),
              shopId: shopId,
              productId: productId,
              movement: 'receive',
              quantityDelta: quantity.toDouble(),
              reason: Value(note),
              referenceType: const Value('stock_lot'),
              referenceId: Value(lotId),
              userId: Value(userId),
            ),
          );
      if (spoiled > Decimal.zero) {
        await db.lotsDao.consumeFefo(
          productId: productId,
          quantity: spoiled,
          movement: 'spoilage',
          fallbackCostSantim: costSantim,
          lotId: lotId,
          now: now,
        );
        await db.into(db.inventoryLogsTable).insert(
              InventoryLogsTableCompanion.insert(
                id: const Uuid().v4(),
                shopId: shopId,
                productId: productId,
                movement: 'spoilage',
                quantityDelta: -spoiled.toDouble(),
                reason: const Value('spoiled on receive'),
                referenceType: const Value('stock_lot'),
                referenceId: Value(lotId),
                userId: Value(userId),
              ),
            );
      }
      // Sellable units + last-cost display, mirroring the server.
      await db.productsDao.applyStockDelta(productId, net);
      await db.customUpdate(
        'UPDATE products SET purchase_price = ?, updated_at = ? WHERE id = ?',
        variables: [
          Variable.withInt(costSantim),
          Variable.withInt(sqliteDateTimeParam(now)),
          Variable.withString(productId),
        ],
        updates: {db.productsTable},
        updateKind: UpdateKind.update,
      );
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'stock.receive',
              occurredAt: now,
              payload: jsonEncode({
                'id': lotId,
                'product_id': productId,
                'quantity': quantity.toString(),
                'unit_cost': unitCost.toString(),
                if (expiry != null) 'expiry_date': expiry,
                if (spoiled > Decimal.zero)
                  'spoiled_quantity': spoiled.toString(),
                if (note != null && note.isNotEmpty) 'note': note,
                'occurred_at': now.toIso8601String(),
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
  }

  /// Record spoilage after the fact (expired, damaged, day-old): consumes
  /// lots FEFO (or the named lot), decrements stock, enqueues `stock.spoil`.
  Future<void> recordSpoilage({
    required String productId,
    required Decimal quantity,
    String? reason,
    String? lotId,
    String? ownerChallengeToken,
  }) async {
    if (quantity <= Decimal.zero) {
      throw StateError('Spoil quantity must be positive');
    }
    final now = DateTime.now().toUtc();
    final product = await db.productsDao.getById(productId);
    final fallback = santimFromDecimal(product?.purchasePrice ?? Decimal.zero);

    await db.transaction(() async {
      await db.lotsDao.consumeFefo(
        productId: productId,
        quantity: quantity,
        movement: 'spoilage',
        fallbackCostSantim: fallback,
        lotId: lotId,
        now: now,
      );
      await db.productsDao.applyStockDelta(productId, -quantity);
      await db.into(db.inventoryLogsTable).insert(
            InventoryLogsTableCompanion.insert(
              id: const Uuid().v4(),
              shopId: shopId,
              productId: productId,
              movement: 'spoilage',
              quantityDelta: -quantity.toDouble(),
              reason: Value(reason),
              userId: Value(userId),
            ),
          );
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'stock.spoil',
              occurredAt: now,
              payload: jsonEncode({
                'id': const Uuid().v4(),
                'product_id': productId,
                'quantity': quantity.toString(),
                if (lotId != null) 'lot_id': lotId,
                if (reason != null) 'reason': reason,
                'occurred_at': now.toIso8601String(),
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
  }

  /// Bakery: record a production run. Stock += produced − spoiled; the lot is
  /// valued at recipe cost (Σ ingredient qty × supply cost, converted to each
  /// supply's stocked unit); spoiled units deduct their recipe supplies —
  /// they consumed ingredients but will never hit a sale, which is where
  /// bakery supplies are normally deducted. Enqueues `production.record`.
  Future<void> recordProduction({
    required String productId,
    required Decimal quantityProduced,
    Decimal? quantitySpoiled,
    DateTime? expiryDate,
    String? note,
    String? ownerChallengeToken,
  }) async {
    final spoiled = quantitySpoiled ?? Decimal.zero;
    if (quantityProduced <= Decimal.zero) {
      throw StateError('Produced quantity must be positive');
    }
    if (spoiled < Decimal.zero || spoiled > quantityProduced) {
      throw StateError('Spoiled quantity out of range');
    }
    final lotId = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final expiry = expiryDate == null ? null : expiryDateString(expiryDate);

    // Recipe cost per unit, computed the same way the sale flow does.
    final recipe = await db.recipesDao.getForProduct(productId);
    final supplies = <String, Supply?>{};
    for (final item in recipe) {
      supplies[item.supplyId] ??= await db.suppliesDao.getById(item.supplyId);
    }
    var unitCost = Decimal.zero;
    final qtyPerUnitInSupplyUnit = <String, Decimal>{};
    for (final item in recipe) {
      final supply = supplies[item.supplyId];
      final supplyUnit = supply?.unit;
      final effectiveUnit = item.recipeUnit ?? supplyUnit ?? 'piece';
      final qtyPerUnit = supplyUnit != null
          ? convertUnit(item.quantity, effectiveUnit, supplyUnit)
          : item.quantity;
      qtyPerUnitInSupplyUnit[item.supplyId] = qtyPerUnit;
      unitCost += (supply?.costPerUnit ?? Decimal.zero) * qtyPerUnit;
    }
    final costSantim = santimFromDecimal(unitCost);

    await db.transaction(() async {
      await db.lotsDao.insertLot(
        id: lotId,
        productId: productId,
        quantity: quantityProduced,
        unitCostSantim: costSantim,
        expiryDate: expiry,
        receivedAt: now,
        note: note ?? 'production',
      );
      await db.into(db.inventoryLogsTable).insert(
            InventoryLogsTableCompanion.insert(
              id: const Uuid().v4(),
              shopId: shopId,
              productId: productId,
              movement: 'production',
              quantityDelta: quantityProduced.toDouble(),
              referenceType: const Value('stock_lot'),
              referenceId: Value(lotId),
              userId: Value(userId),
            ),
          );
      if (spoiled > Decimal.zero) {
        await db.lotsDao.consumeFefo(
          productId: productId,
          quantity: spoiled,
          movement: 'spoilage',
          fallbackCostSantim: costSantim,
          lotId: lotId,
          now: now,
        );
        await db.into(db.inventoryLogsTable).insert(
              InventoryLogsTableCompanion.insert(
                id: const Uuid().v4(),
                shopId: shopId,
                productId: productId,
                movement: 'spoilage',
                quantityDelta: -spoiled.toDouble(),
                reason: const Value('spoiled in production'),
                referenceType: const Value('stock_lot'),
                referenceId: Value(lotId),
                userId: Value(userId),
              ),
            );
        // Ingredients consumed by units that will never be sold.
        for (final item in recipe) {
          final perUnit = qtyPerUnitInSupplyUnit[item.supplyId] ?? item.quantity;
          await db.suppliesDao.applyDelta(item.supplyId, -(perUnit * spoiled));
        }
      }
      await db.productsDao.applyStockDelta(
        productId,
        quantityProduced - spoiled,
      );
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'production.record',
              occurredAt: now,
              payload: jsonEncode({
                'id': lotId,
                'product_id': productId,
                'quantity_produced': quantityProduced.toString(),
                if (spoiled > Decimal.zero)
                  'quantity_spoiled': spoiled.toString(),
                if (expiry != null) 'expiry_date': expiry,
                if (note != null && note.isNotEmpty) 'note': note,
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

@Riverpod(keepAlive: true)
LotsRepository lotsRepository(LotsRepositoryRef ref) {
  final auth = ref.watch(authControllerProvider).valueOrNull;
  if (auth is! Authenticated) {
    throw StateError('LotsRepository requires authenticated user');
  }
  return LotsRepository(
    db: ref.watch(appDatabaseProvider),
    remote: LotsRemoteDataSource(ref.watch(dioProvider)),
    syncWorker: ref.watch(syncWorkerProvider),
    shopId: auth.shopId,
    userId: auth.userId,
  );
}

@riverpod
Stream<List<StockLot>> watchProductLots(
  WatchProductLotsRef ref,
  String productId,
) {
  return ref.watch(lotsRepositoryProvider).watchProductLots(productId);
}

@riverpod
Stream<List<ExpiringLot>> watchExpiringLots(WatchExpiringLotsRef ref) {
  return ref.watch(lotsRepositoryProvider).watchExpiring();
}

@riverpod
Future<List<BatchReportEntry>> batchReport(
  BatchReportRef ref, {
  String? productId,
}) {
  return ref.watch(lotsRepositoryProvider).batchReport(productId: productId);
}

/// One-shot lots mirror, kicked from the inventory screen (open + pull to
/// refresh). Failures are swallowed — offline is normal; local lots simply
/// stay as-is until connectivity returns.
@riverpod
class LotsSync extends _$LotsSync {
  @override
  Future<void> build() async {}

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final auth = ref.read(authControllerProvider).valueOrNull;
      if (auth is! Authenticated) return;
      await ref.read(lotsRepositoryProvider).refreshFromServer();
    });
  }
}
