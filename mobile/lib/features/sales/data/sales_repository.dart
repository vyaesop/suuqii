import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/storage/tables/debts_table.dart';
import '../../../core/storage/tables/inventory_logs_table.dart';
import '../../../core/storage/tables/sales_tables.dart';
import '../../auth/domain/entities/auth_state.dart';
import '../../auth/presentation/controllers/auth_controller.dart';
import '../../shifts/data/shifts_repository.dart';
import '../../sync/data/sync_worker.dart';
import '../domain/entities/sale.dart';

part 'sales_repository.g.dart';

class SalesRepository {
  SalesRepository({
    required this.db,
    required this.kickSync,
    required this.currentUserId,
    required this.currentShopId,
    required this.currentShiftId,
  });

  final AppDatabase db;
  final Future<void> Function() kickSync;
  final String currentUserId;
  final String currentShopId;
  final String? Function() currentShiftId;

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
    if (paymentMethod == PaymentMethod.credit && (customerName == null || customerName.isEmpty)) {
      throw StateError('Credit sale needs a customer name');
    }
    for (final l in cart.lines) {
      if (l.qty <= Decimal.zero) throw StateError('Invalid quantity for ${l.product.name}');
      if (l.product.stock < l.qty) {
        throw StateError('Insufficient stock for ${l.product.name}');
      }
    }

    final saleId = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final shift = currentShiftId();
    final subtotal = cart.total;
    final total = cart.total;
    final costTotal = cart.costTotal;
    final method = _paymentMethodKey(paymentMethod);

    final itemsPayload = <Map<String, dynamic>>[];

    await db.transaction(() async {
      await db.into(db.salesTable).insert(SalesTableCompanion.insert(
            id: saleId,
            shopId: currentShopId,
            shiftId: Value(shift),
            userId: currentUserId,
            subtotal: subtotal.toDouble(),
            total: total.toDouble(),
            costTotal: costTotal.toDouble(),
            paymentMethod: method,
            occurredAt: now,
            synced: const Value(false),
          ));

      for (final line in cart.lines) {
        final itemId = const Uuid().v4();
        await db.into(db.saleItemsTable).insert(SaleItemsTableCompanion.insert(
              id: itemId,
              saleId: saleId,
              productId: line.product.id,
              productNameSnapshot: line.product.name,
              quantity: line.qty.toDouble(),
              unitPrice: line.product.sellingPrice.toDouble(),
              unitCost: line.product.purchasePrice.toDouble(),
            ));

        // stock delta + ledger
        await db.customStatement(
          'UPDATE products SET stock = stock - ?, updated_at = ? WHERE id = ?',
          [line.qty.toDouble(), now.toIso8601String(), line.product.id],
        );
        await db.into(db.inventoryLogsTable).insert(InventoryLogsTableCompanion.insert(
              id: const Uuid().v4(),
              shopId: currentShopId,
              productId: line.product.id,
              movement: 'sale',
              quantityDelta: -line.qty.toDouble(),
              referenceType: const Value('sale'),
              referenceId: Value(saleId),
              userId: Value(currentUserId),
            ));

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
        await db.into(db.debtsTable).insert(DebtsTableCompanion.insert(
              id: debtId,
              shopId: currentShopId,
              saleId: Value(saleId),
              customerName: customerName!,
              customerPhone: Value(customerPhone),
              amountOwed: total.toDouble(),
              dueDate: Value(dueDate),
            ));
      }

      // enqueue the sync event in the same transaction
      await db.into(db.syncEventsTable).insert(SyncEventsTableCompanion.insert(
            clientEventId: const Uuid().v4(),
            op: 'sale.create',
            occurredAt: now,
            payload: jsonEncode({
              'id': saleId,
              'shift_id': shift,
              'subtotal': subtotal.toString(),
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
                  if (dueDate != null) 'due_date': dueDate.toIso8601String().split('T').first,
                },
            }),
          ));
    });

    // fire-and-forget — sync runs in background
    unawaited(kickSync());
    return saleId;
  }

  String _paymentMethodKey(PaymentMethod m) => switch (m) {
        PaymentMethod.cash => 'cash',
        PaymentMethod.mobileMoney => 'mobile_money',
        PaymentMethod.credit => 'credit',
      };
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
    kickSync: () => ref.read(syncWorkerProvider).kick(),
    currentUserId: auth.userId,
    currentShopId: auth.shopId,
    currentShiftId: () => shiftAsync.valueOrNull?.id,
  );
}
