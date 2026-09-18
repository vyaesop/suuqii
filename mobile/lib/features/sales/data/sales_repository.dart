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
import 'package:suuqii/features/sales/data/sale_returns_dao.dart';
import 'package:suuqii/features/sales/data/sales_remote_data_source.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/sales/domain/entities/sale_return.dart';
import 'package:suuqii/features/shifts/data/shifts_repository.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';
import 'package:uuid/uuid.dart';

part 'sales_repository.g.dart';

/// Mirrors Shop.debt_threshold's server default (500 ETB). Used when the
/// repository is not given a shop-specific threshold.
final Decimal defaultDebtThreshold = Decimal.parse('500');

/// Mirrors Shop.return_window_days' server default.
const int defaultReturnWindowDays = 7;

class SalesRepository {
  SalesRepository({
    required this.db,
    required this.syncWorker,
    required this.currentUserId,
    required this.currentShopId,
    required this.currentShiftId,
    this.allowsOversell = false,
    this.isOwner = false,
    this.debtThreshold,
    this.hasLinePricing = false,
    this.returnWindowDays = defaultReturnWindowDays,
    this.remote,
  });

  final AppDatabase db;
  final SyncWorker syncWorker;
  final String currentUserId;
  final String currentShopId;
  final String? currentShiftId;

  /// `ShopFeatures.allowsOversell`: selling past the on-hand count is a
  /// warning rather than a hard stop (bakery — stock is only as current as
  /// the baker's last synced handover). Boutique and regular shops block.
  final bool allowsOversell;

  /// Owners may extend credit past the threshold without a PIN and may see
  /// every user's sales; cashiers need an owner challenge and only see their
  /// own (docs/17-roles.md).
  final bool isOwner;

  /// Mirrors Shop.debt_threshold from the server. Credit sales that would push
  /// a customer's cumulative outstanding above this value are blocked locally
  /// so the cashier gets immediate feedback rather than a deferred sync error.
  /// Defaults to 500 ETB when not provided.
  final Decimal? debtThreshold;

  /// `ShopFeatures.hasLinePricing`: the server applies the price-floor rule
  /// (docs/19 §13.3) only for these shops, so the local pre-flight mirrors
  /// that gate exactly — a regular shop never sees the PIN prompt for it.
  final bool hasLinePricing;

  /// Shop.return_window_days. Outside it an owner's return is accepted and
  /// audited server-side; the UI warns first. Cashiers are PIN-gated for
  /// every return anyway.
  final int returnWindowDays;

  /// Cross-device fallback for returns and the detail screen: a sale rung up
  /// on another phone is fetched from `GET /v1/sales/{id}` and cached
  /// locally. Null in offline-only tests.
  final SalesRemoteDataSource? remote;

  Decimal get effectiveDebtThreshold => debtThreshold ?? defaultDebtThreshold;

  /// Whether a credit sale of [saleTotal] to the customer identified by
  /// [customerPhone] would push their cumulative outstanding balance above
  /// the shop's debt threshold — i.e. whether the sale needs an owner (PIN
  /// challenge for cashiers) before it can be submitted.
  Future<bool> creditSaleNeedsOwnerApproval({
    required String? customerPhone,
    required Decimal saleTotal,
  }) async {
    // Mirrors the server: the cumulative check is keyed by phone number, so
    // sales without a phone are not threshold-checked.
    if (customerPhone == null || customerPhone.isEmpty) return false;
    final outstanding = await _outstandingByPhone(customerPhone);
    return outstanding + saleTotal > effectiveDebtThreshold;
  }

  /// Whether [cart] needs the owner because a line is priced below its floor
  /// (docs/19 §6.6): only in line-pricing shops, and never for the owner
  /// (who is audited server-side instead of gated).
  bool pricingNeedsOwnerApproval(Cart cart) =>
      hasLinePricing && !isOwner && cart.linesBelowFloor.isNotEmpty;

