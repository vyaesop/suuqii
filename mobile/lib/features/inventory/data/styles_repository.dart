import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/shop_type/shop_features.dart';
import 'package:suuqii/core/shop_type/variant_naming.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/inventory/data/styles_remote_data_source.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/domain/entities/style.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';
import 'package:uuid/uuid.dart';

part 'styles_repository.g.dart';

/// One cell of a new variant matrix as the wizard hands it over: the size /
/// colour pair plus an optional opening quantity.
class VariantDraft {
  const VariantDraft({this.size, this.color, this.openingQty});
  final String? size;
  final String? color;

  /// Opening stock; null or 0 = none. Received as a lot right after the
  /// style is created (docs/19 §4: variant stock in `style.create` is always
  /// 0 so every unit on hand has a lot and a cost).
  final Decimal? openingQty;

  VariantCell get cell => (size: size, color: color);
}

/// Thrown by [StylesRepository.deleteStyle] when a live variant still has
/// stock — mirrors the server's `style_has_stock` domain error.
class StyleHasStockException implements Exception {
  const StyleHasStockException();

  @override
  String toString() => 'style_has_stock';
}

/// Most variants one style may carry, mirroring the server's
/// `_check_variant_payload` 1..200 cap (docs/19 §13.3).
///
/// This is enforced on the client because the server's refusal is *terminal*:
/// the reconciler soft-deletes the style and every variant when a
/// `style.create` / `style.add_variants` is rejected, so a 12 × 20 matrix
/// built offline would simply vanish hours later.
const maxVariantsPerStyle = 200;

/// Thrown when a matrix would exceed [maxVariantsPerStyle] live variants.
/// [total] is what the style would end up with.
class VariantCapException implements Exception {
  const VariantCapException(this.total);
  final int total;

  @override
  String toString() => 'variant_cap_exceeded ($total > $maxVariantsPerStyle)';
}

/// Styles and their variant matrices (docs/19-boutique-shop-type.md §4,
/// §13.3). Every mutation writes the local rows and enqueues exactly one
/// `style.*` sync event in the same transaction; opening/received stock goes
/// through [LotsRepository.receiveStock] so a variant's units always carry a
/// lot and a cost.
class StylesRepository {
  StylesRepository({
    required this.db,
    required this.remote,
    required this.syncWorker,
    required this.lots,
    required this.shopId,
    required this.isOwner,
  });

  final AppDatabase db;
  final StylesRemoteDataSource remote;
  final SyncWorker syncWorker;
  final LotsRepository lots;
  final String shopId;

  /// Cost fields are owner-only on the wire: a cashier omits them and the
  /// server stores 0 (docs/19 §13.3).
  final bool isOwner;

  Stream<List<Style>> watchStyles() => db.stylesDao.watchAll(shopId: shopId);

  Stream<List<StyleSummary>> watchSummaries() =>
      db.stylesDao.watchSummaries(shopId: shopId);

  Stream<Style?> watchStyle(String id) => db.stylesDao.watchById(id);

  Future<Style?> byId(String id) => db.stylesDao.getById(id);

  Stream<List<Product>> watchVariants(String styleId) =>
      db.productsDao.watchByStyle(styleId);

  /// Mirror styles from the server. Styles with a pending local `style.*`
  /// event are skipped — the server has not seen those edits yet and its row
  /// would clobber them (same guard as the products mirror).
  Future<int> refreshFromServer() async {
    final remoteList = await remote.list(shopId: shopId);
    final dirty = await _styleIdsWithPendingChanges();
    final toUpsert =
        remoteList.where((s) => !dirty.contains(s.id)).toList();
    await db.stylesDao.upsertAll(toUpsert);
    return toUpsert.length;
  }

  Future<Set<String>> _styleIdsWithPendingChanges() async {
    final pending = await (db.select(db.syncEventsTable)
          ..where((t) => t.status.equals('pending')))
        .get();
    final ids = <String>{};
    for (final ev in pending) {
      if (!ev.op.startsWith('style.')) continue;
      final payload = jsonDecode(ev.payload) as Map<String, dynamic>;
      final id = payload['id'] ?? payload['style_id'];
      if (id is String) ids.add(id);
    }
    return ids;
  }

