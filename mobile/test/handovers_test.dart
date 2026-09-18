import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/handovers/data/handovers_repository.dart';
import 'package:suuqii/features/handovers/domain/entities/handover.dart';
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
const bakerId = 'baker-1';
const sellerId = 'seller-1';

void main() {
  late AppDatabase db;
  late _NoopSyncWorker worker;
  late LotsRepository lots;
  late HandoversRepository bakerRepo;
  late HandoversRepository sellerRepo;
  late SalesRepository sales;

  HandoversRepository repoFor(String userId) => HandoversRepository(
        db: db,
        remote: HandoversRemoteDataSource(Dio()),
        lots: lots,
        syncWorker: worker,
        shopId: shopId,
        userId: userId,
      );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    worker = _NoopSyncWorker(db);
    lots = LotsRepository(
      db: db,
      remote: LotsRemoteDataSource(Dio()),
      syncWorker: worker,
      shopId: shopId,
      userId: bakerId,
    );
    bakerRepo = repoFor(bakerId);
    sellerRepo = repoFor(sellerId);
    sales = SalesRepository(
      db: db,
      syncWorker: worker,
      currentUserId: sellerId,
      currentShopId: shopId,
      currentShiftId: null,
      allowsOversell: true,
    );
  });

  tearDown(() async {
    await db.close();
  });

  /// A bakery product whose recipe is 0.5 kg flour per unit at 40/kg, i.e. a
  /// recipe cost of 20.00 per unit. Mirrors the backend's `owner_bakery`.
  Future<Product> seedBread({String id = 'bread'}) async {
    final bread = Product(
      id: id,
      shopId: shopId,
      name: 'Doonaattii',
      purchasePrice: Decimal.zero,
      sellingPrice: Decimal.parse('60'),
      stock: Decimal.zero,
      lowStockThreshold: Decimal.zero,
      unit: 'piece',
    );
    await db.productsDao.upsertAll([bread]);
    await db.suppliesDao.upsertAll([
      Supply(
        id: 'flour',
        shopId: shopId,
        name: 'Flour',
        unit: 'kg',
        quantityOnHand: Decimal.fromInt(100),
        reorderThreshold: Decimal.fromInt(10),
        costPerUnit: Decimal.parse('40'),
      ),
    ]);
    await db.recipesDao.setRecipe(id, [
      RecipeItem(
        id: 'r1',
        shopId: shopId,
        productId: id,
        supplyId: 'flour',
        quantity: Decimal.parse('0.5'),
        recipeUnit: 'kg',
      ),
    ]);
    return bread;
  }

  Future<Decimal> flourOnHand() async =>
      (await db.suppliesDao.getById('flour'))!.quantityOnHand;

  Future<Product> productById(String id) async =>
      (await db.productsDao.getById(id))!;

  Future<List<String>> queuedOps() async {
    final rows = await (db.select(db.syncEventsTable)
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    return rows.map((r) => r.op).toList();
  }

  group('baker submit', () {
    test('records production, declares the handover, and moves no stock beyond '
        'what was baked', () async {
      final bread = await seedBread();

      await bakerRepo.submitBake(
        lines: [
          HandoverDraftLine(
            productId: bread.id,
            productName: bread.name,
            produced: Decimal.fromInt(20),
            handed: Decimal.fromInt(20),
          ),
        ],
        toUserId: sellerId,
      );

      // Production created the units; the handover itself moved nothing.
      expect((await productById('bread')).stock, Decimal.fromInt(20));
      // Ingredients came off for the whole bake: 20 × 0.5 kg = 10 kg.
      expect(await flourOnHand(), Decimal.fromInt(90));

      final pending = await bakerRepo.watchPending().first;
      expect(pending, hasLength(1));
      expect(pending.single.status, HandoverStatus.pending);
      expect(pending.single.totalHanded, Decimal.fromInt(20));
      expect(pending.single.fromUserId, bakerId);

      expect(await queuedOps(), ['production.record', 'handover.create']);
    });

    test('the handover payload never carries prices', () async {
      final bread = await seedBread();
      await bakerRepo.submitBake(
        lines: [
          HandoverDraftLine(
            productId: bread.id,
            productName: bread.name,
            produced: Decimal.fromInt(5),
            handed: Decimal.fromInt(5),
          ),
        ],
      );
      final row = await (db.select(db.syncEventsTable)
            ..where((t) => t.op.equals('handover.create')))
          .getSingle();
      final payload = jsonDecode(row.payload) as Map<String, dynamic>;
      final line = (payload['items'] as List).first as Map<String, dynamic>;
      expect(line.keys, isNot(contains('unit_price')));
      expect(line.keys, isNot(contains('unit_cost')));
      expect(line['qty_handed'], '5');
    });

    test('spoiled units reduce stock but not the ingredients twice', () async {
      final bread = await seedBread();
      await bakerRepo.submitBake(
        lines: [
          HandoverDraftLine(
            productId: bread.id,
            productName: bread.name,
            produced: Decimal.fromInt(20),
            spoiled: Decimal.fromInt(5),
            handed: Decimal.fromInt(15),
          ),
        ],
      );
      expect((await productById('bread')).stock, Decimal.fromInt(15));
      // 20 × 0.5 kg, charged once for the whole bake.
      expect(await flourOnHand(), Decimal.fromInt(90));
    });

    test('handing over more than was baked is refused', () async {
      final bread = await seedBread();
      await expectLater(
        bakerRepo.submitBake(
          lines: [
            HandoverDraftLine(
              productId: bread.id,
              productName: bread.name,
              produced: Decimal.fromInt(10),
              spoiled: Decimal.fromInt(4),
              handed: Decimal.fromInt(8),
            ),
          ],
        ),
        throwsA(isA<StateError>()),
      );
      // Nothing queued: the guard runs before any write.
      expect(await queuedOps(), isEmpty);
    });

    test('the same product twice in one submit is refused', () async {
      final bread = await seedBread();
      await expectLater(
        bakerRepo.submitBake(
          lines: [
            HandoverDraftLine(
              productId: bread.id,
              productName: bread.name,
              produced: Decimal.fromInt(5),
              handed: Decimal.fromInt(5),
            ),
            HandoverDraftLine(
              productId: bread.id,
              productName: bread.name,
              produced: Decimal.fromInt(3),
              handed: Decimal.fromInt(3),
            ),
          ],
        ),
        throwsA(isA<StateError>()),
      );
      expect(await queuedOps(), isEmpty);
    });
  });

  group('counter accept', () {
    Future<String> givenPendingHandover({int handed = 30}) async {
      final bread = await seedBread();
      await bakerRepo.submitBake(
        lines: [
          HandoverDraftLine(
            productId: bread.id,
            productName: bread.name,
            produced: Decimal.fromInt(handed),
            handed: Decimal.fromInt(handed),
          ),
        ],
      );
      return (await bakerRepo.watchPending().first).single.id;
    }

    test('matching counts settle as accepted with zero variance', () async {
      final id = await givenPendingHandover();
      await sellerRepo.acceptHandover(
        handoverId: id,
        countsByProductId: {'bread': Decimal.fromInt(30)},
      );

      final recent = await sellerRepo.watchRecent().first;
      final h = recent.single;
      expect(h.status, HandoverStatus.accepted);
      expect(h.acceptedByUserId, sellerId);
      expect(h.lines.single.variance, Decimal.zero);
      expect(h.grossVariance, Decimal.zero);
      expect(await queuedOps(), contains('handover.accept'));
    });

    test('a short count is disputed and keeps the gap', () async {
      // The 18-11 row from the client's real sheet: 18 units unaccounted for.
      final id = await givenPendingHandover();
      await sellerRepo.acceptHandover(
        handoverId: id,
        countsByProductId: {'bread': Decimal.fromInt(12)},
        note: 'tray looked short',
      );

      final h = (await sellerRepo.watchRecent().first).single;
      expect(h.status, HandoverStatus.disputed);
      expect(h.lines.single.variance, Decimal.fromInt(-18));
      expect(h.grossVariance, Decimal.fromInt(18));
      expect(h.discrepancies, hasLength(1));
      expect(h.acceptNote, 'tray looked short');
    });

    test('the baker cannot count in their own handover', () async {
      final id = await givenPendingHandover();
      await expectLater(
        bakerRepo.acceptHandover(
          handoverId: id,
          countsByProductId: {'bread': Decimal.fromInt(30)},
        ),
        throwsA(isA<StateError>()),
      );
      // Still pending, and no accept was queued.
      final h = (await bakerRepo.watchPending().first).single;
      expect(h.status, HandoverStatus.pending);
      expect(await queuedOps(), isNot(contains('handover.accept')));
    });

    test('an uncounted line is refused', () async {
      final bread = await seedBread();
      final cake = Product(
        id: 'cake',
        shopId: shopId,
        name: 'Toortaa',
        purchasePrice: Decimal.zero,
        sellingPrice: Decimal.parse('1000'),
        stock: Decimal.zero,
        lowStockThreshold: Decimal.zero,
        unit: 'piece',
      );
      await db.productsDao.upsertAll([cake]);
      await bakerRepo.submitBake(
        lines: [
          HandoverDraftLine(
            productId: bread.id,
            productName: bread.name,
            produced: Decimal.fromInt(10),
            handed: Decimal.fromInt(10),
          ),
          HandoverDraftLine(
            productId: cake.id,
            productName: cake.name,
            produced: Decimal.fromInt(2),
            handed: Decimal.fromInt(2),
          ),
        ],
      );
      final id = (await bakerRepo.watchPending().first).single.id;

      await expectLater(
        sellerRepo.acceptHandover(
          handoverId: id,
          countsByProductId: {'bread': Decimal.fromInt(10)},
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        (await sellerRepo.watchPending().first).single.status,
        HandoverStatus.pending,
      );
    });

    test('a second accept is refused', () async {
      final id = await givenPendingHandover();
      await sellerRepo.acceptHandover(
        handoverId: id,
        countsByProductId: {'bread': Decimal.fromInt(30)},
      );
      await expectLater(
        repoFor('seller-2').acceptHandover(
          handoverId: id,
          countsByProductId: {'bread': Decimal.fromInt(28)},
        ),
        throwsA(isA<StateError>()),
      );
      final h = (await sellerRepo.watchRecent().first).single;
      expect(h.lines.single.qtyReceived, Decimal.fromInt(30));
    });

    test('negative counts are refused', () async {
      final id = await givenPendingHandover();
      await expectLater(
        sellerRepo.acceptHandover(
          handoverId: id,
          countsByProductId: {'bread': Decimal.fromInt(-1)},
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('bakery sale converges with the regular flow', () {
    test('selling draws down the production lot and its recipe cost', () async {
      final bread = await seedBread();
      await bakerRepo.submitBake(
        lines: [
          HandoverDraftLine(
            productId: bread.id,
            productName: bread.name,
            produced: Decimal.fromInt(10),
            handed: Decimal.fromInt(10),
          ),
        ],
      );
      final flourAfterBake = await flourOnHand();

      final saleId = await sales.submit(
        cart: Cart([
          CartLine(product: await productById('bread'), qty: Decimal.fromInt(4)),
        ]),
        paymentMethod: PaymentMethod.cash,
      );

      // Stock down, lot drawn down.
      expect((await productById('bread')).stock, Decimal.fromInt(6));
      final lot = await (db.select(db.stockLotsTable)
            ..where((t) => t.productId.equals('bread')))
          .getSingle();
      expect(lot.qtyRemaining, 6);

      // COGS from the recipe-costed lot: 20.00/unit → 2000 santim.
      final item = await (db.select(db.saleItemsTable)
            ..where((t) => t.saleId.equals(saleId)))
          .getSingle();
      expect(item.unitCost, 2000);

      // Selling does not touch ingredients again.
      expect(await flourOnHand(), flourAfterBake);
    });

    test('the sale payload no longer carries supply_deductions', () async {
      final bread = await seedBread();
      await bakerRepo.submitBake(
        lines: [
          HandoverDraftLine(
            productId: bread.id,
            productName: bread.name,
            produced: Decimal.fromInt(10),
            handed: Decimal.fromInt(10),
          ),
        ],
      );
      await sales.submit(
        cart: Cart([
          CartLine(product: await productById('bread'), qty: Decimal.fromInt(2)),
        ]),
        paymentMethod: PaymentMethod.cash,
      );
      final row = await (db.select(db.syncEventsTable)
            ..where((t) => t.op.equals('sale.create')))
          .getSingle();
      final payload = jsonDecode(row.payload) as Map<String, dynamic>;
      expect(payload.keys, isNot(contains('supply_deductions')));
    });

    test('overselling a bakery product is allowed — a sync delay must not '
        'block the counter', () async {
      await seedBread();
      // The baker's handover has not synced to this device yet: stock is 0.
      expect((await productById('bread')).stock, Decimal.zero);

      final saleId = await sales.submit(
        cart: Cart([
          CartLine(product: await productById('bread'), qty: Decimal.fromInt(3)),
        ]),
        paymentMethod: PaymentMethod.cash,
      );
      expect(saleId, isNotEmpty);
      expect((await productById('bread')).stock, Decimal.fromInt(-3));
    });

    test('refund restores stock and the lot, never the flour', () async {
      final bread = await seedBread();
      await bakerRepo.submitBake(
        lines: [
          HandoverDraftLine(
            productId: bread.id,
            productName: bread.name,
            produced: Decimal.fromInt(10),
            handed: Decimal.fromInt(10),
          ),
        ],
      );
      final saleId = await sales.submit(
        cart: Cart([
          CartLine(product: await productById('bread'), qty: Decimal.fromInt(3)),
        ]),
        paymentMethod: PaymentMethod.cash,
      );
      final flourAfterSale = await flourOnHand();

      await sales.refund(saleId: saleId, ownerChallengeToken: null);

      expect((await productById('bread')).stock, Decimal.fromInt(10));
      final lot = await (db.select(db.stockLotsTable)
            ..where((t) => t.productId.equals('bread')))
          .getSingle();
      expect(lot.qtyRemaining, 10);
      expect(await flourOnHand(), flourAfterSale);
    });
  });
}