  Future<Decimal> _outstandingByPhone(String phone) async {
    // Money is stored as int64 santim, so this SUM is exact integer math.
    final rows = await db.customSelect(
      'SELECT COALESCE(SUM(amount_owed - amount_paid), 0) AS outstanding '
      'FROM debts '
      'WHERE shop_id = ? AND customer_phone = ? '
      "AND status IN ('open', 'partial') AND deleted_at IS NULL",
      variables: [
        Variable.withString(currentShopId),
        Variable.withString(phone),
      ],
      readsFrom: {db.debtsTable},
    ).get();
    final outstandingVal = rows.firstOrNull?.read<int>('outstanding');
    return outstandingVal != null
        ? decimalFromSantim(outstandingVal)
        : Decimal.zero;
  }

  /// Atomic local write: sale + items + stock decrement + inventory log
  /// + (optional) debt + sync event. Returns the persisted sale id.
  ///
  /// [kick] is false when this runs inside a wider transaction (the exchange):
  /// a push started there would read uncommitted rows off the open
  /// transaction and could POST a sale the caller still rolls back. The
  /// composing call kicks once, after it commits.
  Future<String> submit({
    required Cart cart,
    required PaymentMethod paymentMethod,
    String? customerName,
    String? customerPhone,
    DateTime? dueDate,
    String? ownerChallengeToken,
    bool kick = true,
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
      if (l.unitPrice < Decimal.zero) {
        throw StateError('Invalid price for ${l.product.name}');
      }
      // Bakery stock depends on the baker's handover having synced from
      // another device, so overselling is a warning in the POS rather than a
      // hard stop here — a sync delay must never block a sale.
      if (!allowsOversell && l.product.stock < l.qty) {
        throw StateError('Insufficient stock for ${l.product.name}');
      }
    }
    // Price floor (docs/19 §13.3), mirrored from the server so the cashier is
    // asked for the PIN now rather than the event bouncing hours later. The
    // owner is let through: the server audits `sale.below_floor` instead.
    if (pricingNeedsOwnerApproval(cart) && ownerChallengeToken == null) {
      throw BelowPriceFloorException(
        cart.linesBelowFloor.map((l) => l.product.name).toList(),
      );
    }

    final saleId = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final shift = currentShiftId;
    final subtotal = cart.subtotal;
    final discount = cart.discount;
    final total = cart.total;
    final method = _paymentMethodKey(paymentMethod);

    // A bakery sale is an ordinary sale. Production values each lot at recipe
    // cost and consumes the ingredients when the dough is mixed, so COGS here
    // comes from the lots this sale draws down — same as a bought-in product.
    // Until migration 0011 this branched: bakery COGS was recomputed from
    // recipes per sale and ingredients were deducted at sale time, which
    // overstated ingredients on hand for as long as stock went unsold.
    var costTotal = cart.costTotal;

    final itemsPayload = <Map<String, dynamic>>[];

    await db.transaction(() async {
      await db.into(db.salesTable).insert(
            SalesTableCompanion.insert(
              id: saleId,
              shopId: currentShopId,
              shiftId: Value(shift),
              userId: currentUserId,
              subtotal: santimFromDecimal(subtotal),
              discount: Value(santimFromDecimal(discount)),
              total: santimFromDecimal(total),
              costTotal: santimFromDecimal(costTotal),
              paymentMethod: method,
              occurredAt: now,
              synced: const Value(false),
            ),
          );

      var lotCostTotal = Decimal.zero;
      for (final line in cart.lines) {
        final itemId = const Uuid().v4();
        // FEFO lot consumption: COGS is the weighted cost of the batches this
        // line actually drew from (earliest expiry first, then oldest receipt).
        // Bakery lots are valued at recipe cost by production.record, so this
        // is correct for both shop types. Unlotted stock falls back to
        // product.purchasePrice; the server recomputes authoritatively at
        // sync-apply time.
        final lineUnitCostSantim = await db.lotsDao.consumeFefo(
          productId: line.product.id,
          quantity: line.qty,
          movement: 'sale',
          saleItemId: itemId,
          fallbackCostSantim: santimFromDecimal(line.product.purchasePrice),
          now: now,
        );
        final lineUnitCost = decimalFromSantim(lineUnitCostSantim);
        lotCostTotal += lineUnitCost * line.qty;
        // unit_price is what was charged, list_price what the tag said
        // (docs/19 §6.6). Both are written for every shop type: for a
        // non-haggling shop they are equal and the server's floor rule only
        // looks at them when has_line_pricing is on.
        await db.into(db.saleItemsTable).insert(
              SaleItemsTableCompanion.insert(
                id: itemId,
                saleId: saleId,
                productId: line.product.id,
                productNameSnapshot: line.product.name,
                quantity: line.qty.toDouble(),
                unitPrice: santimFromDecimal(line.unitPrice),
                unitCost: lineUnitCostSantim,
                listPrice: Value(santimFromDecimal(line.listPrice)),
              ),
            );

        // Stock delta + ledger, for both shop types. Bakery products carry
        // real stock since 0011 (production adds it, the sale takes it away).
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
          'unit_price': line.unitPrice.toString(),
          'list_price': line.listPrice.toString(),
          'unit_cost': lineUnitCost.toString(),
        });
      }

      // COGS comes from the lots actually consumed above, which can differ
      // from the cart's cached prices. Reconcile the sale row (and the payload
      // total below) with the lot-based figure.
      if (lotCostTotal != costTotal) {
        costTotal = lotCostTotal;
        await (db.update(db.salesTable)..where((t) => t.id.equals(saleId)))
            .write(
          SalesTableCompanion(costTotal: Value(santimFromDecimal(costTotal))),
        );
      }

      String? debtId;
      if (paymentMethod == PaymentMethod.credit) {
        // Per-customer cumulative credit exposure check, mirroring the
        // server: owners may exceed the threshold freely; cashiers need an
        // owner challenge attached (collected upfront by the POS) or the
        // sale is blocked locally before the event even reaches the server.
        if (customerPhone != null &&
            customerPhone.isNotEmpty &&
            !isOwner &&
            ownerChallengeToken == null) {
          final outstanding = await _outstandingByPhone(customerPhone);
          final effective = effectiveDebtThreshold;
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
                amountOwed: santimFromDecimal(total),
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
                // No `supply_deductions`: ingredients are deducted by
                // production.record for the whole bake (migration 0011). The
                // server ignores the field if an older client still sends it.
                if (debtId != null) 'debt_id': debtId,
                if (paymentMethod == PaymentMethod.credit)
                  'customer': {
                    'name': customerName,
                    if (customerPhone != null) 'phone': customerPhone,
                    if (dueDate != null)
                      'due_date': dueDate.toIso8601String().split('T').first,
                  },
                // Over-threshold credit sales and below-floor lines by
                // cashiers carry the owner challenge so the server accepts
                // them (sale.create itself is not blanket-sensitive). The
                // token is single-use; the server resolves it once and
                // shares the answer between both rules.
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });

    // fire-and-forget — sync runs in background
    if (kick) unawaited(syncWorker.kick());
    return saleId;
  }

