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
import 'package:suuqii/features/inventory/data/products_remote_data_source.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';
import 'package:uuid/uuid.dart';

part 'products_repository.g.dart';

class ProductsRepository {
  ProductsRepository({
    required this.db,
    required this.remote,
    required this.syncWorker,
    required this.shopId,
    required this.userId,
    required this.isOwner,
  });

  final AppDatabase db;
  final ProductsRemoteDataSource remote;
  final SyncWorker syncWorker;
  final String shopId;
  final String userId;
  final bool isOwner;

  Stream<List<Product>> watch({String? query, String? category}) =>
      db.productsDao.watchAll(shopId: shopId, query: query, category: category);

  Future<Product?> byId(String id) => db.productsDao.getById(id);

  /// Whether a hand-typed [sku] already belongs to another live product, so
  /// the edit form can refuse it before the server does (`sku_collision`).
  Future<bool> isSkuTaken(String sku, {String? excludingProductId}) =>
      db.productsDao.skuTaken(
        sku,
        shopId: shopId,
        excludingProductId: excludingProductId,
      );

  Stream<Product?> watchById(String id) =>
      db.productsDao.watchById(id);

  /// Recently-sold products, deduplicated, most-recent-sale first.
  /// Used by the POS "Recent" strip for fast repeat-customer flows.
  Stream<List<Product>> watchRecent({int limit = 8}) {
    return db.customSelect(
      'SELECT p.* FROM products p '
      'JOIN ('
      '  SELECT si.product_id, MAX(s.occurred_at) AS last_sold '
      '  FROM sale_items si '
      '  JOIN sales s ON s.id = si.sale_id '
      "  WHERE s.deleted_at IS NULL AND s.status != 'refunded' "
      '  GROUP BY si.product_id '
      ') l ON l.product_id = p.id '
      'WHERE p.deleted_at IS NULL AND p.shop_id = ? '
      'ORDER BY l.last_sold DESC LIMIT ?',
      variables: [Variable.withString(shopId), Variable.withInt(limit)],
      readsFrom: {db.productsTable, db.saleItemsTable, db.salesTable},
    ).watch().map(
      (rows) => rows.map((r) {
        return Product(
          id: r.read<String>('id'),
          shopId: r.read<String>('shop_id'),
          name: r.read<String>('name'),
          category: r.readNullable<String>('category'),
          purchasePrice: decimalFromSantim(r.read<int>('purchase_price')),
          sellingPrice: decimalFromSantim(r.read<int>('selling_price')),
          stock: Decimal.parse(r.read<double>('stock').toString()),
          lowStockThreshold: Decimal.parse(
            r.read<double>('low_stock_threshold').toString(),
          ),
          unit: r.read<String>('unit'),
          barcode: r.readNullable<String>('barcode'),
          imageUrl: r.readNullable<String>('image_url'),
          styleId: r.readNullable<String>('style_id'),
          size: r.readNullable<String>('size'),
          color: r.readNullable<String>('color'),
          sku: r.readNullable<String>('sku'),
          minSellingPrice: r.readNullable<int>('min_selling_price') == null
              ? null
              : decimalFromSantim(r.read<int>('min_selling_price')),
        );
      }).toList(),
    );
  }

  Stream<List<Product>> watchByStyle(String styleId) =>
      db.productsDao.watchByStyle(styleId);

  /// Distinct non-null categories used in this shop. Reactive so the POS
  /// chip row reflects newly-introduced categories without a manual refresh.
  Stream<List<String>> watchCategories() {
    return db.customSelect(
      'SELECT DISTINCT category FROM products '
      "WHERE category IS NOT NULL AND category != '' "
      'AND deleted_at IS NULL AND shop_id = ? ORDER BY category',
      variables: [Variable.withString(shopId)],
      readsFrom: {db.productsTable},
    ).watch().map(
      (rows) => rows.map((r) => r.read<String>('category')).toList(),
    );
  }

  /// Reactive stream of recent stock movements for a single product.
  Stream<List<InventoryMovement>> watchInventoryLog(
    String productId, {
    int limit = 50,
  }) {
    return db.customSelect(
      'SELECT id, movement, quantity_delta, reason, '
      'reference_type, reference_id, user_id, created_at '
      'FROM inventory_logs WHERE product_id = ? '
      'ORDER BY created_at DESC LIMIT ?',
      variables: [
        Variable.withString(productId),
        Variable.withInt(limit),
      ],
      readsFrom: {db.inventoryLogsTable},
    ).watch().map(
      (rows) => rows
          .map(
            (r) => InventoryMovement(
              id: r.read<String>('id'),
              movement: r.read<String>('movement'),
              quantityDelta:
                  Decimal.parse(r.read<double>('quantity_delta').toString()),
              reason: r.readNullable<String>('reason'),
              referenceType: r.readNullable<String>('reference_type'),
              referenceId: r.readNullable<String>('reference_id'),
              userId: r.readNullable<String>('user_id'),
              createdAt: r.read<DateTime>('created_at'),
            ),
          )
          .toList(),
    );
  }

