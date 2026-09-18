import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sales/data/sales_remote_data_source.dart';
import 'package:suuqii/features/sales/data/sales_repository.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/sales/domain/entities/sale_return.dart';
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

/// Records every kick instead of pushing, including whether a drift
/// transaction was open at the time: a push started inside one runs its
/// queries on that transaction and can send rows the caller still rolls back.
class _SpySyncWorker extends SyncWorker {
  _SpySyncWorker(AppDatabase db)
      : super(
          db: db,
          dio: Dio(),
          connectivity: _FakeConnectivity(),
          deviceId: () async => 'test-device',
        );

  final List<bool> kicksInsideTransaction = [];

  int get kicks => kicksInsideTransaction.length;

  void reset() => kicksInsideTransaction.clear();

  @override
  Future<void> kick() async {
    kicksInsideTransaction.add(Zone.current[#DatabaseConnectionUser] != null);
  }
}

/// Stands in for `GET /v1/sales/{id}`: serves one canned sale.
class _FakeRemote extends SalesRemoteDataSource {
  _FakeRemote(this.sale) : super(Dio());
  final RemoteSale? sale;
  int calls = 0;

  @override
  Future<RemoteSale?> getSale(String saleId) async {
    calls++;
    return sale?.id == saleId ? sale : null;
  }
}

const shopId = 'shop-1';
const userId = 'user-1';

Product variant(String id, {String price = '1200'}) => Product(
      id: id,
      shopId: shopId,
      name: 'Slim jeans · $id',
      purchasePrice: Decimal.parse('800'),
      sellingPrice: Decimal.parse(price),
      stock: Decimal.zero,
      lowStockThreshold: Decimal.one,
      unit: 'piece',
      styleId: 'style-1',
    );

void main() {
  late AppDatabase db;
  late _SpySyncWorker worker;
  late SalesRepository sales;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    worker = _SpySyncWorker(db);
    sales = SalesRepository(
      db: db,
      syncWorker: worker,
      currentUserId: userId,
      currentShopId: shopId,
      currentShiftId: 'shift-1',
      isOwner: true,
      hasLinePricing: true,
    );
  });

  tearDown(() => db.close());

  /// A product with [lots] received in order (oldest first), stock summed.
  Future<Product> seed(
    String id,
    List<({String lotId, String qty, String cost})> lots, {
    String price = '1200',
  }) async {
    var stock = Decimal.zero;
    var t = DateTime.utc(2026, 9);
    for (final lot in lots) {
      await db.lotsDao.insertLot(
        id: lot.lotId,
        productId: id,
        quantity: Decimal.parse(lot.qty),
        unitCostSantim: Decimal.parse(lot.cost).toBigInt().toInt() * 100,
        receivedAt: t,
      );
      stock += Decimal.parse(lot.qty);
      t = t.add(const Duration(days: 1));
    }
    final p = variant(id, price: price).copyWith(stock: stock);
    await db.productsDao.upsertAll([p]);
    return (await db.productsDao.getById(id))!;
  }

  Future<String> sell(
    List<(Product, int)> lines, {
    Decimal? discount,
    List<Decimal?>? unitPrices,
  }) async {
    var cart = Cart.empty();
    for (var i = 0; i < lines.length; i++) {
      final (p, q) = lines[i];
      cart = cart.add(p, qty: Decimal.fromInt(q));
      final price = unitPrices?[i];
      if (price != null) cart = cart.setUnitPrice(p.id, price);
    }
    if (discount != null) cart = cart.setDiscount(discount);
    return sales.submit(cart: cart, paymentMethod: PaymentMethod.cash);
  }

  Future<List<SaleItemRow>> itemsOf(String saleId) =>
      (db.select(db.saleItemsTable)..where((t) => t.saleId.equals(saleId)))
          .get();

  Future<SaleRow> sale(String id) =>
      (db.select(db.salesTable)..where((t) => t.id.equals(id))).getSingle();

  Future<double> lotQty(String lotId) async =>
      (await (db.select(db.stockLotsTable)..where((t) => t.id.equals(lotId)))
              .getSingle())
          .qtyRemaining;

  Future<Decimal> stockOf(String productId) async =>
      (await db.productsDao.getById(productId))!.stock;

  Future<List<LotConsumptionRow>> consumptions(String movement) =>
      (db.select(db.lotConsumptionsTable)
            ..where((t) => t.movement.equals(movement))
            ..orderBy([(t) => OrderingTerm.asc(t.consumedAt)]))
          .get();

  Future<List<InventoryLogRow>> logs(String movement) =>
      (db.select(db.inventoryLogsTable)
            ..where((t) => t.movement.equals(movement)))
          .get();

