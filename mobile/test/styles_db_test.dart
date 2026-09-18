import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/inventory/data/styles_remote_data_source.dart';
import 'package:suuqii/features/inventory/data/styles_repository.dart';
import 'package:suuqii/features/sync/data/sync_reconciler.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';

class _FakeConnectivity extends Fake implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [ConnectivityResult.none];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

/// Sync worker whose [kick] is a no-op: these tests exercise the local
/// (offline) writes only.
class _NoopSyncWorker extends SyncWorker {
  _NoopSyncWorker(AppDatabase db)
      : super(
          db: db,
          dio: Dio(),
          connectivity: _FakeConnectivity(),
          deviceId: () async => 'test-device',
        );

  @override
  Future<void> kick() async {}
}

const shopId = 'shop-1';
const userId = 'user-1';

void main() {
  late AppDatabase db;
  late StylesRepository styles;

  /// The same repository as [styles] but signed in as a cashier — cost and
  /// mark-down fields behave differently for them.
  late StylesRepository cashierStyles;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    final worker = _NoopSyncWorker(db);
    final lots = LotsRepository(
      db: db,
      remote: LotsRemoteDataSource(Dio()),
      syncWorker: worker,
      shopId: shopId,
      userId: userId,
    );
    styles = StylesRepository(
      db: db,
      remote: StylesRemoteDataSource(Dio()),
      syncWorker: worker,
      lots: lots,
      shopId: shopId,
      isOwner: true,
    );
    cashierStyles = StylesRepository(
      db: db,
      remote: StylesRemoteDataSource(Dio()),
      syncWorker: worker,
      lots: lots,
      shopId: shopId,
      isOwner: false,
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<List<SyncEventRow>> events() =>
      (db.select(db.syncEventsTable)..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();

  test('in-memory database opens at schema v11 with the boutique tables',
      () async {
    expect(db.schemaVersion, 11);
    // Every v11 table answers a query; a missing table would throw.
    await db.select(db.stylesTable).get();
    await db.select(db.saleReturnsTable).get();
    await db.select(db.saleReturnItemsTable).get();
    // New nullable product columns are readable on a plain insert.
    await db.into(db.productsTable).insert(
          ProductsTableCompanion.insert(
            id: 'p-plain',
            shopId: shopId,
            name: 'Belt',
            purchasePrice: 100,
            sellingPrice: 200,
          ),
        );
    final plain = await db.productsDao.getById('p-plain');
    expect(plain!.styleId, isNull);
    expect(plain.sku, isNull);
    expect(plain.minSellingPrice, isNull);
    expect(plain.isVariant, isFalse);
  });

  test('createStyle writes the style, N variants at stock 0 and ONE event',
      () async {
    final style = await styles.createStyle(
      name: 'Slim jeans',
      brand: "Levi's",
      category: 'Jeans',
      segment: 'men',
      defaultSellingPrice: Decimal.parse('1200'),
      defaultPurchasePrice: Decimal.parse('800'),
      minSellingPrice: Decimal.parse('1000'),
      sizeSet: 'waist',
      skuPrefix: 'jn',
      variants: const [
        VariantDraft(size: '32', color: 'Blue'),
        VariantDraft(size: '34', color: 'Blue'),
        VariantDraft(size: '32', color: 'Black'),
      ],
    );

    final stored = await db.stylesDao.getById(style.id);
    expect(stored, isNotNull);
    expect(stored!.name, 'Slim jeans');
    expect(stored.skuPrefix, 'JN');
    expect(stored.defaultSellingPrice, Decimal.parse('1200'));

    final variants = await db.productsDao.getByStyle(style.id);
    expect(variants, hasLength(3));
    expect(
      variants.map((v) => v.name).toSet(),
      {'Slim jeans · 32 · Blue', 'Slim jeans · 34 · Blue', 'Slim jeans · 32 · Black'},
    );
    expect(
      variants.map((v) => v.sku).toSet(),
      {'JN-32-BLU', 'JN-34-BLU', 'JN-32-BLA'},
    );
    for (final v in variants) {
      expect(v.stock, Decimal.zero);
      expect(v.unit, 'piece');
      expect(v.category, 'Jeans');
      expect(v.styleId, style.id);
      expect(v.sellingPrice, Decimal.parse('1200'));
      expect(v.purchasePrice, Decimal.parse('800'));
      expect(v.minSellingPrice, Decimal.parse('1000'));
      expect(v.lowStockThreshold, Decimal.one);
    }

    final evs = await events();
    expect(evs, hasLength(1));
    expect(evs.single.op, 'style.create');
    final payload = jsonDecode(evs.single.payload) as Map<String, dynamic>;
    expect(payload['id'], style.id);
    expect(payload['sku_prefix'], 'JN');
    expect(payload['default_purchase_price'], '800');
    expect(payload['variants'], hasLength(3));
    final first = (payload['variants'] as List).first as Map<String, dynamic>;
    expect(first.keys, containsAll(['id', 'size', 'color', 'sku', 'selling_price', 'purchase_price', 'low_stock_threshold', 'min_selling_price']));

    // Summary aggregates come from the products table.
    final summaries = await styles.watchSummaries().first;
    expect(summaries.single.variantCount, 3);
    expect(summaries.single.stockTotal, Decimal.zero);
    expect(summaries.single.sizesOut, 3);
    expect(summaries.single.hasBrokenRun, isFalse);
  });

  test('opening quantities become stock.receive lots after the style event',
      () async {
    final style = await styles.createStyle(
      name: 'Tee',
      defaultSellingPrice: Decimal.parse('500'),
      defaultPurchasePrice: Decimal.parse('300'),
      sizeSet: 'letter',
      variants: [
        VariantDraft(size: 'M', openingQty: Decimal.fromInt(4)),
        const VariantDraft(size: 'L'),
      ],
      openingUnitCost: Decimal.parse('280'),
    );
    final variants = await db.productsDao.getByStyle(style.id);
    final m = variants.singleWhere((v) => v.size == 'M');
    final l = variants.singleWhere((v) => v.size == 'L');
    expect(m.stock, Decimal.fromInt(4));
    expect(l.stock, Decimal.zero);
    // Last cost mirrors the receive, as receiveStock does for any product.
    expect(m.purchasePrice, Decimal.parse('280'));

    final lots = await db.lotsDao.openLotsFefo(m.id);
    expect(lots, hasLength(1));
    expect(lots.single.qtyRemaining, 4);
    expect(lots.single.unitCostSantim, 28000);

    final evs = await events();
    expect(evs.map((e) => e.op).toList(), ['style.create', 'stock.receive']);
    final receive = jsonDecode(evs.last.payload) as Map<String, dynamic>;
    expect(receive['product_id'], m.id);
    expect(receive['quantity'], '4');

    final summaries = await styles.watchSummaries().first;
    expect(summaries.single.hasBrokenRun, isTrue);
  });

  test('duplicate (size, colour) cells are rejected and nothing is written',
      () async {
    await expectLater(
      styles.createStyle(
        name: 'Dup',
        defaultSellingPrice: Decimal.parse('10'),
        defaultPurchasePrice: Decimal.zero,
        variants: const [
          VariantDraft(size: 'M', color: 'Red'),
          VariantDraft(size: 'M', color: 'Red'),
        ],
      ),
      throwsStateError,
    );
    expect(await db.select(db.stylesTable).get(), isEmpty);
    expect(await events(), isEmpty);
  });

  test('updateStyle recomposes names, propagates category, rewrites SKUs',
      () async {
    final style = await styles.createStyle(
      name: 'Slim jeans',
      category: 'Jeans',
      defaultSellingPrice: Decimal.parse('1200'),
      defaultPurchasePrice: Decimal.parse('800'),
      skuPrefix: 'JN',
      variants: const [VariantDraft(size: '32', color: 'Blue')],
    );
    await styles.updateStyle(
      id: style.id,
      name: 'Skinny jeans',
      category: 'Denim',
      defaultSellingPrice: Decimal.parse('999'),
      defaultPurchasePrice: Decimal.parse('800'),
      skuPrefix: 'SK',
      applyPriceToVariants: true,
    );
    final v = (await db.productsDao.getByStyle(style.id)).single;
    expect(v.name, 'Skinny jeans · 32 · Blue');
    expect(v.category, 'Denim');
    expect(v.sku, 'SK-32-BLU');
    expect(v.sellingPrice, Decimal.parse('999'));

    final evs = await events();
    expect(evs.last.op, 'style.update');
    final payload = jsonDecode(evs.last.payload) as Map<String, dynamic>;
    expect(payload['apply_price_to_variants'], isTrue);
    expect(payload['sku_prefix'], 'SK');
  });

  test('clearing the SKU prefix clears the variant SKUs (server parity)',
      () async {
    final style = await styles.createStyle(
      name: 'Scarf',
      defaultSellingPrice: Decimal.parse('300'),
      defaultPurchasePrice: Decimal.zero,
      skuPrefix: 'SC',
      variants: const [
        VariantDraft(size: 'M', color: 'Blue'),
        // No size and no colour → the SKU *is* the prefix.
        VariantDraft(),
      ],
    );
    expect(
      (await db.productsDao.getByStyle(style.id)).map((v) => v.sku).toSet(),
      {'SC-M-BLU', 'SC'},
    );

    await styles.updateStyle(
      id: style.id,
      name: 'Scarf',
      defaultSellingPrice: Decimal.parse('300'),
      defaultPurchasePrice: Decimal.zero,
      skuPrefix: '',
    );
    final variants = await db.productsDao.getByStyle(style.id);
    // "Replace the old prefix with nothing": the head goes, and a SKU that
    // was only the prefix is cleared outright.
    expect(
      variants.singleWhere((v) => v.size == 'M').sku,
      'M-BLU',
    );
    expect(variants.singleWhere((v) => v.size == null).sku, isNull);
  });

  test('a cashier cannot mark down: no repricing, no flag on the wire',
      () async {
    final style = await styles.createStyle(
      name: 'Tee',
      defaultSellingPrice: Decimal.parse('500'),
      defaultPurchasePrice: Decimal.parse('300'),
      variants: const [VariantDraft(size: 'M')],
    );
    await cashierStyles.updateStyle(
      id: style.id,
      name: 'Tee',
      defaultSellingPrice: Decimal.parse('400'),
      defaultPurchasePrice: Decimal.parse('300'),
      applyPriceToVariants: true,
    );
    // `_style_update` answers `forbidden` for a non-owner, so the local price
    // must not move either — it would silently revert on the next mirror.
    final v = (await db.productsDao.getByStyle(style.id)).single;
    expect(v.sellingPrice, Decimal.parse('500'));
    final payload = jsonDecode((await events()).last.payload)
        as Map<String, dynamic>;
    expect(payload.containsKey('apply_price_to_variants'), isFalse);
  });

  test('a matrix over the 200-variant cap is refused before anything is written',
      () async {
    await expectLater(
      styles.createStyle(
        name: 'Huge',
        defaultSellingPrice: Decimal.parse('10'),
        defaultPurchasePrice: Decimal.zero,
        variants: [
          for (var i = 0; i <= maxVariantsPerStyle; i++)
            VariantDraft(size: 's$i'),
        ],
      ),
      throwsA(isA<VariantCapException>()),
    );
    expect(await db.select(db.stylesTable).get(), isEmpty);
    expect(await events(), isEmpty);
  });

  test('addVariants counts live variants against the cap', () async {
    final style = await styles.createStyle(
      name: 'Tee',
      defaultSellingPrice: Decimal.parse('500'),
      defaultPurchasePrice: Decimal.zero,
      variants: [
        for (var i = 0; i < maxVariantsPerStyle - 1; i++)
          VariantDraft(size: 's$i'),
      ],
    );
    // 199 live + 1 fits; 199 + 2 does not.
    await expectLater(
      styles.addVariants(
        styleId: style.id,
        variants: const [VariantDraft(size: 'x'), VariantDraft(size: 'y')],
      ),
      throwsA(isA<VariantCapException>()),
    );
    expect(
      await db.productsDao.getByStyle(style.id),
      hasLength(maxVariantsPerStyle - 1),
    );
    final added = await styles.addVariants(
      styleId: style.id,
      variants: const [VariantDraft(size: 'x')],
    );
    expect(added, hasLength(1));
  });

  test('skuTaken finds live duplicates case-insensitively, ignoring self',
      () async {
    final style = await styles.createStyle(
      name: 'Slim jeans',
      defaultSellingPrice: Decimal.parse('1200'),
      defaultPurchasePrice: Decimal.zero,
      skuPrefix: 'JN',
      variants: const [VariantDraft(size: '32', color: 'Blue')],
    );
    final v = (await db.productsDao.getByStyle(style.id)).single;

    expect(await db.productsDao.skuTaken('jn-32-blu', shopId: shopId), isTrue);
    expect(
      await db.productsDao
          .skuTaken('JN-32-BLU', shopId: shopId, excludingProductId: v.id),
      isFalse,
    );
    expect(await db.productsDao.skuTaken('JN-34-BLU', shopId: shopId), isFalse);
    expect(await db.productsDao.skuTaken('  ', shopId: shopId), isFalse);
    // Another shop's SKU is not a collision, and neither is a deleted row.
    expect(
      await db.productsDao.skuTaken('JN-32-BLU', shopId: 'shop-2'),
      isFalse,
    );
    await db.productsDao.softDeleteByStyle(style.id, DateTime.now().toUtc());
    expect(await db.productsDao.skuTaken('JN-32-BLU', shopId: shopId), isFalse);
  });

  test('addVariants skips live cells, resolves SKUs against existing ones',
      () async {
    final style = await styles.createStyle(
      name: 'Tee',
      defaultSellingPrice: Decimal.parse('500'),
      defaultPurchasePrice: Decimal.zero,
      skuPrefix: 'TE',
      variants: const [VariantDraft(size: 'M', color: 'Blue')],
    );
    final added = await styles.addVariants(
      styleId: style.id,
      variants: const [
        VariantDraft(size: 'M', color: 'Blue'), // already live → skipped
        VariantDraft(size: 'L', color: 'Blue'),
        VariantDraft(size: 'M', color: 'Blu'), // collides with TE-M-BLU
      ],
    );
    expect(added, hasLength(2));
    expect(added.map((p) => p.sku).toSet(), {'TE-L-BLU', 'TE-M-BLU2'});
    expect(await db.productsDao.getByStyle(style.id), hasLength(3));
    final evs = await events();
    expect(evs.last.op, 'style.add_variants');
    final payload = jsonDecode(evs.last.payload) as Map<String, dynamic>;
    expect(payload['style_id'], style.id);
    expect(payload['variants'], hasLength(2));
  });

  test('deleteStyle refuses while a variant has stock, then soft-deletes',
      () async {
    final style = await styles.createStyle(
      name: 'Tee',
      defaultSellingPrice: Decimal.parse('500'),
      defaultPurchasePrice: Decimal.zero,
      variants: [VariantDraft(size: 'M', openingQty: Decimal.one)],
    );
    await expectLater(
      styles.deleteStyle(style.id),
      throwsA(isA<StyleHasStockException>()),
    );
    expect(await db.stylesDao.getById(style.id), isNotNull);

    final variant = (await db.productsDao.getByStyle(style.id)).single;
    await db.productsDao.applyStockDelta(variant.id, -Decimal.one);
    await styles.deleteStyle(style.id);

    expect(await styles.watchStyles().first, isEmpty);
    expect(await db.productsDao.getByStyle(style.id), isEmpty);
    expect((await events()).last.op, 'style.delete');
  });

  test('SKU / barcode exact match wins over the folded-name search', () async {
    await styles.createStyle(
      name: 'Slim jeans 32',
      defaultSellingPrice: Decimal.parse('1200'),
      defaultPurchasePrice: Decimal.zero,
      skuPrefix: 'JN',
      variants: const [
        VariantDraft(size: '32', color: 'Blue'),
        VariantDraft(size: '34', color: 'Blue'),
      ],
    );
    final bySku =
        await db.productsDao.watchAll(shopId: shopId, query: 'jn-34-blu').first;
    expect(bySku.map((p) => p.sku), ['JN-34-BLU']);

    final byName =
        await db.productsDao.watchAll(shopId: shopId, query: 'jeans 32').first;
    // Both composed names contain "jeans 32" (the style name does).
    expect(byName, hasLength(2));
  });

  test('reconciler maps style ops to {styles, products} and sale.return',
      () {
    for (final op in [
      'style.create',
      'style.update',
      'style.add_variants',
      'style.delete',
    ]) {
      expect(
        SyncReconciler.domainsForOp(op, const {}),
        {SyncDomain.styles, SyncDomain.products},
        reason: op,
      );
    }
    expect(
      SyncReconciler.domainsForOp('sale.return', const {}),
      {SyncDomain.products, SyncDomain.lots},
    );
  });
}
