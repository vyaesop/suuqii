import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/products_remote_data_source.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';
import 'package:uuid/uuid.dart';

part 'products_repository.g.dart';

class ProductsRepository {
  ProductsRepository({
    required this.db,
    required this.remote,
    required this.kickSync,
    required this.shopId,
    required this.userId,
  });

  final AppDatabase db;
  final ProductsRemoteDataSource remote;
  final Future<void> Function() kickSync;
  final String shopId;
  final String userId;

  Stream<List<Product>> watch({String? query}) =>
      db.productsDao.watchAll(query: query);

  Future<Product?> byId(String id) => db.productsDao.getById(id);

  /// Pull fresh products from server, replace local cache.
  Future<int> refreshFromServer() async {
    final remoteList = await remote.list(shopId: shopId);
    await db.productsDao.upsertAll(remoteList);
    return remoteList.length;
  }

  /// Create a new product locally + enqueue sync event.
  Future<Product> create({
    required String name,
    required Decimal purchasePrice,
    required Decimal sellingPrice,
    required Decimal stock,
    required Decimal lowStockThreshold,
    required String unit,
    String? category,
    String? barcode,
    String? ownerChallengeToken,
  }) async {
    final id = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final product = Product(
      id: id,
      shopId: shopId,
      name: name,
      category: category,
      purchasePrice: purchasePrice,
      sellingPrice: sellingPrice,
      stock: stock,
      lowStockThreshold: lowStockThreshold,
      unit: unit,
      barcode: barcode,
      clientUpdatedAt: now,
    );

    await db.transaction(() async {
      await db.productsDao.upsertAll([product]);
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'product.create',
              occurredAt: now,
              payload: jsonEncode({
                'id': id,
                'name': name,
                'category': category,
                'purchase_price': purchasePrice.toString(),
                'selling_price': sellingPrice.toString(),
                'stock': stock.toString(),
                'low_stock_threshold': lowStockThreshold.toString(),
                'unit': unit,
                if (barcode != null) 'barcode': barcode,
                'client_updated_at': now.toIso8601String(),
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });
    unawaited(kickSync());
    return product;
  }

  /// Update product fields locally + enqueue sync event.
  /// Price changes require [ownerChallengeToken] (verified server-side).
  Future<void> update({
    required String id,
    required String? ownerChallengeToken,
    String? name,
    String? category,
    Decimal? purchasePrice,
    Decimal? sellingPrice,
    Decimal? lowStockThreshold,
    String? unit,
    String? barcode,
  }) async {
    final existing = await db.productsDao.getById(id);
    if (existing == null) throw StateError('Product not found');
    final now = DateTime.now().toUtc();

    final payload = <String, dynamic>{
      'id': id,
      'client_updated_at': now.toIso8601String(),
      if (name != null) 'name': name,
      if (category != null) 'category': category,
      if (purchasePrice != null) 'purchase_price': purchasePrice.toString(),
      if (sellingPrice != null) 'selling_price': sellingPrice.toString(),
      if (lowStockThreshold != null)
        'low_stock_threshold': lowStockThreshold.toString(),
      if (unit != null) 'unit': unit,
      if (barcode != null) 'barcode': barcode,
      if (ownerChallengeToken != null) 'owner_challenge': ownerChallengeToken,
    };

    final updated = Product(
      id: id,
      shopId: existing.shopId,
      name: name ?? existing.name,
      category: category ?? existing.category,
      purchasePrice: purchasePrice ?? existing.purchasePrice,
      sellingPrice: sellingPrice ?? existing.sellingPrice,
      stock: existing.stock,
      lowStockThreshold: lowStockThreshold ?? existing.lowStockThreshold,
      unit: unit ?? existing.unit,
      barcode: barcode ?? existing.barcode,
      imageUrl: existing.imageUrl,
      clientUpdatedAt: now,
    );

    await db.transaction(() async {
      await db.productsDao.upsertAll([updated]);
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'product.update',
              occurredAt: now,
              payload: jsonEncode(payload),
            ),
          );
    });
    unawaited(kickSync());
  }

  /// Stock adjustment: positive delta = restock, negative = waste/correction.
  /// Owner-only or audited.
  Future<void> adjustStock({
    required String productId,
    required Decimal delta,
    String? reason,
    String? ownerChallengeToken,
  }) async {
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      // Apply locally
      await db.productsDao.applyStockDelta(productId, delta);
      await db.into(db.inventoryLogsTable).insert(
            InventoryLogsTableCompanion.insert(
              id: const Uuid().v4(),
              shopId: shopId,
              productId: productId,
              movement: delta > Decimal.zero ? 'restock' : 'adjustment',
              quantityDelta: delta.toDouble(),
              reason: Value(reason),
              userId: Value(userId),
            ),
          );
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'inventory.adjust',
              occurredAt: now,
              payload: jsonEncode({
                'product_id': productId,
                'quantity_delta': delta.toString(),
                if (reason != null) 'reason': reason,
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });
    unawaited(kickSync());
  }
}

@Riverpod(keepAlive: true)
ProductsRepository productsRepository(ProductsRepositoryRef ref) {
  final auth = ref.watch(authControllerProvider).valueOrNull;
  if (auth is! Authenticated) {
    throw StateError('ProductsRepository requires authenticated user');
  }
  return ProductsRepository(
    db: ref.watch(appDatabaseProvider),
    remote: ProductsRemoteDataSource(ref.watch(dioProvider)),
    kickSync: () => ref.read(syncWorkerProvider).kick(),
    shopId: auth.shopId,
    userId: auth.userId,
  );
}

@riverpod
Stream<List<Product>> watchProducts(WatchProductsRef ref, {String? query}) {
  return ref.watch(productsRepositoryProvider).watch(query: query);
}

@riverpod
Stream<List<Product>> watchLowStockProducts(WatchLowStockProductsRef ref) {
  return ref
      .watch(productsRepositoryProvider)
      .watch()
      .map(
        (List<Product> list) =>
            list.where((Product p) => p.isLowStock).toList(),
      );
}

/// One-shot refresh kicked off after login (and when user pulls to refresh).
@riverpod
class ProductsSync extends _$ProductsSync {
  @override
  Future<void> build() async {}

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final auth = ref.read(authControllerProvider).valueOrNull;
      if (auth is! Authenticated) return;
      await ref.read(productsRepositoryProvider).refreshFromServer();
    });
  }
}