  /// Create a style with its whole variant matrix — one local transaction,
  /// ONE `style.create` event (never N `product.create`s: a half-applied
  /// matrix is worse than none). Cells with an opening quantity are then
  /// received as lots at [openingUnitCost] inside the same transaction, so
  /// the style and its opening stock commit or roll back together.
  Future<Style> createStyle({
    required String name,
    required Decimal defaultSellingPrice,
    required Decimal defaultPurchasePrice,
    required List<VariantDraft> variants,
    String? brand,
    String? category,
    String? segment,
    String? imageUrl,
    String? sizeSet,
    String? skuPrefix,
    Decimal? minSellingPrice,
    Decimal? lowStockThreshold,
    Decimal? openingUnitCost,
    String? ownerChallengeToken,
  }) async {
    if (variants.isEmpty) {
      throw StateError('A style needs at least one variant');
    }
    if (variants.length > maxVariantsPerStyle) {
      throw VariantCapException(variants.length);
    }
    _assertDistinctCells(variants.map((v) => v.cell));
    final styleId = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final prefix = _normalizePrefix(skuPrefix);
    final threshold = lowStockThreshold ?? Decimal.one;
    final style = Style(
      id: styleId,
      shopId: shopId,
      name: name.trim(),
      brand: _blankToNull(brand),
      category: _blankToNull(category),
      segment: _blankToNull(segment),
      imageUrl: _blankToNull(imageUrl),
      defaultSellingPrice: defaultSellingPrice,
      defaultPurchasePrice: defaultPurchasePrice,
      sizeSet: _blankToNull(sizeSet),
      skuPrefix: prefix,
      clientUpdatedAt: now,
    );
    final products = _buildVariants(
      style: style,
      drafts: variants,
      threshold: threshold,
      minSellingPrice: minSellingPrice,
      now: now,
    );

    await db.transaction(() async {
      await db.stylesDao.upsertAll([style]);
      await db.productsDao.upsertAll(products);
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'style.create',
              occurredAt: now,
              payload: jsonEncode({
                'id': styleId,
                'name': style.name,
                'brand': style.brand,
                'category': style.category,
                'segment': style.segment,
                'image_url': style.imageUrl,
                'default_selling_price': defaultSellingPrice.toString(),
                if (isOwner)
                  'default_purchase_price': defaultPurchasePrice.toString(),
                'size_set': style.sizeSet,
                'sku_prefix': style.skuPrefix,
                'client_updated_at': now.toIso8601String(),
                'variants': products.map(_variantPayload).toList(),
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
      await _receiveOpening(
        products: products,
        drafts: variants,
        unitCost: openingUnitCost ?? defaultPurchasePrice,
        ownerChallengeToken: ownerChallengeToken,
      );
    });
    unawaited(syncWorker.kick());
    return style;
  }

  /// Edit the shared fields. Variant names, categories and SKUs are
  /// recomposed locally the same way the server does on `style.update`, so
  /// the device shows the outcome immediately and the later products mirror
  /// finds nothing to change. [applyPriceToVariants] is the "mark down" path:
  /// every live variant takes the new default price. It is owner-only and is
  /// dropped for a cashier, whom the server would refuse.
  Future<void> updateStyle({
    required String id,
    required String name,
    required Decimal defaultSellingPrice,
    required Decimal defaultPurchasePrice,
    String? brand,
    String? category,
    String? segment,
    String? imageUrl,
    String? sizeSet,
    String? skuPrefix,
    bool applyPriceToVariants = false,
    String? ownerChallengeToken,
  }) async {
    final existing = await db.stylesDao.getById(id);
    if (existing == null) throw StateError('Style not found');
    final now = DateTime.now().toUtc();
    final prefix = _normalizePrefix(skuPrefix);
    final updated = Style(
      id: id,
      shopId: existing.shopId,
      name: name.trim(),
      brand: _blankToNull(brand),
      category: _blankToNull(category),
      segment: _blankToNull(segment),
      imageUrl: _blankToNull(imageUrl),
      defaultSellingPrice: defaultSellingPrice,
      defaultPurchasePrice: defaultPurchasePrice,
      sizeSet: _blankToNull(sizeSet),
      skuPrefix: prefix,
      clientUpdatedAt: now,
    );

    final nameChanged = updated.name != existing.name;
    final categoryChanged = updated.category != existing.category;
    final prefixChanged = updated.skuPrefix != existing.skuPrefix;
    // `apply_price_to_variants` is owner-only server-side (`_style_update`
    // answers `forbidden`). Repricing locally for a cashier would show new
    // prices that silently revert on the next mirror, so drop the whole
    // mark-down here rather than send a request that cannot succeed.
    final applyPrice = applyPriceToVariants && isOwner;

    await db.transaction(() async {
      await db.stylesDao.upsertAll([updated]);
      if (nameChanged || categoryChanged || prefixChanged || applyPrice) {
        final variants = await db.productsDao.getByStyle(id);
        final touched = variants
            .map(
              (v) {
                // Clearing the prefix can legitimately leave a variant with
                // no SKU at all; copyWith reads a null `sku` as "keep", so
                // that case needs the explicit clearSku flag or the stale
                // code would survive locally and then disagree with the
                // server's rewrite.
                final rewritten = prefixChanged
                    ? rewriteSkuPrefix(
                        v.sku,
                        existing.skuPrefix,
                        updated.skuPrefix,
                      )
                    : v.sku;
                return v.copyWith(
                  name: nameChanged
                      ? composeVariantName(updated.name, v.size, v.color)
                      : null,
                  category: categoryChanged ? updated.category : null,
                  sku: rewritten,
                  clearSku: rewritten == null,
                  sellingPrice: applyPrice ? defaultSellingPrice : null,
                  clientUpdatedAt: now,
                );
              },
            )
            .toList();
        // copyWith cannot clear category to null through `null` — a cleared
        // style category must still propagate, so patch that case directly.
        final patched = categoryChanged && updated.category == null
            ? touched.map(_withoutCategory).toList()
            : touched;
        await db.productsDao.upsertAll(patched);
      }
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'style.update',
              occurredAt: now,
              payload: jsonEncode({
                'id': id,
                'client_updated_at': now.toIso8601String(),
                'name': updated.name,
                'brand': updated.brand,
                'category': updated.category,
                'segment': updated.segment,
                'image_url': updated.imageUrl,
                'default_selling_price': defaultSellingPrice.toString(),
                if (isOwner)
                  'default_purchase_price': defaultPurchasePrice.toString(),
                'size_set': updated.sizeSet,
                'sku_prefix': updated.skuPrefix,
                if (applyPrice) 'apply_price_to_variants': true,
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
  }

  /// Add sizes/colours to an existing style: new product rows at stock 0 and
  /// one `style.add_variants` event. Cells that already exist live are
  /// skipped rather than rejected — the sheet offers the full run and the
  /// owner ticks what they bought.
  Future<List<Product>> addVariants({
    required String styleId,
    required List<VariantDraft> variants,
    Decimal? openingUnitCost,
    String? ownerChallengeToken,
  }) async {
    final style = await db.stylesDao.getById(styleId);
    if (style == null) throw StateError('Style not found');
    final existing = await db.productsDao.getByStyle(styleId);
    final live = existing.map((p) => (size: p.size, color: p.color)).toSet();
    final fresh =
        variants.where((v) => !live.contains(v.cell)).toList();
    if (fresh.isEmpty) return const [];
    // The server caps the *style*, not the payload: what counts is what the
    // style ends up with once these land.
    if (existing.length + fresh.length > maxVariantsPerStyle) {
      throw VariantCapException(existing.length + fresh.length);
    }
    _assertDistinctCells(fresh.map((v) => v.cell));
    final now = DateTime.now().toUtc();
    final threshold = existing.isEmpty
        ? Decimal.one
        : existing.first.lowStockThreshold;
    final products = _buildVariants(
      style: style,
      drafts: fresh,
      threshold: threshold,
      minSellingPrice: existing.isEmpty ? null : existing.first.minSellingPrice,
      now: now,
      takenSkus: existing.map((p) => p.sku).whereType<String>().toSet(),
    );

    await db.transaction(() async {
      await db.productsDao.upsertAll(products);
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'style.add_variants',
              occurredAt: now,
              payload: jsonEncode({
                'style_id': styleId,
                'client_updated_at': now.toIso8601String(),
                'variants': products.map(_variantPayload).toList(),
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
      await _receiveOpening(
        products: products,
        drafts: fresh,
        unitCost: openingUnitCost ?? style.defaultPurchasePrice,
        ownerChallengeToken: ownerChallengeToken,
      );
    });
    unawaited(syncWorker.kick());
    return products;
  }

  /// Soft-delete a style and all its variants. Refused locally while any
  /// variant has stock — the server would refuse too (`style_has_stock`),
  /// and an optimistic delete that bounces hours later is worse than an
  /// immediate "sell or write off the stock first".
  Future<void> deleteStyle(String id, {String? ownerChallengeToken}) async {
    final variants = await db.productsDao.getByStyle(id);
    if (variants.any((v) => v.stock > Decimal.zero)) {
      throw const StyleHasStockException();
    }
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await db.productsDao.softDeleteByStyle(id, now);
      await db.stylesDao.softDelete(id, now);
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'style.delete',
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

  List<Product> _buildVariants({
    required Style style,
    required List<VariantDraft> drafts,
    required Decimal threshold,
    required Decimal? minSellingPrice,
    required DateTime now,
    Set<String> takenSkus = const {},
  }) {
    final skus = resolveSkuCollisions(
      style.skuPrefix,
      drafts.map((d) => d.cell).toList(),
      taken: takenSkus,
    );
    return [
      for (var i = 0; i < drafts.length; i++)
        Product(
          id: const Uuid().v4(),
          shopId: shopId,
          name: composeVariantName(
            style.name,
            drafts[i].size,
            drafts[i].color,
          ),
          category: style.category,
          purchasePrice: style.defaultPurchasePrice,
          sellingPrice: style.defaultSellingPrice,
          stock: Decimal.zero,
          lowStockThreshold: threshold,
          unit: ShopFeatures.boutique.defaultUnit,
          clientUpdatedAt: now,
          styleId: style.id,
          size: _blankToNull(drafts[i].size),
          color: _blankToNull(drafts[i].color),
          sku: skus[i],
          minSellingPrice: minSellingPrice,
        ),
    ];
  }

  Map<String, dynamic> _variantPayload(Product p) => {
        'id': p.id,
        'size': p.size,
        'color': p.color,
        'sku': p.sku,
        'barcode': p.barcode,
        'selling_price': p.sellingPrice.toString(),
        if (isOwner) 'purchase_price': p.purchasePrice.toString(),
        'low_stock_threshold': p.lowStockThreshold.toString(),
        'min_selling_price': p.minSellingPrice?.toString(),
      };

  /// Opening quantities become `stock.receive` lots through the existing
  /// lots flow (nested Drift transaction = savepoint inside the caller's).
  Future<void> _receiveOpening({
    required List<Product> products,
    required List<VariantDraft> drafts,
    required Decimal unitCost,
    required String? ownerChallengeToken,
  }) async {
    for (var i = 0; i < drafts.length; i++) {
      final qty = drafts[i].openingQty;
      if (qty == null || qty <= Decimal.zero) continue;
      await lots.receiveStock(
        productId: products[i].id,
        quantity: qty,
        unitCost: unitCost,
        note: 'opening stock',
        ownerChallengeToken: ownerChallengeToken,
        // Inside the caller's transaction; createStyle/addVariants kick once
        // after it commits.
        kick: false,
      );
    }
  }

  static void _assertDistinctCells(Iterable<VariantCell> cells) {
    final seen = <VariantCell>{};
    for (final c in cells) {
      final key = (size: _blankToNull(c.size), color: _blankToNull(c.color));
      if (!seen.add(key)) {
        throw StateError('Duplicate variant ${c.size} / ${c.color}');
      }
    }
  }

  static Product _withoutCategory(Product p) => Product(
        id: p.id,
        shopId: p.shopId,
        name: p.name,
        purchasePrice: p.purchasePrice,
        sellingPrice: p.sellingPrice,
        stock: p.stock,
        lowStockThreshold: p.lowStockThreshold,
        unit: p.unit,
        barcode: p.barcode,
        imageUrl: p.imageUrl,
        clientUpdatedAt: p.clientUpdatedAt,
        styleId: p.styleId,
        size: p.size,
        color: p.color,
        sku: p.sku,
        minSellingPrice: p.minSellingPrice,
      );

  static String? _blankToNull(String? s) {
    if (s == null) return null;
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  /// SKU prefixes are stored upper-cased and capped at the server's
  /// VARCHAR(8) so a composed SKU never differs between the two sides.
  static String? _normalizePrefix(String? prefix) {
    final t = _blankToNull(prefix)?.toUpperCase().replaceAll(' ', '');
    if (t == null) return null;
    return t.length > 8 ? t.substring(0, 8) : t;
  }
}

@Riverpod(keepAlive: true)
StylesRepository stylesRepository(StylesRepositoryRef ref) {
  final auth = ref.watch(authControllerProvider).valueOrNull;
  if (auth is! Authenticated) {
    throw StateError('StylesRepository requires authenticated user');
  }
  return StylesRepository(
    db: ref.watch(appDatabaseProvider),
    remote: StylesRemoteDataSource(ref.watch(dioProvider)),
    syncWorker: ref.watch(syncWorkerProvider),
    lots: ref.watch(lotsRepositoryProvider),
    shopId: auth.shopId,
    isOwner: auth.isOwner,
  );
}

@riverpod
Stream<List<Style>> watchStyles(WatchStylesRef ref) {
  return ref.watch(stylesRepositoryProvider).watchStyles();
}

@riverpod
Stream<List<StyleSummary>> watchStyleSummaries(WatchStyleSummariesRef ref) {
  return ref.watch(stylesRepositoryProvider).watchSummaries();
}

@riverpod
Stream<Style?> watchStyle(WatchStyleRef ref, String id) {
  return ref.watch(stylesRepositoryProvider).watchStyle(id);
}

/// One-shot styles mirror, kicked from the inventory screen on boutique
/// shops. Failures are swallowed — offline is normal.
@riverpod
class StylesSync extends _$StylesSync {
  @override
  Future<void> build() async {}

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final auth = ref.read(authControllerProvider).valueOrNull;
      if (auth is! Authenticated || !auth.features.hasVariants) return;
      await ref.read(stylesRepositoryProvider).refreshFromServer();
    });
  }
}