  String _paymentMethodKey(PaymentMethod m) => switch (m) {
        PaymentMethod.cash => 'cash',
        PaymentMethod.mobileMoney => 'mobile_money',
        PaymentMethod.credit => 'credit',
      };

  /// Returns the most recent N completed sales, with item summaries for the
  /// recent-sales list / refund picker. Owners see every sale recorded on
  /// this device; cashiers only see their own (docs/17-roles.md: "view own
  /// recent sales" vs "view all sales").
  Stream<List<RecentSale>> watchRecent({int limit = 50}) {
    return db.customSelect(
      'SELECT s.id, s.total, s.payment_method, s.status, s.occurred_at, '
      '       s.user_id, COUNT(i.id) AS item_count '
      'FROM sales s '
      'LEFT JOIN sale_items i ON i.sale_id = s.id '
      'WHERE s.shop_id = ? AND s.deleted_at IS NULL '
      '${isOwner ? '' : 'AND s.user_id = ? '}'
      'GROUP BY s.id '
      'ORDER BY s.occurred_at DESC LIMIT ?',
      variables: [
        Variable.withString(currentShopId),
        if (!isOwner) Variable.withString(currentUserId),
        Variable.withInt(limit),
      ],
      readsFrom: {db.salesTable, db.saleItemsTable},
    ).watch().map(
      (rows) => rows.map((r) {
        return RecentSale(
          id: r.read<String>('id'),
          total: decimalFromSantim(r.read<int>('total')),
          paymentMethod: r.read<String>('payment_method'),
          status: r.read<String>('status'),
          occurredAt: r.read<DateTime>('occurred_at'),
          itemCount: r.read<int>('item_count'),
        );
      }).toList(),
    );
  }

