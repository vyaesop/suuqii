import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/shifts/data/shifts_repository.dart';
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
  });

  final AppDatabase db;
  final SyncWorker syncWorker;
  final String currentUserId;
  final String currentShopId;
  final String? currentShiftId;

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
      if (l.product.stock < l.qty) {
        throw StateError('Insufficient stock for ${l.product.name}');
      }
    }

    final saleId = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final shift = currentShiftId;
    final subtotal = cart.subtotal;
    final discount = cart.discount;
    final total = cart.total;
    final costTotal = cart.costTotal;
    final method = _paymentMethodKey(paymentMethod);

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
        await db.into(db.saleItemsTable).insert(
              SaleItemsTableCompanion.insert(
                id: itemId,
                saleId: saleId,
                productId: line.product.id,
                productNameSnapshot: line.product.name,
                quantity: line.qty.toDouble(),
                unitPrice: line.product.sellingPrice.toDouble(),
                unitCost: line.product.purchasePrice.toDouble(),
              ),
            );

        // stock delta + ledger
        await db.customStatement(
          'UPDATE products SET stock = stock - ?, updated_at = ? WHERE id = ?',
          [
            line.qty.toDouble(),
            sqliteDateTimeParam(now),
            line.product.id,
          ],
        );
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

        itemsPayload.add({
          'id': itemId,
          'product_id': line.product.id,
          'product_name_snapshot': line.product.name,
          'quantity': line.qty.toString(),
          'unit_price': line.product.sellingPrice.toString(),
          'unit_cost': line.product.purchasePrice.toString(),
        });
      }

      String? debtId;
      if (paymentMethod == PaymentMethod.credit) {
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
      for (final item in items) {
        await db.customStatement(
          'UPDATE products SET stock = stock + ?, updated_at = ? WHERE id = ?',
          [item.quantity, sqliteDateTimeParam(now), item.productId],
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
  );
}
