import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sales/data/sales_repository.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/sales/domain/entities/sale_return.dart';
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

/// Boutique variant with an explicit haggling floor.
final jeans = Product(
  id: 'jeans-32',
  shopId: shopId,
  name: 'Slim jeans · 32 · Blue',
  purchasePrice: Decimal.parse('800'),
  sellingPrice: Decimal.parse('1200'),
  minSellingPrice: Decimal.parse('1000'),
  stock: Decimal.parse('10'),
  lowStockThreshold: Decimal.one,
  unit: 'piece',
  styleId: 'style-1',
  size: '32',
  color: 'Blue',
);

/// No floor set: any discount at all is the owner's call.
final belt = Product(
  id: 'belt',
  shopId: shopId,
  name: 'Belt',
  purchasePrice: Decimal.parse('200'),
  sellingPrice: Decimal.parse('500'),
  stock: Decimal.parse('10'),
  lowStockThreshold: Decimal.one,
  unit: 'piece',
);

void main() {
  group('CartLine / Cart pricing', () {
    test('unitPrice defaults to the list price and drives the totals', () {
      final line = CartLine(product: jeans, qty: Decimal.fromInt(2));
      expect(line.unitPrice, Decimal.parse('1200'));
      expect(line.listPrice, Decimal.parse('1200'));
      expect(line.lineTotal, Decimal.parse('2400'));
      expect(line.hasLineDiscount, isFalse);
      expect(line.isBelowFloor, isFalse);

      final cart = Cart.empty()
          .add(jeans, qty: Decimal.fromInt(2))
          .setUnitPrice(jeans.id, Decimal.parse('1100'));
      expect(cart.lines.single.unitPrice, Decimal.parse('1100'));
      expect(cart.lines.single.lineTotal, Decimal.parse('2200'));
      expect(cart.subtotal, Decimal.parse('2200'));
      expect(cart.lines.single.hasLineDiscount, isTrue);
      // 1100 ≥ floor 1000: no owner needed.
      expect(cart.linesBelowFloor, isEmpty);
    });

    test('negotiated price survives quantity edits and cart copies', () {
      final cart = Cart.empty()
          .add(jeans)
          .setUnitPrice(jeans.id, Decimal.parse('950'))
          .setQty(jeans.id, Decimal.fromInt(3))
          .add(belt)
          .setDiscount(Decimal.fromInt(10));
      final jeansLine = cart.lines.firstWhere((l) => l.product.id == jeans.id);
      expect(jeansLine.unitPrice, Decimal.parse('950'));
      expect(jeansLine.qty, Decimal.fromInt(3));
      expect(jeansLine.isBelowFloor, isTrue);
      expect(cart.linesBelowFloor.map((l) => l.product.id), ['jeans-32']);
    });

    test('floor is the list price when no minimum is set', () {
      final full = Cart.empty().add(belt);
      expect(full.lines.single.floorPrice, Decimal.parse('500'));
      expect(full.lines.single.isBelowFloor, isFalse);
      final haggled = full.setUnitPrice(belt.id, Decimal.parse('450'));
      expect(haggled.lines.single.isBelowFloor, isTrue);
    });

    test('negative prices are refused', () {
      final cart = Cart.empty().add(belt);
      expect(
        () => cart.setUnitPrice(belt.id, Decimal.parse('-1')),
        throwsArgumentError,
      );
      // Zero is a legitimate giveaway.
      expect(cart.setUnitPrice(belt.id, Decimal.zero).subtotal, Decimal.zero);
    });
  });

  group('SalesRepository floor pre-flight and persistence', () {
    late AppDatabase db;
    late _NoopSyncWorker worker;

    SalesRepository repo({required bool isOwner, bool hasLinePricing = true}) =>
        SalesRepository(
          db: db,
          syncWorker: worker,
          currentUserId: isOwner ? 'owner-1' : 'cashier-1',
          currentShopId: shopId,
          currentShiftId: null,
          isOwner: isOwner,
          hasLinePricing: hasLinePricing,
        );

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      worker = _NoopSyncWorker(db);
      await db.productsDao.upsertAll([jeans, belt]);
    });

    tearDown(() => db.close());

    Future<int> saleCount() async =>
        (await db.select(db.salesTable).get()).length;

    test('cashier below the explicit floor is stopped before any write',
        () async {
      final cart =
          Cart.empty().add(jeans).setUnitPrice(jeans.id, Decimal.parse('900'));
      final cashier = repo(isOwner: false);
      expect(cashier.pricingNeedsOwnerApproval(cart), isTrue);
      await expectLater(
        cashier.submit(cart: cart, paymentMethod: PaymentMethod.cash),
        throwsA(
          isA<BelowPriceFloorException>().having(
            (e) => e.productNames,
            'productNames',
            ['Slim jeans · 32 · Blue'],
          ),
        ),
      );
      expect(await saleCount(), 0);
      expect(await db.select(db.syncEventsTable).get(), isEmpty);
      expect(
        (await db.productsDao.getById(jeans.id))!.stock,
        Decimal.parse('10'),
      );
    });

    test('owner below the floor goes through (server audits, not gates)',
        () async {
      final cart =
          Cart.empty().add(jeans).setUnitPrice(jeans.id, Decimal.parse('900'));
      final owner = repo(isOwner: true);
      expect(owner.pricingNeedsOwnerApproval(cart), isFalse);
      await owner.submit(cart: cart, paymentMethod: PaymentMethod.cash);
      expect(await saleCount(), 1);
    });

    test('no floor and no discount passes for a cashier', () async {
      final cart = Cart.empty().add(belt);
      await repo(isOwner: false)
          .submit(cart: cart, paymentMethod: PaymentMethod.cash);
      expect(await saleCount(), 1);
    });

    test('no floor but a declared discount needs the owner', () async {
      final cart =
          Cart.empty().add(belt).setUnitPrice(belt.id, Decimal.parse('450'));
      await expectLater(
        repo(isOwner: false)
            .submit(cart: cart, paymentMethod: PaymentMethod.cash),
        throwsA(isA<BelowPriceFloorException>()),
      );
    });

    test('floor set and priced above it passes for a cashier', () async {
      final cart =
          Cart.empty().add(jeans).setUnitPrice(jeans.id, Decimal.parse('1000'));
      await repo(isOwner: false)
          .submit(cart: cart, paymentMethod: PaymentMethod.cash);
      expect(await saleCount(), 1);
    });

    test('the rule is off for shops without line pricing', () async {
      final cart =
          Cart.empty().add(jeans).setUnitPrice(jeans.id, Decimal.parse('900'));
      await repo(isOwner: false, hasLinePricing: false)
          .submit(cart: cart, paymentMethod: PaymentMethod.cash);
      expect(await saleCount(), 1);
    });

    test('an owner challenge lets the cashier through and rides the payload',
        () async {
      final cart =
          Cart.empty().add(jeans).setUnitPrice(jeans.id, Decimal.parse('900'));
      await repo(isOwner: false).submit(
        cart: cart,
        paymentMethod: PaymentMethod.cash,
        ownerChallengeToken: 'tok-123',
      );
      final ev = (await db.select(db.syncEventsTable).get()).single;
      final payload = jsonDecode(ev.payload) as Map<String, dynamic>;
      expect(payload['owner_challenge'], 'tok-123');
    });

    test('submit writes unit_price and list_price locally and on the wire',
        () async {
      final cart = Cart.empty()
          .add(jeans, qty: Decimal.fromInt(2))
          .setUnitPrice(jeans.id, Decimal.parse('1100'))
          .add(belt);
      final saleId = await repo(isOwner: false)
          .submit(cart: cart, paymentMethod: PaymentMethod.cash);

      final sale = await (db.select(db.salesTable)
            ..where((t) => t.id.equals(saleId)))
          .getSingle();
      // 2 × 1100 + 500, in santim.
      expect(sale.subtotal, 270000);
      expect(sale.total, 270000);

      final items = await (db.select(db.saleItemsTable)
            ..where((t) => t.saleId.equals(saleId)))
          .get();
      final jeansRow = items.firstWhere((i) => i.productId == jeans.id);
      final beltRow = items.firstWhere((i) => i.productId == belt.id);
      expect(jeansRow.unitPrice, 110000);
      expect(jeansRow.listPrice, 120000);
      expect(beltRow.unitPrice, 50000);
      expect(beltRow.listPrice, 50000);

      final ev = (await db.select(db.syncEventsTable).get()).single;
      expect(ev.op, 'sale.create');
      final payload = jsonDecode(ev.payload) as Map<String, dynamic>;
      final wireItems = (payload['items'] as List).cast<Map<String, dynamic>>();
      final wireJeans =
          wireItems.firstWhere((i) => i['product_id'] == jeans.id);
      expect(wireJeans['unit_price'], '1100');
      expect(wireJeans['list_price'], '1200');
      expect(wireJeans['quantity'], '2');
      expect(payload['subtotal'], '2700');
      expect(payload.containsKey('owner_challenge'), isFalse);

      // The receipt snapshot exposes the strike-through.
      final receipt = (await repo(isOwner: false).receiptData(saleId))!;
      final jeansItem =
          receipt.items.firstWhere((i) => i.productId == jeans.id);
      expect(jeansItem.hasLineDiscount, isTrue);
      expect(jeansItem.listPrice, Decimal.parse('1200'));
      expect(
        receipt.items.firstWhere((i) => i.productId == belt.id).hasLineDiscount,
        isFalse,
      );
    });
  });
}