  /// The local sale row, fetching and caching it from the server when this
  /// device never saw it (docs/19 §13.4). Cached rows are marked synced so
  /// they are never pushed back as a new `sale.create`.
  Future<SaleRow?> _loadSale(String saleId) async {
    final local = await (db.select(db.salesTable)
          ..where((t) => t.id.equals(saleId)))
        .getSingleOrNull();
    if (local != null) return local;
    final api = remote;
    if (api == null) return null;
    final fetched = await api.getSale(saleId);
    if (fetched == null) return null;
    await _cacheRemoteSale(fetched);
    return (db.select(db.salesTable)..where((t) => t.id.equals(saleId)))
        .getSingleOrNull();
  }

  Future<void> _cacheRemoteSale(RemoteSale sale) async {
    await db.transaction(() async {
      await db.into(db.salesTable).insert(
            SalesTableCompanion.insert(
              id: sale.id,
              shopId: currentShopId,
              shiftId: Value(sale.shiftId),
              userId: sale.userId,
              subtotal: santimFromDecimal(sale.subtotal),
              discount: Value(santimFromDecimal(sale.discount)),
              total: santimFromDecimal(sale.total),
              // cost_total is owner-only on the wire and not part of the
              // detail dump; profit views for foreign sales come from the
              // server reports, not this mirror.
              costTotal: 0,
              paymentMethod: sale.paymentMethod,
              status: Value(sale.status),
              occurredAt: sale.occurredAt,
              synced: const Value(true),
            ),
            mode: InsertMode.insertOrIgnore,
          );
      for (final item in sale.items) {
        await db.into(db.saleItemsTable).insert(
              SaleItemsTableCompanion.insert(
                id: item.id,
                saleId: sale.id,
                productId: item.productId,
                productNameSnapshot: item.productNameSnapshot,
                quantity: item.quantity.toDouble(),
                unitPrice: santimFromDecimal(item.unitPrice),
                unitCost: 0,
                listPrice: Value(
                  item.listPrice == null
                      ? null
                      : santimFromDecimal(item.listPrice!),
                ),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
      // Earlier returns must be mirrored too, or the over-return check and
      // the exchange-credit ratio would start from zero on this device.
      for (final ret in sale.returns) {
        await db.saleReturnsDao.insertReturn(
          id: ret.id,
          shopId: currentShopId,
          saleId: sale.id,
          userId: ret.userId,
          shiftId: ret.shiftId,
          occurredAt: ret.occurredAt,
          refundAmountSantim: santimFromDecimal(ret.refundAmount),
          refundMethod: switch (ret.refundMethod) {
            'cash' => RefundMethod.cash,
            'mobile_money' => RefundMethod.mobileMoney,
            _ => null,
          },
          exchangeSaleId: ret.exchangeSaleId,
          reason: ret.reason ?? ReturnReason.other,
          note: ret.note,
        );
        for (final line in ret.items) {
          await db.saleReturnsDao.insertItem(
            // Deterministic so `insertOrIgnore` really dedupes: two concurrent
            // `_loadSale` calls for the same uncached sale would otherwise
            // insert the same line twice, doubling returned quantities and
            // the exchange credit.
            id: line.id ?? _derivedReturnItemId(ret.id, line.saleItemId),
            returnId: ret.id,
            saleItemId: line.saleItemId,
            quantity: line.quantity,
            condition: line.condition,
            creditUnitSantim: santimFromDecimal(line.unitPrice),
          );
        }
      }
    });
  }

  /// Stable id for a cached remote return line when the server sends none:
  /// one line per (return, sale item), which is exactly how the server
  /// aggregates them.
  static String _derivedReturnItemId(String returnId, String saleItemId) =>
      '$returnId:$saleItemId';

  /// Loads everything needed to re-compose a shareable plain-text receipt
  /// for a past sale from the local snapshot tables (sale_items stores
  /// name/qty/price snapshots, so this works even after product edits),
  /// plus its returns and per-line returned quantities for the return sheet.
  /// Falls back to the server for sales rung up on another device.
  Future<SaleReceiptData?> receiptData(String saleId) async {
    final sale = await _loadSale(saleId);
    if (sale == null) return null;
    final items = await (db.select(db.saleItemsTable)
          ..where((t) => t.saleId.equals(saleId)))
        .get();
    final returned = await db.saleReturnsDao.returnedQtyBySaleItem(saleId);
    final returns = await db.saleReturnsDao.returnsForSale(saleId);
    return SaleReceiptData(
      id: sale.id,
      subtotal: decimalFromSantim(sale.subtotal),
      discount: decimalFromSantim(sale.discount),
      total: decimalFromSantim(sale.total),
      paymentMethod: sale.paymentMethod,
      status: sale.status,
      occurredAt: sale.occurredAt,
      items: [
        for (final item in items)
          SaleReceiptItem(
            id: item.id,
            productId: item.productId,
            name: item.productNameSnapshot,
            quantity: item.quantity,
            unitPrice: decimalFromSantim(item.unitPrice),
            listPrice: item.listPrice == null
                ? null
                : decimalFromSantim(item.listPrice!),
            returnedQuantity:
                (returned[item.id] ?? Decimal.zero).toDouble(),
          ),
      ],
      returns: returns,
    );
  }

  /// The credit rule for returns against [saleId] (docs/19 §13.3), so the
  /// return sheet shows the cashier exactly what [submitReturn] will write.
  Future<ReturnCreditCalculator> returnCalculator(String saleId) async {
    final sale = await _loadSale(saleId);
    if (sale == null) {
      throw const SaleReturnException('not_found', 'Sale not found');
    }
    return db.saleReturnsDao.calculatorFor(sale);
  }

  /// Whether a return recorded [now] against a sale from [saleOccurredAt]
  /// falls outside the shop's return window.
  bool isOutsideReturnWindow(DateTime saleOccurredAt, {DateTime? now}) =>
      (now ?? DateTime.now().toUtc()).difference(saleOccurredAt) >
      Duration(days: returnWindowDays);

  /// Partial return of one or more lines (docs/19 §13.3 `sale.return`).
  ///
  /// One transaction: return rows, per-item lot reversal (+ the spoilage
  /// pair for damaged units), stock and ledger, sale status, and exactly one
  /// `sale.return` event. Validation happens before any write so a refused
  /// return leaves nothing behind. Mirrors `_sale_return` server-side.
  Future<SaleReturnResult> submitReturn({
    required String saleId,
    required List<ReturnLine> items,
    required Decimal refundAmount,
    required RefundMethod? refundMethod,
    required ReturnReason reason,
    String? note,
    String? exchangeSaleId,
    String? ownerChallengeToken,
    DateTime? now,
    bool kick = true,
  }) async {
    // `sale.return` is a SENSITIVE_OP: without a challenge the server rejects
    // it terminally, so the rule belongs here rather than in each screen that
    // happens to remember it.
    if (!isOwner && ownerChallengeToken == null) {
      throw const SaleReturnException(
        'owner_pin_required',
        'A return needs an owner challenge',
      );
    }
    if (items.isEmpty) {
      throw const SaleReturnException('invalid_payload', 'Return has no items');
    }
    final sale = await _loadSale(saleId);
    if (sale == null) {
      throw const SaleReturnException('not_found', 'Sale not found');
    }
    if (sale.status == 'refunded') {
      throw const SaleReturnException(
        'already_refunded',
        'Sale already refunded',
      );
    }
    final at = now ?? DateTime.now().toUtc();
    final saleItems = {
      for (final si in await (db.select(db.saleItemsTable)
            ..where((t) => t.saleId.equals(saleId)))
          .get())
        si.id: si,
    };
    final returnedSoFar = await db.saleReturnsDao.returnedQtyBySaleItem(saleId);
    final calculator = await db.saleReturnsDao.calculatorFor(sale);

    // Validate every line before writing anything: the over-return check is
    // cumulative across earlier returns AND lines of this one.
    final nowReturning = <String, Decimal>{};
    final parsed = <({SaleItemRow item, ReturnLine line, int creditUnit})>[];
    for (final line in items) {
      final si = saleItems[line.saleItemId];
      if (si == null) {
        throw const SaleReturnException(
          'invalid_payload',
          'Sale item does not belong to this sale',
        );
      }
      if (line.quantity <= Decimal.zero) {
        throw const SaleReturnException(
          'invalid_payload',
          'Return quantity must be positive',
        );
      }
      final already = (returnedSoFar[si.id] ?? Decimal.zero) +
          (nowReturning[si.id] ?? Decimal.zero);
      final sold = Decimal.parse(si.quantity.toString());
      if (already + line.quantity > sold) {
        throw SaleReturnException(
          'return_exceeds_sold',
          'Returning ${already + line.quantity} of $sold sold',
        );
      }
      nowReturning[si.id] =
          (nowReturning[si.id] ?? Decimal.zero) + line.quantity;
      parsed.add(
        (
          item: si,
          line: line,
          creditUnit: calculator.creditUnitSantim(si.unitPrice),
        ),
      );
    }
    final creditTotalSantim = calculator.creditTotalSantim([
      for (final p in parsed)
        (unitPriceSantim: p.item.unitPrice, quantity: p.line.quantity),
    ]);
    final refundSantim = santimFromDecimal(refundAmount);
    if (refundSantim < 0 || refundSantim > creditTotalSantim) {
      throw SaleReturnException(
        'invalid_payload',
        'refund_amount must be between 0 and the credit '
            '${decimalFromSantim(creditTotalSantim)}',
      );
    }

    final returnId = const Uuid().v4();
    final itemsPayload = <Map<String, dynamic>>[];

    await db.transaction(() async {
      await db.saleReturnsDao.insertReturn(
        id: returnId,
        shopId: currentShopId,
        saleId: saleId,
        userId: currentUserId,
        shiftId: currentShiftId,
        occurredAt: at,
        refundAmountSantim: refundSantim,
        refundMethod: refundMethod,
        exchangeSaleId: exchangeSaleId,
        reason: reason,
        note: note,
      );
      for (final p in parsed) {
        final itemId = const Uuid().v4();
        await db.saleReturnsDao.insertItem(
          id: itemId,
          returnId: returnId,
          saleItemId: p.item.id,
          quantity: p.line.quantity,
          condition: p.line.condition,
          creditUnitSantim: p.creditUnit,
        );
        // Units go back onto the exact lots they came from, oldest draw
        // first, so batch reports stay truthful.
        final reversed = await db.lotsDao.reverseItemConsumptions(
          saleItemId: p.item.id,
          quantity: p.line.quantity,
          now: at,
        );
        await db.into(db.inventoryLogsTable).insert(
              InventoryLogsTableCompanion.insert(
                id: const Uuid().v4(),
                shopId: currentShopId,
                productId: p.item.productId,
                movement: 'refund',
                quantityDelta: p.line.quantity.toDouble(),
                reason: Value(reason.wire),
                referenceType: const Value('sale_return'),
                referenceId: Value(returnId),
                userId: Value(currentUserId),
              ),
            );
        if (p.line.condition == ReturnCondition.damaged) {
          // Came back but cannot be sold: onto its lot and straight back off
          // as spoilage, so the loss is visible instead of vanishing. Net
          // stock unchanged, hence no products.stock update for this line.
          await db.lotsDao.spoilReturnedLots(
            saleItemId: p.item.id,
            lots: reversed.lots,
            now: at,
          );
          await db.into(db.inventoryLogsTable).insert(
                InventoryLogsTableCompanion.insert(
                  id: const Uuid().v4(),
                  shopId: currentShopId,
                  productId: p.item.productId,
                  movement: 'spoilage',
                  quantityDelta: -p.line.quantity.toDouble(),
                  reason: const Value('return_damaged'),
                  referenceType: const Value('sale_return'),
                  referenceId: Value(returnId),
                  userId: Value(currentUserId),
                ),
              );
        } else {
          await db.customUpdate(
            'UPDATE products SET stock = stock + ?, updated_at = ? WHERE id = ?',
            variables: [
              Variable.withReal(p.line.quantity.toDouble()),
              Variable.withInt(sqliteDateTimeParam(at)),
              Variable.withString(p.item.productId),
            ],
            updates: {db.productsTable},
            updateKind: UpdateKind.update,
          );
        }
        itemsPayload.add({
          'id': itemId,
          'sale_item_id': p.item.id,
          'quantity': p.line.quantity.toString(),
          'condition': p.line.condition.wire,
        });
      }

      final fullyReturned = saleItems.values.every((si) {
        final back = (returnedSoFar[si.id] ?? Decimal.zero) +
            (nowReturning[si.id] ?? Decimal.zero);
        return back >= Decimal.parse(si.quantity.toString());
      });
      await (db.update(db.salesTable)..where((t) => t.id.equals(saleId))).write(
        SalesTableCompanion(
          status: Value(fullyReturned ? 'refunded' : 'partially_returned'),
        ),
      );

      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'sale.return',
              occurredAt: at,
              payload: jsonEncode({
                'id': returnId,
                'sale_id': saleId,
                'shift_id': currentShiftId,
                'occurred_at': at.toIso8601String(),
                'items': itemsPayload,
                'refund_amount': decimalFromSantim(refundSantim).toString(),
                'refund_method': refundMethod?.wire,
                'exchange_sale_id': exchangeSaleId,
                'reason': reason.wire,
                'note': note,
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });

    if (kick) unawaited(syncWorker.kick());
    return SaleReturnResult(
      returnId: returnId,
      credit: decimalFromSantim(creditTotalSantim),
      refundAmount: decimalFromSantim(refundSantim),
      exchangeSaleId: exchangeSaleId,
    );
  }

  /// Exchange (docs/19 §13.3): an ordinary `sale.create` for the new items
  /// whose `discount` carries the returned goods' credit, then the
  /// `sale.return` linked to it with `refund_amount = max(0, credit − new
  /// subtotal)`. One local transaction, sale event first, so the server
  /// applies them in that order and a crash cannot leave half an exchange.
  ///
  /// The credit *is* the discount here; [cart]'s own discount is ignored.
  ///
  /// An `owner_challenge` is single-use server-side, so the two events need
  /// two distinct tokens: [ownerChallengeToken] authorises the `sale.create`
  /// (only ever needed when the floor or credit rule fires) and
  /// [returnOwnerChallengeToken] the `sale.return`, which is always sensitive.
  /// Reusing one token would have the sale consume it and the return bounce
  /// with `owner_pin_required` — a dead-lettered event on top of local state
  /// the server never accepted.
  Future<SaleReturnResult> submitExchange({
    required String originalSaleId,
    required List<ReturnLine> returnItems,
    required ReturnReason reason,
    required Cart cart,
    required PaymentMethod paymentMethod,
    required RefundMethod refundMethod,
    String? note,
    String? customerName,
    String? customerPhone,
    DateTime? dueDate,
    String? ownerChallengeToken,
    String? returnOwnerChallengeToken,
  }) async {
    if (cart.isEmpty) throw StateError('Cart is empty');
    // submitReturn enforces the challenge itself, but checking before the
    // sale is written keeps the common refusal free of a rollback.
    if (!isOwner && returnOwnerChallengeToken == null) {
      throw const SaleReturnException(
        'owner_pin_required',
        'An exchange needs an owner challenge for the return',
      );
    }
    final calculator = await returnCalculator(originalSaleId);
    final saleItems = {
      for (final si in await (db.select(db.saleItemsTable)
            ..where((t) => t.saleId.equals(originalSaleId)))
          .get())
        si.id: si,
    };
    final creditSantim = calculator.creditTotalSantim([
      for (final line in returnItems)
        if (saleItems[line.saleItemId] case final si?)
          (unitPriceSantim: si.unitPrice, quantity: line.quantity),
    ]);
    final settlement = ExchangeContext(
      originalSaleId: originalSaleId,
      items: returnItems,
      reason: reason,
      credit: decimalFromSantim(creditSantim),
    ).settle(cart.subtotal);

    late SaleReturnResult result;
    await db.transaction(() async {
      final newSaleId = await submit(
        cart: Cart(cart.lines, discount: settlement.creditApplied),
        paymentMethod: paymentMethod,
        customerName: customerName,
        customerPhone: customerPhone,
        dueDate: dueDate,
        ownerChallengeToken: ownerChallengeToken,
        kick: false,
      );
      result = await submitReturn(
        saleId: originalSaleId,
        items: returnItems,
        refundAmount: settlement.refund,
        refundMethod: settlement.refund > Decimal.zero ? refundMethod : null,
        reason: reason,
        note: note,
        exchangeSaleId: newSaleId,
        ownerChallengeToken: returnOwnerChallengeToken,
        kick: false,
      );
    });
    // Only now: a push started inside the transaction above would run on the
    // open transaction and could send the replacement sale the return's
    // failure is about to roll back (leaving a server-side sale no device
    // knows about).
    unawaited(syncWorker.kick());
    return result;
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
    // The two refund paths are disjoint in shift and revenue math (docs/19
    // §13.3): once a line has gone back through sale.return, the rest must
    // too, or the server refuses the legacy event.
    if (saleRow.status == 'partially_returned') {
      throw StateError('Sale partially returned');
    }

    final items = await (db.select(db.saleItemsTable)
          ..where((t) => t.saleId.equals(saleId)))
        .get();
    final now = DateTime.now().toUtc();

    await db.transaction(() async {
      await (db.update(db.salesTable)..where((t) => t.id.equals(saleId)))
          .write(const SalesTableCompanion(status: Value('refunded')));
      // Both shop types: put quantities back on the exact lots this sale
      // consumed (movement 'refund_reversal', negative qty) so batch reports
      // stay truthful. Ingredients are deliberately not restored — the flour
      // was used when the dough was mixed, and a returned loaf does not undo
      // that.
      await db.lotsDao.reverseSaleConsumptions(saleId, now: now);
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

/// Snapshot of a past sale for receipt sharing, the detail screen and the
/// return sheet (see [SalesRepository.receiptData]).
class SaleReceiptData {
  SaleReceiptData({
    required this.id,
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paymentMethod,
    required this.status,
    required this.occurredAt,
    required this.items,
    this.returns = const [],
  });
  final String id;
  final Decimal subtotal;
  final Decimal discount;
  final Decimal total;
  final String paymentMethod;
  final String status;
  final DateTime occurredAt;
  final List<SaleReceiptItem> items;

  /// Returns recorded against this sale, oldest first.
  final List<SaleReturnView> returns;

  bool get isRefunded => status == 'refunded';
  bool get isPartiallyReturned => status == 'partially_returned';

  /// True while at least one unit can still come back.
  bool get canReturn =>
      !isRefunded && items.any((i) => i.remainingQuantity > 0);

  /// Money handed back across every return.
  Decimal get refundedTotal =>
      returns.fold(Decimal.zero, (a, r) => a + r.refundAmount);
}

class SaleReceiptItem {
  SaleReceiptItem({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.id = '',
    this.productId = '',
    this.listPrice,
    this.returnedQuantity = 0,
  });

  /// `sale_items.id` — what a return references. Empty for ad-hoc snapshots.
  final String id;
  final String productId;
  final String name;
  final double quantity;

  /// What was charged per unit.
  final Decimal unitPrice;

  /// The tag price at the time; null when unknown (pre-Phase-3 rows).
  final Decimal? listPrice;

  /// Units already returned across earlier returns.
  final double returnedQuantity;

  Decimal get lineTotal => unitPrice * Decimal.parse(quantity.toString());

  /// Haggled below the tag (docs/19 §6.6): the receipt shows the strike.
  bool get hasLineDiscount => listPrice != null && listPrice! > unitPrice;

  double get remainingQuantity => quantity - returnedQuantity;
  bool get isFullyReturned => remainingQuantity <= 0;
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
  bool get isPartiallyReturned => status == 'partially_returned';
}

@riverpod
Stream<List<RecentSale>> watchRecentSales(WatchRecentSalesRef ref) {
  return ref.watch(salesRepositoryProvider).watchRecent();
}

/// Line-level snapshot of one past sale for the sale-detail screen and
/// receipt sharing. Null when the sale is unknown locally and on the server.
@riverpod
Future<SaleReceiptData?> saleReceipt(SaleReceiptRef ref, String saleId) {
  return ref.watch(salesRepositoryProvider).receiptData(saleId);
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
    allowsOversell: auth.features.allowsOversell,
    isOwner: auth.isOwner,
    debtThreshold: auth.debtThresholdValue,
    hasLinePricing: auth.features.hasLinePricing,
    returnWindowDays: auth.returnWindowDays,
    remote: SalesRemoteDataSource(ref.watch(dioProvider)),
  );
}
