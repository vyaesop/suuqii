import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/domain/entities/recipe_item.dart';
import 'package:suuqii/features/sales/data/sales_repository.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/supplies/domain/entities/supply.dart';
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
/// (offline) writes only — pushing is covered by sync_worker_test.dart.
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
  late _NoopSyncWorker worker;
  late LotsRepository lots;
  late SalesRepository sales;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    worker = _NoopSyncWorker(db);
    lots = LotsRepository(
      db: db,
      remote: LotsRemoteDataSource(Dio()),
      syncWorker: worker,
      shopId: shopId,
      userId: userId,
    );
    sales = SalesRepository(
      db: db,
      syncWorker: worker,
      currentUserId: userId,
      currentShopId: shopId,
      currentShiftId: null,
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<Product> insertProduct({
    String id = 'p1',
    String purchasePrice = '11',
  }) async {
    final p = Product(
      id: id,
      shopId: shopId,
      name: 'Soda',
      purchasePrice: Decimal.parse(purchasePrice),
      sellingPrice: Decimal.parse('15'),
      stock: Decimal.zero,
      lowStockThreshold: Decimal.zero,
      unit: 'piece',
    );
    await db.productsDao.upsertAll([p]);
    return p;
  }

  Future<Product> productById(String id) async =>
      (await db.productsDao.getById(id))!;

  Future<List<StockLotRow>> lotRows(String productId) =>
      (db.select(db.stockLotsTable)
            ..where((t) => t.productId.equals(productId))
            ..orderBy([(t) => OrderingTerm.asc(t.receivedAt)]))
          .get();

  Future<List<LotConsumptionRow>> consumptionRows() =>
      (db.select(db.lotConsumptionsTable)
            ..orderBy([(t) => OrderingTerm.asc(t.consumedAt)]))
          .get();

  group('FEFO consumption', () {
    test(
        'sale consumes the expiring lot first (despite later receipt) and '
        'computes the weighted santim cost exactly', () async {
      await insertProduct();
      // Lot B first: 10 @ 13.00, no expiry.
      await lots.receiveStock(
        productId: 'p1',
        quantity: Decimal.fromInt(10),
        unitCost: Decimal.parse('13'),
      );
      // Lot A second (received later) but expiring tomorrow: 5 @ 10.00.
      await lots.receiveStock(
        productId: 'p1',
        quantity: Decimal.fromInt(5),
        unitCost: Decimal.parse('10'),
        expiryDate: DateTime.now().add(const Duration(days: 1)),
      );

      final product = await productById('p1');
      expect(product.stock, Decimal.fromInt(15));

      final saleId = await sales.submit(
        cart: Cart([CartLine(product: product, qty: Decimal.fromInt(8))]),
        paymentMethod: PaymentMethod.cash,
      );

      // Expiring lot A (5) drained first, then 3 from lot B.
      final rows = await lotRows('p1');
      final lotA = rows.singleWhere((r) => r.expiryDate != null);
      final lotB = rows.singleWhere((r) => r.expiryDate == null);
      expect(lotA.qtyRemaining, 0);
      expect(lotB.qtyRemaining, 7);

      // Weighted cost: (5×1000 + 3×1300) / 8 = 1112.5 → 1113 santim.
      final item = await (db.select(db.saleItemsTable)
            ..where((t) => t.saleId.equals(saleId)))
          .getSingle();
      expect(item.unitCost, 1113);

      // Sale-level COGS follows the lot-based unit cost.
      final sale = await (db.select(db.salesTable)
            ..where((t) => t.id.equals(saleId)))
          .getSingle();
      expect(sale.costTotal, santimFromDecimal(Decimal.parse('11.13') * Decimal.fromInt(8)));

      final consumptions = await consumptionRows();
      final saleRows =
          consumptions.where((c) => c.movement == 'sale').toList();
      expect(saleRows, hasLength(2));
      expect(
        saleRows.map((c) => (c.lotId, c.quantity, c.unitCostSantim)).toSet(),
        {(lotA.id, 5.0, 1000), (lotB.id, 3.0, 1300)},
      );
      expect(saleRows.every((c) => c.saleItemId == item.id), isTrue);

      // Product stock decremented alongside the lots.
      expect((await productById('p1')).stock, Decimal.fromInt(7));
    });
  });

  group('stock.receive with spoiled-on-arrival', () {
    test('nets spoiled units out of the lot and records the spoilage',
        () async {
      await insertProduct();
      await lots.receiveStock(
        productId: 'p1',
        quantity: Decimal.fromInt(10),
        unitCost: Decimal.parse('12'),
        spoiledQuantity: Decimal.fromInt(2),
        note: 'supplier delivery',
      );

      final lot = (await lotRows('p1')).single;
      expect(lot.qtyReceived, 10);
      expect(lot.qtyRemaining, 8);
      expect(lot.unitCostSantim, 1200);

      // Only sellable units hit stock; last cost mirrors the batch.
      final product = await productById('p1');
      expect(product.stock, Decimal.fromInt(8));
      expect(product.purchasePrice, Decimal.parse('12'));

      final spoilage = (await consumptionRows()).single;
      expect(spoilage.movement, 'spoilage');
      expect(spoilage.lotId, lot.id);
      expect(spoilage.quantity, 2);
      expect(spoilage.unitCostSantim, 1200);

      final event = await (db.select(db.syncEventsTable)
            ..where((t) => t.op.equals('stock.receive')))
          .getSingle();
      expect(event.payload, contains('"spoiled_quantity":"2"'));
      expect(event.payload, contains('"unit_cost":"12"'));
    });
  });

  group('sale.refund', () {
    test('returns consumed quantities to their exact lots', () async {
      await insertProduct();
      await lots.receiveStock(
        productId: 'p1',
        quantity: Decimal.fromInt(10),
        unitCost: Decimal.parse('13'),
      );
      await lots.receiveStock(
        productId: 'p1',
        quantity: Decimal.fromInt(5),
        unitCost: Decimal.parse('10'),
        expiryDate: DateTime.now().add(const Duration(days: 1)),
      );

      final product = await productById('p1');
      final saleId = await sales.submit(
        cart: Cart([CartLine(product: product, qty: Decimal.fromInt(8))]),
        paymentMethod: PaymentMethod.cash,
      );
      await sales.refund(saleId: saleId, ownerChallengeToken: null);

      // Both lots restored to their original remaining quantities.
      final rows = await lotRows('p1');
      final lotA = rows.singleWhere((r) => r.expiryDate != null);
      final lotB = rows.singleWhere((r) => r.expiryDate == null);
      expect(lotA.qtyRemaining, 5);
      expect(lotB.qtyRemaining, 10);
      expect((await productById('p1')).stock, Decimal.fromInt(15));

      // Reversal rows: negative quantity, same lots, movement flag set.
      final reversals = (await consumptionRows())
          .where((c) => c.movement == 'refund_reversal')
          .toList();
      expect(reversals, hasLength(2));
      expect(
        reversals.map((c) => (c.lotId, c.quantity)).toSet(),
        {(lotA.id, -5.0), (lotB.id, -3.0)},
      );
    });
  });

  group('production.record (bakery)', () {
    test(
        'spoiled units deduct recipe supplies (g recipe / kg supply) and the '
        'lot is valued at recipe cost', () async {
      final bakery = LotsRepository(
        db: db,
        remote: LotsRemoteDataSource(Dio()),
        syncWorker: worker,
        shopId: shopId,
        userId: userId,
      );
      await insertProduct(id: 'bread', purchasePrice: '0');
      await db.suppliesDao.upsertAll([
        Supply(
          id: 'flour',
          shopId: shopId,
          name: 'Flour',
          unit: 'kg',
          quantityOnHand: Decimal.fromInt(10),
          reorderThreshold: Decimal.zero,
          costPerUnit: Decimal.fromInt(40),
        ),
      ]);
      // 500 g of flour per bread; the supply is stocked in kg.
      await db.recipesDao.setRecipe('bread', [
        RecipeItem(
          id: 'r1',
          shopId: shopId,
          productId: 'bread',
          supplyId: 'flour',
          quantity: Decimal.fromInt(500),
          recipeUnit: 'g',
        ),
      ]);

      await bakery.recordProduction(
        productId: 'bread',
        quantityProduced: Decimal.fromInt(10),
        quantitySpoiled: Decimal.fromInt(2),
        expiryDate: DateTime.now().add(const Duration(days: 1)),
      );

      // Lot valued at recipe cost: 0.5 kg × 40 = 20.00 birr = 2000 santim.
      final lot = (await lotRows('bread')).single;
      expect(lot.unitCostSantim, 2000);
      expect(lot.qtyReceived, 10);
      expect(lot.qtyRemaining, 8);
      expect(lot.expiryDate, isNotNull);

      // Stock += produced − spoiled.
      expect((await productById('bread')).stock, Decimal.fromInt(8));

      // Supplies deducted for the WHOLE bake, spoiled or not — the flour was
      // used when the dough was mixed (migration 0011): 10 × 0.5 kg = 5 kg
      // → 5 kg left. Before 0011 only the spoiled units deducted here and the
      // rest deducted at sale time, which overstated flour on hand for as long
      // as the bread went unsold.
      final flour = await db.suppliesDao.getById('flour');
      expect(flour!.quantityOnHand, Decimal.fromInt(5));

      final spoilage = (await consumptionRows()).single;
      expect(spoilage.movement, 'spoilage');
      expect(spoilage.quantity, 2);
      expect(spoilage.unitCostSantim, 2000);

      final event = await (db.select(db.syncEventsTable)
            ..where((t) => t.op.equals('production.record')))
          .getSingle();
      expect(event.payload, contains('"quantity_produced":"10"'));
      expect(event.payload, contains('"quantity_spoiled":"2"'));
      expect(event.payload, contains(lot.id));
    });

    test('production deducts its ingredients even with nothing spoiled',
        () async {
      await insertProduct(id: 'bread', purchasePrice: '0');
      await db.suppliesDao.upsertAll([
        Supply(
          id: 'flour',
          shopId: shopId,
          name: 'Flour',
          unit: 'kg',
          quantityOnHand: Decimal.fromInt(10),
          reorderThreshold: Decimal.zero,
          costPerUnit: Decimal.fromInt(40),
        ),
      ]);
      await db.recipesDao.setRecipe('bread', [
        RecipeItem(
          id: 'r1',
          shopId: shopId,
          productId: 'bread',
          supplyId: 'flour',
          quantity: Decimal.fromInt(500),
          recipeUnit: 'g',
        ),
      ]);

      await lots.recordProduction(
        productId: 'bread',
        quantityProduced: Decimal.fromInt(10),
      );

      expect((await productById('bread')).stock, Decimal.fromInt(10));
      // 10 × 500 g = 5 kg off the sack, at bake time, with nothing sold yet.
      final flour = await db.suppliesDao.getById('flour');
      expect(flour!.quantityOnHand, Decimal.fromInt(5));
      // No spoilage, so nothing was drawn back out of the lot.
      expect(await consumptionRows(), isEmpty);
    });
  });

  group('inventory.adjust lot mirroring', () {
    test('negative correction consumes lots FEFO', () async {
      await insertProduct();
      await lots.receiveStock(
        productId: 'p1',
        quantity: Decimal.fromInt(10),
        unitCost: Decimal.parse('13'),
      );

      // Local mirror of the server behavior for inventory.adjust.
      await db.transaction(() async {
        await db.lotsDao.consumeFefo(
          productId: 'p1',
          quantity: Decimal.fromInt(4),
          movement: 'adjustment',
          fallbackCostSantim: 1300,
        );
      });

      final lot = (await lotRows('p1')).single;
      expect(lot.qtyRemaining, 6);
      final adj = (await consumptionRows())
          .where((c) => c.movement == 'adjustment')
          .single;
      expect(adj.quantity, 4);
      expect(adj.unitCostSantim, 1300);
    });

    test('oversell beyond lots falls back to product cost', () async {
      await insertProduct();
      await lots.receiveStock(
        productId: 'p1',
        quantity: Decimal.fromInt(2),
        unitCost: Decimal.parse('10'),
      );

      int? weighted;
      await db.transaction(() async {
        weighted = await db.lotsDao.consumeFefo(
          productId: 'p1',
          quantity: Decimal.fromInt(4),
          movement: 'sale',
          fallbackCostSantim: 1400,
        );
      });

      // (2×1000 + 2×1400) / 4 = 1200 santim; lot clamps at zero.
      expect(weighted, 1200);
      expect((await lotRows('p1')).single.qtyRemaining, 0);
    });
  });
}