  /// Pull fresh products from server, replace local cache.
  ///
  /// Products touched by still-pending sync events are skipped: the server
  /// hasn't seen those local changes yet, so its rows would clobber queued
  /// stock decrements / edits. Local wins until the queue drains.
  Future<int> refreshFromServer() async {
    final remoteList = await remote.list(shopId: shopId);
    final dirty = await productIdsWithPendingChanges(db);
    final toUpsert = dirty.isEmpty
        ? remoteList
        : remoteList.where((p) => !dirty.contains(p.id)).toList();
    await db.productsDao.upsertAll(toUpsert);
    return toUpsert.length;
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
    String? imageUrl,
    String? sku,
    Decimal? minSellingPrice,
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
      imageUrl: imageUrl,
      clientUpdatedAt: now,
      sku: sku,
      minSellingPrice: minSellingPrice,
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
                // purchase_price is owner-only data; non-owners leave it unset
                // (server defaults to 0 for creates, ignores missing for updates).
                if (isOwner) 'purchase_price': purchasePrice.toString(),
                'selling_price': sellingPrice.toString(),
                'stock': stock.toString(),
                'low_stock_threshold': lowStockThreshold.toString(),
                'unit': unit,
                if (barcode != null) 'barcode': barcode,
                if (imageUrl != null) 'image_url': imageUrl,
                if (sku != null) 'sku': sku,
                if (minSellingPrice != null)
                  'min_selling_price': minSellingPrice.toString(),
                'client_updated_at': now.toIso8601String(),
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
    return product;
  }

