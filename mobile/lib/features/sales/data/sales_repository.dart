import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/utils/unit_conversion.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/domain/entities/recipe_item.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/shifts/data/shifts_repository.dart';
import 'package:suuqii/features/supplies/domain/entities/supply.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';
import 'package:uuid/uuid.dart';

part 'sales_repository.g.dart';

class SalesRepository {
  SalesRepository({
    required this.db,
    required this.syncWorker,
    required this.currentUserId,
    required this.currentShopId,
    required this.currentShiftId,
    this.isBakery = false,
    this.debtThreshold,
  });

  final AppDatabase db;
  final SyncWorker syncWorker;
  final String currentUserId;
  final String currentShopId;
  final String? currentShiftId;
  final bool isBakery;
  /// Mirrors Shop.debt_threshold from the server. Credit sales that would push
  /// a customer's cumulative outstanding above this value are blocked locally
  /// so the cashier gets immediate feedback rather than a deferred sync error.
  /// Defaults to 500 ETB when not provided.
  final Decimal? debtThreshold;

  /// Atomic local write: sale + items + stock decrement + inventory log
  /// + (optional) debt + sync event. Returns the persisted sale id.
  Future<String> submit({
    required Cart cart,
    required PaymentMethod paymentMethod,
    String? customerName,
    String? customerPhone,
    DateTime? dueDate,
  }) async {
    if (cart.isEmpty) {
      throw StateError('Cart is empty');
    }
    if (paymentMethod == PaymentMethod.credit &&
        (customerName == null || customerName.isEmpty)) {
      throw StateError('Credit sale needs a customer name');
    }
    for (final l in cart.lines) {
      if (l.qty <= Decimal.zero) {
        throw StateError('Invalid quantity for ${l.product.name}');
      }
      if (!isBakery && l.product.stock < l.qty) {
        throw StateError('Insufficient stock for ${l.product.name}');
      }
    }

    final saleId = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final shift = currentShiftId;
    final subtotal = cart.subtotal;
    final discount = cart.discount;
    final total = cart.total;
    final method = _paymentMethodKey(paymentMethod);

    // For bakery shops, cost_total is derived from ingredient supply costs
    // (supply.costPerUnit × qty consumed per recipe), not from product.purchasePrice
    // which is always 0. Pre-load recipes and supplies outside the transaction
    // so the same data can be reused in the supply deduction loop inside it.
    Map<String, List<RecipeItem>> cachedRecipes = {};
    Map<String, Supply?> cachedSupplies = {};
    final Map<String, Decimal> productUnitCosts = {};
    Decimal costTotal;

    if (isBakery) {
      final productIds = cart.lines.map((l) => l.product.id).toList();
      cachedRecipes = await db.recipesDao.getForProducts(productIds);
      final supplyIds = cachedRecipes.values
          .expand((items) => items.map((i) => i.supplyId))
          .toSet();
      for (final id in supplyIds) {
        cachedSupplies[id] = await db.suppliesDao.getById(id);
      }
      Decimal ingredientCostTotal = Decimal.zero;
      for (final line in cart.lines) {
        Decimal unitCost = Decimal.zero;
        for (final item in cachedRecipes[line.product.id] ?? <RecipeItem>[]) {
          final supply = cachedSupplies[item.supplyId];
          final supplyUnit = supply?.unit;
          final costPerUnit = supply?.costPerUnit ?? Decimal.zero;
          final effectiveUnit = item.recipeUnit ?? supplyUnit ?? 'piece';
          final qtyPerUnit = supplyUnit != null
              ? convertUnit(item.quantity, effectiveUnit, supplyUnit)
              : item.quantity;
          unitCost += costPerUnit * qtyPerUnit;
        }
        productUnitCosts[line.product.id] = unitCost;
        ingredientCostTotal += unitCost * line.qty;
      }
      costTotal = ingredientCostTotal;
    } else {
      costTotal = cart.costTotal;
    }

    final itemsPayload = <Map<String, dynamic>>[];

    await db.transaction(() async {
      await db.into(db.salesTable).insert(
            SalesTableCompanion.insert(
              id: saleId,
              shopId: currentShopId,
              shiftId: Value(shift),
              userId: currentUserId,
              subtotal: subtotal.toDouble(),
              discount: Value(discount.toDouble()),
              total: total.toDouble(),
              costTotal: costTotal.toDouble(),
              paymentMethod: method,
              occurredAt: now,
              synced: const Value(false),
            ),
          );

      for (final line in cart.lines) {
        final itemId = const Uuid().v4();
        final lineUnitCost = isBakery
            ? (productUnitCosts[line.product.id] ?? Decimal.zero)
            : line.product.purchasePrice;
        await db.into(db.saleItemsTable).insert(
              SaleItemsTableCompanion.insert(
                id: itemId,
                saleId: saleId,
                productId: line.product.id,
                productNameSnapshot: line.product.name,
                quantity: line.qty.toDouble(),
                unitPrice: line.product.sellingPrice.toDouble(),
                unitCost: lineUnitCost.toDouble(),
              ),
            );

        // stock delta + ledger. Skipped for bakery — ingredient supplies are
        // the inventory unit; product stock is not tracked per-sale.
        if (!isBakery) {
          await db.customUpdate(
            'UPDATE products SET stock = stock - ?, updated_at = ? WHERE id = ?',
            variables: [
              Variable.withReal(line.qty.toDouble()),
              Variable.withInt(sqliteDateTimeParam(now)),
              Variable.withString(line.product.id),
            ],
            updates: {db.productsTable},
            updateKind: UpdateKind.update,
          );
        }
        if (!isBakery) {
          await db.into(db.inventoryLogsTable).insert(
                InventoryLogsTableCompanion.insert(
                  id: const Uuid().v4(),
                  shopId: currentShopId,
                  productId: line.product.id,
                  movement: 'sale',
                  quantityDelta: -line.qty.toDouble(),
                  referenceType: const Value('sale'),
                  referenceId: Value(saleId),
                  userId: Value(currentUserId),
                ),
              );
        }

        itemsPayload.add({
          'id': itemId,
          'product_id': line.product.id,
          'product_name_snapshot': line.product.name,
          'quantity': line.qty.toString(),
          'unit_price': line.product.sellingPrice.toString(),
          'unit_cost': lineUnitCost.toString(),
        });
      }

      // Bakery: deduct ingredient supplies consumed by this sale.
      // Reuses cachedRecipes and cachedSupplies pre-loaded above.
      final supplyDeductionsPayload = <Map<String, dynamic>>[];
      if (isBakery) {
        for (final line in cart.lines) {
          for (final item in cachedRecipes[line.product.id] ?? <RecipeItem>[]) {
            final supply = cachedSupplies[item.supplyId];
            final supplyUnit = supply?.unit;
            final effectiveUnit = item.recipeUnit ?? supplyUnit ?? 'piece';
            // Convert recipe quantity to supply's storage unit before deducting.
            // e.g. recipe says 100g flour, supply tracked in kg → deduct 0.1 kg.
            final qtyInSupplyUnit = supplyUnit != null
                ? convertUnit(item.quantity * line.qty, effectiveUnit, supplyUnit)
                : item.quantity * line.qty;
            final delta = -qtyInSupplyUnit;
            await db.suppliesDao.applyDelta(item.supplyId, delta);
            supplyDeductionsPayload.add({
              'supply_id': item.supplyId,
              'quantity_delta': delta.toString(),
            });
          }
        }
      }

      String? debtId;
      if (paymentMethod == PaymentMethod.credit) {
        // Per-customer cumulative credit exposure check.
        // Query the local debts table to prevent extending credit beyond the
        // shop's debt_threshold before the event even reaches the server.
        if (customerPhone != null && customerPhone.isNotEmpty) {
          final rows = await db.customSelect(
            'SELECT COALESCE(SUM(amount_owed - amount_paid), 0.0) AS outstanding '
            'FROM debts '
            'WHERE shop_id = ? AND customer_phone = ? '
            "AND status IN ('open', 'partial') AND deleted_at IS NULL",
            variables: [
              Variable.withString(currentShopId),
              Variable.withString(customerPhone),
            ],
            readsFrom: {db.debtsTable},
          ).get();
          final outstandingVal = rows.firstOrNull?.read<double>('outstanding');
          final outstanding = outstandingVal != null
              ? Decimal.parse(outstandingVal.toStringAsFixed(2))
              : Decimal.zero;
          final effective = debtThreshold ?? Decimal.parse('500');
          if (outstanding + total > effective) {
            throw StateError(
              'Customer credit limit exceeded: '
              '${outstanding.toStringAsFixed(2)} outstanding + '
              '${total.toStringAsFixed(2)} this sale = '
              '${(outstanding + total).toStringAsFixed(2)} '
              '(limit ${effective.toStringAsFixed(2)} ETB). '
              'Owner approval required.',
            );
          }
        }

        debtId = const Uuid().v4();
        await db.into(db.debtsTable).insert(
              DebtsTableCompanion.insert(
                id: debtId,
                shopId: currentShopId,
                saleId: Value(saleId),
                customerName: customerName!,
                customerPhone: Value(customerPhone),
                amountOwed: total.toDouble(),
                dueDate: Value(dueDate),
              ),
            );
      }

      // enqueue the sync event in the same transaction
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'sale.create',
              occurredAt: now,
              payload: jsonEncode({
                'id': saleId,
                'shift_id': shift,
                'subtotal': subtotal.toString(),
                'discount': discount.toString(),
                'total': total.toString(),
                'cost_total': costTotal.toString(),
                'payment_method': method,
                'occurred_at': now.toIso8601String(),
                'items': itemsPayload,
                if (supplyDeductionsPayload.isNotEmpty)
                  'supply_deductions': supplyDeductionsPayload,
                if (debtId != null) 'debt_id': debtId,
                if (paymentMethod == PaymentMethod.credit)
                  'customer': {
                    'name': customerName,
                    if (customerPhone != null) 'phone': customerPhone,
                    if (dueDate != null)
                      'due_date': dueDate.toIso8601String().split('T').first,
                  },
              }),
            ),
          );
    });

    // fire-and-forget — sync runs in background
    unawaited(syncWorker.kick());
    return saleId;
  }

  String _paymentMethodKey(PaymentMethod m) => switch (m) {
        PaymentMethod.cash => 'cash',
        PaymentMethod.mobileMoney => 'mobile_money',
        PaymentMethod.credit => 'credit',
      };

  /// Returns the most recent N completed sales by this shop, with item
  /// summaries for the recent-sales list / refund picker.
  Stream<List<RecentSale>> watchRecent({int limit = 50}) {
    return db.customSelect(
      'SELECT s.id, s.total, s.payment_method, s.status, s.occurred_at, '
      '       s.user_id, COUNT(i.id) AS item_count '
      'FROM sales s '
      'LEFT JOIN sale_items i ON i.sale_id = s.id '
      'WHERE s.shop_id = ? AND s.deleted_at IS NULL '
      'GROUP BY s.id '
      'ORDER BY s.occurred_at DESC LIMIT ?',
      variables: [
        Variable.withString(currentShopId),
        Variable.withInt(limit),
      ],
      readsFrom: {db.salesTable, db.saleItemsTable},
    ).watch().map(
      (rows) => rows.map((r) {
        return RecentSale(
          id: r.read<String>('id'),
          total: Decimal.parse(r.read<double>('total').toString()),
          paymentMethod: r.read<String>('payment_method'),
          status: r.read<String>('status'),
          occurredAt: r.read<DateTime>('occurred_at'),
          itemCount: r.read<int>('item_count'),
        );
      }).toList(),
    );
  }

  /// Reverse a completed sale. Local writes mirror the server-side
  /// `_sale_refund` handler: mark sale as refunded, restore stock, log
  /// inventory movements, enqueue the sync event.
  Future<void> refund({
    required String saleId,
    required String? ownerChallengeToken,
  }) async {
    final saleRow = await (db.select(db.salesTable)
          ..where((t) => t.id.equals(saleId)))
        .getSingleOrNull();
    if (saleRow == null) throw StateError('Sale not found');
    if (saleRow.status == 'refunded') {
      throw StateError('Sale already refunded');
    }

    final items = await (db.select(db.saleItemsTable)
          ..where((t) => t.saleId.equals(saleId)))
        .get();
    final now = DateTime.now().toUtc();

    await db.transaction(() async {
      await (db.update(db.salesTable)..where((t) => t.id.equals(saleId)))
          .write(const SalesTableCompanion(status: Value('refunded')));
      // Bakery tracks ingredient supplies, not product stock — skip the
      // stock restore and inventory log (supply restoration happens server-side).
      if (!isBakery) {
        for (final item in items) {
          await db.customUpdate(
            'UPDATE products SET stock = stock + ?, updated_at = ? WHERE id = ?',
            variables: [
              Variable.withReal(item.quantity),
              Variable.withInt(sqliteDateTimeParam(now)),
              Variable.withString(item.productId),
            ],
            updates: {db.productsTable},
            updateKind: UpdateKind.update,
          );
          await db.into(db.inventoryLogsTable).insert(
                InventoryLogsTableCompanion.insert(
                  id: const Uuid().v4(),
                  shopId: currentShopId,
                  productId: item.productId,
                  movement: 'refund',
                  quantityDelta: item.quantity,
                  referenceType: const Value('sale'),
                  referenceId: Value(saleId),
                  userId: Value(currentUserId),
                ),
              );
        }
      }
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'sale.refund',
              occurredAt: now,
              payload: jsonEncode({
                'sale_id': saleId,
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
  }
}

class RecentSale {
  RecentSale({
    required this.id,
    required this.total,
    required this.paymentMethod,
    required this.status,
    required this.occurredAt,
    required this.itemCount,
  });
  final String id;
  final Decimal total;
  final String paymentMethod;
  final String status;
  final DateTime occurredAt;
  final int itemCount;

  bool get isRefunded => status == 'refunded';
}

@riverpod
Stream<List<RecentSale>> watchRecentSales(WatchRecentSalesRef ref) {
  return ref.watch(salesRepositoryProvider).watchRecent();
}

@riverpod
SalesRepository salesRepository(SalesRepositoryRef ref) {
  final auth = ref.watch(authControllerProvider).valueOrNull;
  if (auth is! Authenticated) {
    throw StateError('SalesRepository requires authenticated user');
  }
  final shiftAsync = ref.watch(currentShiftProvider);
  return SalesRepository(
    db: ref.watch(appDatabaseProvider),
    syncWorker: ref.watch(syncWorkerProvider),
    currentUserId: auth.userId,
    currentShopId: auth.shopId,
    currentShiftId: shiftAsync.valueOrNull?.id,
    isBakery: auth.isBakery,
  );
}