  Future<List<SyncEventRow>> events() =>
      (db.select(db.syncEventsTable)..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();

  ReturnLine line(
    SaleItemRow item,
    int qty, [
    ReturnCondition c = ReturnCondition.resellable,
  ]) =>
      ReturnLine(
        saleItemId: item.id,
        quantity: Decimal.fromInt(qty),
        condition: c,
      );

  group('partial return inventory', () {
    test("restores only that item's lot consumptions, oldest draw first",
        () async {
      // a: 1 unit in an older lot + 10 in a newer one → selling 2 draws 1
      // from each; b: untouched by the return.
      final a = await seed('a', [
        (lotId: 'a-old', qty: '1', cost: '800'),
        (lotId: 'a-new', qty: '10', cost: '900'),
      ]);
      final b = await seed('b', [(lotId: 'b-1', qty: '10', cost: '800')]);
      final saleId = await sell([(a, 2), (b, 1)]);
      expect(await lotQty('a-old'), 0);
      expect(await lotQty('a-new'), 9);

      final items = await itemsOf(saleId);
      final itemA = items.firstWhere((i) => i.productId == a.id);
      final res = await sales.submitReturn(
        saleId: saleId,
        items: [line(itemA, 1)],
        refundAmount: Decimal.parse('1200'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.wrongSize,
      );
      expect(res.credit, Decimal.parse('1200'));

      // The first draw (old lot) is what comes back; the new lot and b's lot
      // are untouched.
      expect(await lotQty('a-old'), 1);
      expect(await lotQty('a-new'), 9);
      expect(await lotQty('b-1'), 9);
      expect(await stockOf(a.id), Decimal.fromInt(10));
      expect(await stockOf(b.id), Decimal.fromInt(9));

      final reversals = await consumptions('refund_reversal');
      expect(reversals, hasLength(1));
      expect(reversals.single.quantity, -1);
      expect(reversals.single.lotId, 'a-old');
      expect(reversals.single.saleItemId, itemA.id);
      expect(reversals.single.unitCostSantim, 80000);

      final refundLogs = await logs('refund');
      expect(refundLogs, hasLength(1));
      expect(refundLogs.single.referenceType, 'sale_return');
      expect(refundLogs.single.referenceId, res.returnId);
      expect(refundLogs.single.reason, 'wrong_size');
      expect(refundLogs.single.quantityDelta, 1);

      expect((await sale(saleId)).status, 'partially_returned');
      final retItem = (await db.select(db.saleReturnItemsTable).get()).single;
      expect(retItem.unitPrice, 120000);
      expect(retItem.condition, 'resellable');
    });

    test('two lines for one item restore each lot once', () async {
      final a = await seed('a', [
        (lotId: 'a-old', qty: '1', cost: '800'),
        (lotId: 'a-new', qty: '10', cost: '900'),
      ]);
      final saleId = await sell([(a, 2)]);
      final item = (await itemsOf(saleId)).single;

      await sales.submitReturn(
        saleId: saleId,
        items: [
          line(item, 1),
          line(item, 1, ReturnCondition.damaged),
        ],
        refundAmount: Decimal.parse('2400'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.defect,
      );

      final reversals = await consumptions('refund_reversal');
      expect(reversals.map((r) => r.lotId).toList(), ['a-old', 'a-new']);
      expect(reversals.every((r) => r.quantity == -1), isTrue);
      // Resellable unit back on the old lot; damaged unit back on and straight
      // off the new one.
      expect(await lotQty('a-old'), 1);
      expect(await lotQty('a-new'), 9);
      final spoil = await consumptions('spoilage');
      expect(spoil, hasLength(1));
      expect(spoil.single.lotId, 'a-new');
      expect(spoil.single.unitCostSantim, 90000);
      expect(await stockOf(a.id), Decimal.fromInt(10)); // 11 − 2 + 1
      expect((await sale(saleId)).status, 'refunded');
    });

    test('damaged unit nets stock to no change with a spoilage pair', () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final saleId = await sell([(a, 2)]);
      final item = (await itemsOf(saleId)).single;

      final res = await sales.submitReturn(
        saleId: saleId,
        items: [line(item, 1, ReturnCondition.damaged)],
        refundAmount: Decimal.parse('1200'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.defect,
      );

      expect(await lotQty('a-1'), 8); // back on, straight off again
      expect(await stockOf(a.id), Decimal.fromInt(8));
      final spoil = (await consumptions('spoilage')).single;
      expect(spoil.quantity, 1);
      expect(spoil.unitCostSantim, 80000);
      expect(spoil.saleItemId, item.id);
      final spoilLog = (await logs('spoilage')).single;
      expect(spoilLog.reason, 'return_damaged');
      expect(spoilLog.quantityDelta, -1);
      expect(spoilLog.referenceType, 'sale_return');
      expect(spoilLog.referenceId, res.returnId);
      expect(await logs('refund'), hasLength(1));
      expect((await sale(saleId)).status, 'partially_returned');
    });
  });

  group('validation and status', () {
    test('over-return is rejected before anything is written', () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final saleId = await sell([(a, 2)]);
      final item = (await itemsOf(saleId)).single;

      await expectLater(
        sales.submitReturn(
          saleId: saleId,
          items: [line(item, 3)],
          refundAmount: Decimal.zero,
          refundMethod: null,
          reason: ReturnReason.other,
        ),
        throwsA(
          isA<SaleReturnException>()
              .having((e) => e.code, 'code', 'return_exceeds_sold'),
        ),
      );
      expect(await db.select(db.saleReturnsTable).get(), isEmpty);
      expect(await lotQty('a-1'), 8);
      expect((await sale(saleId)).status, 'completed');

      // Cumulative: 1 back, then 2 more is one too many.
      await sales.submitReturn(
        saleId: saleId,
        items: [line(item, 1)],
        refundAmount: Decimal.zero,
        refundMethod: null,
        reason: ReturnReason.other,
      );
      await expectLater(
        sales.submitReturn(
          saleId: saleId,
          items: [line(item, 2)],
          refundAmount: Decimal.zero,
          refundMethod: null,
          reason: ReturnReason.other,
        ),
        throwsA(
          isA<SaleReturnException>()
              .having((e) => e.code, 'code', 'return_exceeds_sold'),
        ),
      );
    });

    test('status goes partially_returned then refunded; legacy refund refused',
        () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final b = await seed('b', [(lotId: 'b-1', qty: '10', cost: '800')]);
      final saleId = await sell([(a, 1), (b, 1)]);
      final items = await itemsOf(saleId);

      await sales.submitReturn(
        saleId: saleId,
        items: [line(items[0], 1)],
        refundAmount: Decimal.parse('1200'),
        refundMethod: RefundMethod.mobileMoney,
        reason: ReturnReason.changedMind,
      );
      expect((await sale(saleId)).status, 'partially_returned');
      // The whole-sale refund path is disjoint from returns (docs/19 §13.3).
      await expectLater(
        sales.refund(saleId: saleId, ownerChallengeToken: null),
        throwsA(isA<StateError>()),
      );

      await sales.submitReturn(
        saleId: saleId,
        items: [line(items[1], 1)],
        refundAmount: Decimal.parse('1200'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.changedMind,
      );
      expect((await sale(saleId)).status, 'refunded');
      await expectLater(
        sales.submitReturn(
          saleId: saleId,
          items: [line(items[1], 1)],
          refundAmount: Decimal.zero,
          refundMethod: null,
          reason: ReturnReason.other,
        ),
        throwsA(
          isA<SaleReturnException>()
              .having((e) => e.code, 'code', 'already_refunded'),
        ),
      );
    });

    test('refund_amount must lie within [0, credit]', () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final saleId = await sell([(a, 1)]);
      final item = (await itemsOf(saleId)).single;
      for (final bad in ['1200.01', '-1']) {
        await expectLater(
          sales.submitReturn(
            saleId: saleId,
            items: [line(item, 1)],
            refundAmount: Decimal.parse(bad),
            refundMethod: RefundMethod.cash,
            reason: ReturnReason.other,
          ),
          throwsA(
            isA<SaleReturnException>()
                .having((e) => e.code, 'code', 'invalid_payload'),
          ),
        );
      }
      final res = await sales.submitReturn(
        saleId: saleId,
        items: [line(item, 1)],
        refundAmount: Decimal.parse('1200'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.other,
      );
      expect(res.refundAmount, Decimal.parse('1200'));
    });

    test('a sale-level discount is shared proportionally', () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      // 2 × 1200 = 2400, 10% off → ratio 0.9 → 1080 credit per unit.
      final saleId = await sell([(a, 2)], discount: Decimal.parse('240'));
      final item = (await itemsOf(saleId)).single;
      final calc = await sales.returnCalculator(saleId);
      expect(calc.creditUnitSantim(120000), 108000);

      final res = await sales.submitReturn(
        saleId: saleId,
        items: [line(item, 1)],
        refundAmount: Decimal.parse('1080'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.other,
      );
      expect(res.credit, Decimal.parse('1080'));
      final row = (await db.select(db.saleReturnItemsTable).get()).single;
      expect(row.unitPrice, 108000);
    });

    test('credit rounds half up to the santim like the server', () {
      // 1000 × (2/3): 666.666… → 666.67; 1 × (1/8) → 0.125 → 0.13.
      const c = ReturnCreditCalculator(
        subtotalSantim: 300000,
        effectiveTotalSantim: 200000,
      );
      expect(c.creditUnitSantim(100000), 66667);
      const half = ReturnCreditCalculator(
        subtotalSantim: 800,
        effectiveTotalSantim: 100,
      );
      expect(half.creditUnitSantim(100), 13);
      // Ratio is capped at 1 and a zero-subtotal sale credits in full.
      const over = ReturnCreditCalculator(
        subtotalSantim: 100,
        effectiveTotalSantim: 500,
      );
      expect(over.creditUnitSantim(777), 777);
      const zero = ReturnCreditCalculator(
        subtotalSantim: 0,
        effectiveTotalSantim: 0,
      );
      expect(zero.creditUnitSantim(50), 50);
    });
  });

  group('exchange', () {
    test("credit becomes the new sale's discount, events sale-first",
        () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final b = await seed(
        'b',
        [(lotId: 'b-1', qty: '10', cost: '800')],
        price: '1500',
      );
      final original = await sell([(a, 1)]);
      final item = (await itemsOf(original)).single;

      final res = await sales.submitExchange(
        originalSaleId: original,
        returnItems: [line(item, 1)],
        reason: ReturnReason.wrongSize,
        cart: Cart.empty().add(b),
        paymentMethod: PaymentMethod.cash,
        refundMethod: RefundMethod.cash,
      );
      expect(res.credit, Decimal.parse('1200'));
      expect(res.refundAmount, Decimal.zero);
      final replacement = await sale(res.exchangeSaleId!);
      expect(replacement.subtotal, 150000);
      expect(replacement.discount, 120000);
      expect(replacement.total, 30000); // customer tops up 300
      expect((await sale(original)).status, 'refunded');
      final ret = (await db.select(db.saleReturnsTable).get()).single;
      expect(ret.exchangeSaleId, res.exchangeSaleId);
      expect(ret.refundMethod, isNull);

      final evs = await events();
      expect(
        evs.map((e) => e.op).toList(),
        ['sale.create', 'sale.create', 'sale.return'],
      );
      final retPayload = jsonDecode(evs.last.payload) as Map<String, dynamic>;
      expect(retPayload['exchange_sale_id'], res.exchangeSaleId);
      expect(retPayload['refund_amount'], '0');
      expect(retPayload['refund_method'], isNull);

      expect(await stockOf(a.id), Decimal.fromInt(10));
      expect(await stockOf(b.id), Decimal.fromInt(9));
    });

    test('cheaper replacement refunds the difference', () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final c = await seed(
        'c',
        [(lotId: 'c-1', qty: '10', cost: '500')],
        price: '1000',
      );
      final original = await sell([(a, 1)]);
      final item = (await itemsOf(original)).single;

      final res = await sales.submitExchange(
        originalSaleId: original,
        returnItems: [line(item, 1)],
        reason: ReturnReason.changedMind,
        cart: Cart.empty().add(c),
        paymentMethod: PaymentMethod.cash,
        refundMethod: RefundMethod.mobileMoney,
      );
      expect(res.refundAmount, Decimal.parse('200'));
      final replacement = await sale(res.exchangeSaleId!);
      expect(replacement.discount, 100000);
      expect(replacement.total, 0);
      final ret = (await db.select(db.saleReturnsTable).get()).single;
      expect(ret.refundAmount, 20000);
      expect(ret.refundMethod, 'mobile_money');
    });

    test('returning an exchanged item credits its full price (effective_total)',
        () async {
      final a = await seed(
        'a',
        [(lotId: 'a-1', qty: '10', cost: '800')],
        price: '1500',
      );
      final b = await seed(
        'b',
        [(lotId: 'b-1', qty: '10', cost: '800')],
        price: '1500',
      );
      final original = await sell([(a, 1)]);
      final item = (await itemsOf(original)).single;

      // Even exchange: replacement sale total 0, discount 1500.
      final ex = await sales.submitExchange(
        originalSaleId: original,
        returnItems: [line(item, 1)],
        reason: ReturnReason.wrongSize,
        cart: Cart.empty().add(b),
        paymentMethod: PaymentMethod.cash,
        refundMethod: RefundMethod.cash,
      );
      final replacementId = ex.exchangeSaleId!;
      expect((await sale(replacementId)).total, 0);

      // total/subtotal would be 0; effective_total adds the 1500 credit back.
      final calc = await sales.returnCalculator(replacementId);
      expect(calc.effectiveTotalSantim, 150000);
      expect(calc.creditUnitSantim(150000), 150000);

      final replItem = (await itemsOf(replacementId)).single;
      final res = await sales.submitReturn(
        saleId: replacementId,
        items: [line(replItem, 1)],
        refundAmount: Decimal.parse('1500'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.changedMind,
      );
      expect(res.credit, Decimal.parse('1500'));
      expect((await sale(replacementId)).status, 'refunded');
      expect(await stockOf(b.id), Decimal.fromInt(10));
    });

    test('a failed return rolls the whole exchange back, pushing nothing',
        () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final b = await seed('b', [(lotId: 'b-1', qty: '10', cost: '800')]);
      final original = await sell([(a, 1)]);
      final item = (await itemsOf(original)).single;
      final salesBefore = (await db.select(db.salesTable).get()).length;
      final eventsBefore = (await events()).length;
      worker.reset();

      // Another device already took this unit back: the return fails after
      // the replacement sale has been written inside the same transaction.
      await expectLater(
        sales.submitExchange(
          originalSaleId: original,
          returnItems: [line(item, 2)],
          reason: ReturnReason.wrongSize,
          cart: Cart.empty().add(b),
          paymentMethod: PaymentMethod.cash,
          refundMethod: RefundMethod.cash,
        ),
        throwsA(
          isA<SaleReturnException>()
              .having((e) => e.code, 'code', 'return_exceeds_sold'),
        ),
      );

      // Nothing of the replacement sale survives…
      expect(await db.select(db.salesTable).get(), hasLength(salesBefore));
      expect((await events()).length, eventsBefore);
      expect(await db.select(db.saleReturnsTable).get(), isEmpty);
      expect(await stockOf(b.id), Decimal.fromInt(10));
      expect((await sale(original)).status, 'completed');
      // …and, decisively, no push was ever started: a kick inside the
      // transaction would have read the uncommitted sale.create off the open
      // transaction and POSTed a sale no device would then know about.
      expect(worker.kicks, 0);
    });

    test('a successful exchange kicks exactly once, after the commit',
        () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final b = await seed('b', [(lotId: 'b-1', qty: '10', cost: '800')]);
      final original = await sell([(a, 1)]);
      final item = (await itemsOf(original)).single;
      worker.reset();

      await sales.submitExchange(
        originalSaleId: original,
        returnItems: [line(item, 1)],
        reason: ReturnReason.wrongSize,
        cart: Cart.empty().add(b),
        paymentMethod: PaymentMethod.cash,
        refundMethod: RefundMethod.cash,
      );

      // One kick for the pair (not one per inner write), and outside the
      // transaction, so it can only ever see committed rows.
      expect(worker.kicksInsideTransaction, [false]);
    });

    group('cashier haggling below the floor', () {
      late SalesRepository cashier;

      setUp(() {
        // isOwner defaults to false — this is the cashier's repository.
        cashier = SalesRepository(
          db: db,
          syncWorker: worker,
          currentUserId: userId,
          currentShopId: shopId,
          currentShiftId: 'shift-1',
          hasLinePricing: true,
        );
      });

      /// A replacement priced under its floor, so `sale.create` resolves a
      /// challenge of its own on top of the always-sensitive `sale.return`.
      Future<({String original, Cart cart})> setUpBelowFloorExchange() async {
        final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
        final b = await seed('b', [(lotId: 'b-1', qty: '10', cost: '800')]);
        final floored = Product(
          id: b.id,
          shopId: b.shopId,
          name: b.name,
          purchasePrice: b.purchasePrice,
          sellingPrice: b.sellingPrice,
          stock: b.stock,
          lowStockThreshold: b.lowStockThreshold,
          unit: b.unit,
          styleId: b.styleId,
          minSellingPrice: Decimal.parse('1100'),
        );
        await db.productsDao.upsertAll([floored]);
        final original = await sell([(a, 1)]);
        return (
          original: original,
          cart: Cart.empty()
              .add(floored)
              .setUnitPrice(floored.id, Decimal.parse('900')),
        );
      }

      test('the two events carry two distinct challenges', () async {
        final setUpResult = await setUpBelowFloorExchange();
        final item = (await itemsOf(setUpResult.original)).single;

        await cashier.submitExchange(
          originalSaleId: setUpResult.original,
          returnItems: [line(item, 1)],
          reason: ReturnReason.wrongSize,
          cart: setUpResult.cart,
          paymentMethod: PaymentMethod.cash,
          refundMethod: RefundMethod.cash,
          ownerChallengeToken: 'tok-sale',
          returnOwnerChallengeToken: 'tok-return',
        );

        final evs = await events();
        expect(
          evs.map((e) => e.op).toList(),
          ['sale.create', 'sale.create', 'sale.return'],
        );
        Map<String, dynamic> payload(int i) =>
            jsonDecode(evs[i].payload) as Map<String, dynamic>;
        // A challenge is single-use server-side: one token on both events
        // would have the sale spend it and the return bounce with
        // `owner_pin_required`, dead-lettering half an exchange.
        expect(payload(1)['owner_challenge'], 'tok-sale');
        expect(payload(2)['owner_challenge'], 'tok-return');
      });

      test('a missing return challenge aborts before anything is written',
          () async {
        final setUpResult = await setUpBelowFloorExchange();
        final item = (await itemsOf(setUpResult.original)).single;
        final before = (await events()).length;

        await expectLater(
          cashier.submitExchange(
            originalSaleId: setUpResult.original,
            returnItems: [line(item, 1)],
            reason: ReturnReason.wrongSize,
            cart: setUpResult.cart,
            paymentMethod: PaymentMethod.cash,
            refundMethod: RefundMethod.cash,
            ownerChallengeToken: 'tok-sale',
          ),
          throwsA(
            isA<SaleReturnException>()
                .having((e) => e.code, 'code', 'owner_pin_required'),
          ),
        );
        expect((await events()).length, before);
        expect(await db.select(db.saleReturnsTable).get(), isEmpty);
        expect((await sale(setUpResult.original)).status, 'completed');
      });

      test('a missing sale challenge still refuses the below-floor line',
          () async {
        final setUpResult = await setUpBelowFloorExchange();
        final item = (await itemsOf(setUpResult.original)).single;
        final before = (await events()).length;

        await expectLater(
          cashier.submitExchange(
            originalSaleId: setUpResult.original,
            returnItems: [line(item, 1)],
            reason: ReturnReason.wrongSize,
            cart: setUpResult.cart,
            paymentMethod: PaymentMethod.cash,
            refundMethod: RefundMethod.cash,
            returnOwnerChallengeToken: 'tok-return',
          ),
          throwsA(isA<BelowPriceFloorException>()),
        );
        expect((await events()).length, before);
        expect(await db.select(db.saleReturnsTable).get(), isEmpty);
      });
    });
  });

  group('wire and sync', () {
    test('sale.return payload matches docs/19 §13.3 exactly', () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final saleId = await sell([(a, 2)]);
      final item = (await itemsOf(saleId)).single;
      final res = await sales.submitReturn(
        saleId: saleId,
        items: [
          line(item, 1),
          line(item, 1, ReturnCondition.damaged),
        ],
        refundAmount: Decimal.parse('2400'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.wrongSize,
        note: 'too tight',
        ownerChallengeToken: 'tok-1',
      );

      final ev = (await events()).last;
      expect(ev.op, 'sale.return');
      final p = jsonDecode(ev.payload) as Map<String, dynamic>;
      expect(
        p.keys.toSet(),
        {
          'id',
          'sale_id',
          'shift_id',
          'occurred_at',
          'items',
          'refund_amount',
          'refund_method',
          'exchange_sale_id',
          'reason',
          'note',
          'owner_challenge',
        },
      );
      expect(p['id'], res.returnId);
      expect(p['sale_id'], saleId);
      expect(p['shift_id'], 'shift-1');
      expect(DateTime.parse(p['occurred_at'] as String).isUtc, isTrue);
      expect(p['refund_amount'], '2400');
      expect(p['refund_method'], 'cash');
      expect(p['exchange_sale_id'], isNull);
      expect(p['reason'], 'wrong_size');
      expect(p['note'], 'too tight');
      expect(p['owner_challenge'], 'tok-1');
      final items = (p['items'] as List).cast<Map<String, dynamic>>();
      expect(items, hasLength(2));
      for (final it in items) {
        expect(
          it.keys.toSet(),
          {'id', 'sale_item_id', 'quantity', 'condition'},
        );
        expect(it['sale_item_id'], item.id);
        expect(it['quantity'], '1');
      }
      expect(items.map((i) => i['condition']), ['resellable', 'damaged']);
      // The local mirror rows carry the same ids as the wire.
      final rows = await db.select(db.saleReturnItemsTable).get();
      expect(rows.map((r) => r.id).toSet(), items.map((i) => i['id']).toSet());
    });

    test('pending sale.return marks its products as locally ahead', () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final saleId = await sell([(a, 1)]);
      // Drop the sale.create so only the return is pending.
      await (db.delete(db.syncEventsTable)
            ..where((t) => t.op.equals('sale.create')))
          .go();
      final item = (await itemsOf(saleId)).single;
      await sales.submitReturn(
        saleId: saleId,
        items: [line(item, 1)],
        refundAmount: Decimal.zero,
        refundMethod: null,
        reason: ReturnReason.other,
      );
      expect(await productIdsWithPendingChanges(db), {a.id});
    });

    test('submitReturn kicks once, after the commit', () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final saleId = await sell([(a, 1)]);
      final item = (await itemsOf(saleId)).single;
      worker.reset();

      await sales.submitReturn(
        saleId: saleId,
        items: [line(item, 1)],
        refundAmount: Decimal.parse('1200'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.other,
      );
      expect(worker.kicksInsideTransaction, [false]);
    });

    test('a cashier return without an owner challenge is refused', () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final saleId = await sell([(a, 1)]);
      final item = (await itemsOf(saleId)).single;
      final cashier = SalesRepository(
        db: db,
        syncWorker: worker,
        currentUserId: userId,
        currentShopId: shopId,
        currentShiftId: 'shift-1',
      );
      final eventsBefore = (await events()).length;

      // `sale.return` is a SENSITIVE_OP: the rule lives in the repository,
      // not only in the screen that happens to collect the PIN.
      await expectLater(
        cashier.submitReturn(
          saleId: saleId,
          items: [line(item, 1)],
          refundAmount: Decimal.parse('1200'),
          refundMethod: RefundMethod.cash,
          reason: ReturnReason.other,
        ),
        throwsA(
          isA<SaleReturnException>()
              .having((e) => e.code, 'code', 'owner_pin_required'),
        ),
      );
      expect(await db.select(db.saleReturnsTable).get(), isEmpty);
      expect((await events()).length, eventsBefore);

      // With a challenge the same return goes through.
      await cashier.submitReturn(
        saleId: saleId,
        items: [line(item, 1)],
        refundAmount: Decimal.parse('1200'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.other,
        ownerChallengeToken: 'tok-1',
      );
      expect(await db.select(db.saleReturnsTable).get(), hasLength(1));
    });

    test('a discarded sale.return is undone and the sale status restored',
        () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final saleId = await sell([(a, 2)]);
      final item = (await itemsOf(saleId)).single;
      final res = await sales.submitReturn(
        saleId: saleId,
        items: [line(item, 1)],
        refundAmount: Decimal.parse('1200'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.other,
      );
      expect((await sale(saleId)).status, 'partially_returned');

      final rec = SyncReconciler(
        db: db,
        shopId: () => shopId,
        refreshProducts: () async {},
        refreshLots: () async {},
        refreshDebts: () async {},
        refreshExpenses: () async {},
        refreshSupplies: () async {},
        refreshStyles: () async {},
      );
      final domains = await rec.onLocalDiscarded('sale.return', {
        'id': res.returnId,
        'sale_id': saleId,
      });

      // Left behind, the phantom rows would keep that unit un-returnable,
      // keep `refund()` refusing the sale and (for an exchange) inflate the
      // credit ratio of every later return.
      expect(await db.select(db.saleReturnsTable).get(), isEmpty);
      expect(await db.select(db.saleReturnItemsTable).get(), isEmpty);
      expect(await db.saleReturnsDao.returnedQtyBySaleItem(saleId), isEmpty);
      expect((await sale(saleId)).status, 'completed');
      // Stock and lots come back from the snapshot refresh.
      expect(domains, {SyncDomain.products, SyncDomain.lots});
    });

    test('a partly-undone sale keeps its partially_returned status', () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final saleId = await sell([(a, 3)]);
      final item = (await itemsOf(saleId)).single;
      final kept = await sales.submitReturn(
        saleId: saleId,
        items: [line(item, 1)],
        refundAmount: Decimal.parse('1200'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.other,
      );
      final discarded = await sales.submitReturn(
        saleId: saleId,
        items: [line(item, 1)],
        refundAmount: Decimal.parse('1200'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.other,
      );
      final rec = SyncReconciler(
        db: db,
        shopId: () => shopId,
        refreshProducts: () async {},
        refreshLots: () async {},
        refreshDebts: () async {},
        refreshExpenses: () async {},
        refreshSupplies: () async {},
        refreshStyles: () async {},
      );
      await rec.onLocalDiscarded('sale.return', {
        'id': discarded.returnId,
        'sale_id': saleId,
      });

      final returns = await db.select(db.saleReturnsTable).get();
      expect(returns.map((r) => r.id), [kept.returnId]);
      expect((await sale(saleId)).status, 'partially_returned');
    });

    test('reconciler mirrors a foreign sale.return once and sets status',
        () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final saleId = await sell([(a, 2)], discount: Decimal.parse('240'));
      final item = (await itemsOf(saleId)).single;
      final rec = SyncReconciler(
        db: db,
        shopId: () => shopId,
        refreshProducts: () async {},
        refreshLots: () async {},
        refreshDebts: () async {},
        refreshExpenses: () async {},
        refreshSupplies: () async {},
        refreshStyles: () async {},
      );
      final payload = {
        'id': 'ret-remote-1',
        'sale_id': saleId,
        'shift_id': null,
        'occurred_at': '2026-09-16T10:00:00Z',
        'items': [
          {
            'id': 'ri-1',
            'sale_item_id': item.id,
            'quantity': '1',
            'condition': 'damaged',
          },
        ],
        'refund_amount': '1080',
        'refund_method': 'cash',
        'exchange_sale_id': null,
        'reason': 'defect',
        'note': null,
      };
      for (var i = 0; i < 2; i++) {
        await rec.applyRemoteEvent(
          op: 'sale.return',
          payload: payload,
          userId: 'other-user',
          occurredAt: DateTime.utc(2026, 9, 16, 10),
        );
      }
      final returns = await db.select(db.saleReturnsTable).get();
      expect(returns, hasLength(1));
      expect(returns.single.userId, 'other-user');
      expect(returns.single.refundAmount, 108000);
      final rows = await db.select(db.saleReturnItemsTable).get();
      expect(rows, hasLength(1));
      expect(rows.single.unitPrice, 108000); // proportional credit
      expect(rows.single.condition, 'damaged');
      expect((await sale(saleId)).status, 'partially_returned');
      // Stock/lots converge via the snapshot refresh, not here.
      expect(await lotQty('a-1'), 8);
      expect(
        SyncReconciler.domainsForOp('sale.return', payload),
        {SyncDomain.products, SyncDomain.lots},
      );

      // A second foreign return for the remaining unit flips it to refunded.
      await rec.applyRemoteEvent(
        op: 'sale.return',
        payload: {
          ...payload,
          'id': 'ret-remote-2',
          'items': [
            {
              'id': 'ri-2',
              'sale_item_id': item.id,
              'quantity': '1',
              'condition': 'resellable',
            },
          ],
        },
        userId: 'other-user',
        occurredAt: DateTime.utc(2026, 9, 16, 11),
      );
      expect((await sale(saleId)).status, 'refunded');
    });

    test('two concurrent fetches of the same sale cache its returns once',
        () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final remote = _FakeRemote(
        RemoteSale(
          id: 'sale-from-phone-a',
          shiftId: null,
          userId: 'other-user',
          subtotal: Decimal.parse('2400'),
          discount: Decimal.zero,
          total: Decimal.parse('2400'),
          paymentMethod: 'cash',
          status: 'partially_returned',
          occurredAt: DateTime.utc(2026, 9, 10, 9),
          items: [
            RemoteSaleItem(
              id: 'si-1',
              productId: a.id,
              productNameSnapshot: a.name,
              quantity: Decimal.fromInt(2),
              unitPrice: Decimal.parse('1200'),
              listPrice: null,
              returnedQuantity: Decimal.one,
            ),
          ],
          returns: [
            RemoteSaleReturn(
              id: 'ret-earlier',
              userId: 'other-user',
              shiftId: null,
              occurredAt: DateTime.utc(2026, 9, 11, 9),
              refundAmount: Decimal.parse('1200'),
              refundMethod: 'cash',
              exchangeSaleId: null,
              reason: ReturnReason.defect,
              note: null,
              // No line id: the cache must derive a deterministic one, or
              // insertOrIgnore cannot dedupe.
              items: [
                RemoteSaleReturnItem(
                  id: null,
                  saleItemId: 'si-1',
                  quantity: Decimal.one,
                  condition: ReturnCondition.resellable,
                  unitPrice: Decimal.parse('1200'),
                ),
              ],
            ),
          ],
        ),
      );
      final online = SalesRepository(
        db: db,
        syncWorker: worker,
        currentUserId: userId,
        currentShopId: shopId,
        currentShiftId: null,
        isOwner: true,
        hasLinePricing: true,
        remote: remote,
      );

      // The screen and the return sheet can both ask before either caches.
      await Future.wait([
        online.receiptData('sale-from-phone-a'),
        online.receiptData('sale-from-phone-a'),
      ]);
      expect(remote.calls, 2);

      // One line, so the unit counts once: a doubled row would make the
      // already-returned unit un-returnable and double the exchange credit.
      expect(await db.select(db.saleReturnItemsTable).get(), hasLength(1));
      expect(
        await db.saleReturnsDao.returnedQtyBySaleItem('sale-from-phone-a'),
        {'si-1': Decimal.one},
      );
    });

    test('a sale unknown locally is fetched, cached synced and returnable',
        () async {
      final a = await seed('a', [(lotId: 'a-1', qty: '10', cost: '800')]);
      final remote = _FakeRemote(
        RemoteSale(
          id: 'sale-from-phone-a',
          shiftId: null,
          userId: 'other-user',
          subtotal: Decimal.parse('2400'),
          discount: Decimal.zero,
          total: Decimal.parse('2400'),
          paymentMethod: 'cash',
          status: 'partially_returned',
          occurredAt: DateTime.utc(2026, 9, 10, 9),
          items: [
            RemoteSaleItem(
              id: 'si-1',
              productId: a.id,
              productNameSnapshot: a.name,
              quantity: Decimal.fromInt(2),
              unitPrice: Decimal.parse('1200'),
              listPrice: Decimal.parse('1300'),
              returnedQuantity: Decimal.one,
            ),
          ],
          returns: [
            RemoteSaleReturn(
              id: 'ret-earlier',
              userId: 'other-user',
              shiftId: null,
              occurredAt: DateTime.utc(2026, 9, 11, 9),
              refundAmount: Decimal.parse('1200'),
              refundMethod: 'cash',
              exchangeSaleId: null,
              reason: ReturnReason.defect,
              note: null,
              items: [
                RemoteSaleReturnItem(
                  // Older servers send no line id; the cache derives one.
                  id: null,
                  saleItemId: 'si-1',
                  quantity: Decimal.one,
                  condition: ReturnCondition.resellable,
                  unitPrice: Decimal.parse('1200'),
                ),
              ],
            ),
          ],
        ),
      );
      final online = SalesRepository(
        db: db,
        syncWorker: worker,
        currentUserId: userId,
        currentShopId: shopId,
        currentShiftId: null,
        isOwner: true,
        hasLinePricing: true,
        remote: remote,
      );

      expect(await online.receiptData('nope'), isNull);
      final data = (await online.receiptData('sale-from-phone-a'))!;
      expect(data.items.single.returnedQuantity, 1);
      expect(data.items.single.listPrice, Decimal.parse('1300'));
      expect(data.returns, hasLength(1));
      expect(data.isPartiallyReturned, isTrue);
      final cached = await sale('sale-from-phone-a');
      expect(cached.synced, isTrue);
      expect(cached.status, 'partially_returned');
      // Second read is local — no refetch.
      await online.receiptData('sale-from-phone-a');
      expect(remote.calls, 2);

      // Only the remaining unit can come back; the earlier return counts.
      await expectLater(
        online.submitReturn(
          saleId: 'sale-from-phone-a',
          items: [
            ReturnLine(
              saleItemId: 'si-1',
              quantity: Decimal.fromInt(2),
              condition: ReturnCondition.resellable,
            ),
          ],
          refundAmount: Decimal.zero,
          refundMethod: null,
          reason: ReturnReason.other,
        ),
        throwsA(
          isA<SaleReturnException>()
              .having((e) => e.code, 'code', 'return_exceeds_sold'),
        ),
      );
      final res = await online.submitReturn(
        saleId: 'sale-from-phone-a',
        items: [
          ReturnLine(
            saleItemId: 'si-1',
            quantity: Decimal.one,
            condition: ReturnCondition.resellable,
          ),
        ],
        refundAmount: Decimal.parse('1200'),
        refundMethod: RefundMethod.cash,
        reason: ReturnReason.other,
      );
      expect(res.credit, Decimal.parse('1200'));
      expect((await sale('sale-from-phone-a')).status, 'refunded');
      // No lot was consumed on this device for that sale, so nothing to put
      // back on a lot — but the unit still counts towards stock.
      expect(await stockOf(a.id), Decimal.fromInt(11));
      expect(await consumptions('refund_reversal'), isEmpty);
      // Only the return is queued; the cached sale is never re-pushed.
      expect((await events()).map((e) => e.op), ['sale.return']);
    });
  });
}