  /// Update product fields locally + enqueue sync event.
  /// Price changes require [ownerChallengeToken] (verified server-side).
  Future<void> update({
    required String id,
    required String name,
    required String? category,
    required Decimal purchasePrice,
    required Decimal sellingPrice,
    required Decimal lowStockThreshold,
    required String unit,
    required String? barcode,
    required String? imageUrl,
    required String? ownerChallengeToken,
    String? sku,
    Decimal? minSellingPrice,
  }) async {
    final existing = await db.productsDao.getById(id);
    if (existing == null) throw StateError('Product not found');
    final now = DateTime.now().toUtc();

    // Variant identity (style_id / size / colour) is not editable here — the
    // style screen owns it — so it is neither sent nor changed; the server
    // leaves absent keys untouched. sku and min_selling_price are always
    // sent so that clearing them (null) reaches the server.
    final payload = <String, dynamic>{
      'id': id,
      'client_updated_at': now.toIso8601String(),
      'name': name,
      'category': category,
      // Non-owners cannot set purchase_price; omit so the server leaves it unchanged.
      if (isOwner) 'purchase_price': purchasePrice.toString(),
      'selling_price': sellingPrice.toString(),
      'low_stock_threshold': lowStockThreshold.toString(),
      'unit': unit,
      'barcode': barcode,
      'image_url': imageUrl,
      'sku': sku,
      'min_selling_price': minSellingPrice?.toString(),
      if (ownerChallengeToken != null) 'owner_challenge': ownerChallengeToken,
    };

    final updated = Product(
      id: id,
      shopId: existing.shopId,
      name: name,
      category: category,
      purchasePrice: purchasePrice,
      sellingPrice: sellingPrice,
      stock: existing.stock,
      lowStockThreshold: lowStockThreshold,
      unit: unit,
      barcode: barcode,
      imageUrl: imageUrl,
      clientUpdatedAt: now,
      styleId: existing.styleId,
      size: existing.size,
      color: existing.color,
      sku: sku,
      minSellingPrice: minSellingPrice,
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
    unawaited(syncWorker.kick());
  }

  /// Manual stock correction (count fix / shrinkage): positive delta adds,
  /// negative removes. Owner-only or audited.
  ///
  /// Mirrors the server's lot handling for `inventory.adjust`: a positive
  /// delta creates a local lot at the product's last cost, a negative delta
  /// consumes lots FEFO — keeping `stock ≈ Σ lots.qty_remaining` locally.
  Future<void> adjustStock({
    required String productId,
    required Decimal delta,
    String? reason,
    String? ownerChallengeToken,
  }) async {
    final now = DateTime.now().toUtc();
    final product = await db.productsDao.getById(productId);
    await db.transaction(() async {
      // Apply locally
      await db.productsDao.applyStockDelta(productId, delta);
      if (product != null) {
        if (delta > Decimal.zero) {
          await db.lotsDao.insertLot(
            id: const Uuid().v4(),
            productId: productId,
            quantity: delta,
            unitCostSantim: santimFromDecimal(product.purchasePrice),
            receivedAt: now,
            note: reason ?? 'adjustment',
          );
        } else if (delta < Decimal.zero) {
          await db.lotsDao.consumeFefo(
            productId: productId,
            quantity: -delta,
            movement: 'adjustment',
            fallbackCostSantim: santimFromDecimal(product.purchasePrice),
            now: now,
          );
        }
      }
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
    unawaited(syncWorker.kick());
  }
}

/// Product ids referenced by pending sync events (ops that create, edit or
/// move stock on a product). Shared by the products and lots mirror passes so
/// server state never clobbers queued local changes.
Future<Set<String>> productIdsWithPendingChanges(AppDatabase db) async {
  final pending = await (db.select(db.syncEventsTable)
        ..where((t) => t.status.equals('pending')))
      .get();
  final ids = <String>{};
  for (final ev in pending) {
    final payload = jsonDecode(ev.payload) as Map<String, dynamic>;
    switch (ev.op) {
      case 'product.create':
      case 'product.update':
        final id = payload['id'];
        if (id is String) ids.add(id);
      case 'style.create':
      case 'style.add_variants':
        // Variants are created inside the style event, so their rows are
        // local-only until it lands.
        final variants = payload['variants'];
        if (variants is List) {
          for (final v in variants) {
            if (v is Map && v['id'] is String) ids.add(v['id'] as String);
          }
        }
      case 'style.update':
      case 'style.delete':
        // Renames/markdowns/deletes touch every variant of the style; the
        // ids are not in the payload, so resolve them locally.
        final styleId = payload['id'];
        if (styleId is String) {
          final rows = await (db.select(db.productsTable)
                ..where((t) => t.styleId.equals(styleId)))
              .get();
          ids.addAll(rows.map((r) => r.id));
        }
      case 'inventory.adjust':
      case 'stock.receive':
      case 'stock.spoil':
      case 'production.record':
        final id = payload['product_id'];
        if (id is String) ids.add(id);
      case 'sale.create':
        final items = payload['items'];
        if (items is List) {
          for (final item in items) {
            if (item is Map<String, dynamic>) {
              final id = item['product_id'];
              if (id is String) ids.add(id);
            }
          }
        }
      case 'sale.refund':
      case 'sale.return':
        // Refunds and returns restore stock locally; the payload only carries
        // the sale id, so resolve the affected products from local sale items.
        final saleId = payload['sale_id'];
        if (saleId is String) {
          final rows = await (db.select(db.saleItemsTable)
                ..where((t) => t.saleId.equals(saleId)))
              .get();
          ids.addAll(rows.map((r) => r.productId));
        }
    }
  }
  return ids;
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
    syncWorker: ref.watch(syncWorkerProvider),
    shopId: auth.shopId,
    userId: auth.userId,
    isOwner: auth.role == 'owner',
  );
}

@riverpod
Stream<List<Product>> watchProducts(
  WatchProductsRef ref, {
  String? query,
  String? category,
}) {
  return ref
      .watch(productsRepositoryProvider)
      .watch(query: query, category: category);
}

@riverpod
Stream<List<String>> watchCategories(WatchCategoriesRef ref) {
  return ref.watch(productsRepositoryProvider).watchCategories();
}

@riverpod
Stream<List<Product>> watchRecentProducts(WatchRecentProductsRef ref) {
  return ref.watch(productsRepositoryProvider).watchRecent();
}

@riverpod
Stream<Product?> watchProduct(WatchProductRef ref, String id) {
  return ref.watch(productsRepositoryProvider).watchById(id);
}

/// Live variants of one style (boutique).
@riverpod
Stream<List<Product>> watchVariants(WatchVariantsRef ref, String styleId) {
  return ref.watch(productsRepositoryProvider).watchByStyle(styleId);
}

@riverpod
Stream<List<InventoryMovement>> watchInventoryLog(
  WatchInventoryLogRef ref,
  String productId,
) {
  return ref.watch(productsRepositoryProvider).watchInventoryLog(productId);
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
