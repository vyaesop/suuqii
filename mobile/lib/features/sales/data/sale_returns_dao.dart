import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/tables/sale_returns_table.dart';
import 'package:suuqii/core/storage/tables/sales_tables.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/sales/domain/entities/sale_return.dart';

part 'sale_returns_dao.g.dart';

/// One returned line as read back for receipts and the detail screen.
class SaleReturnItemView {
  const SaleReturnItemView({
    required this.saleItemId,
    required this.productName,
    required this.quantity,
    required this.condition,
    required this.creditUnit,
  });

  final String saleItemId;
  final String productName;
  final double quantity;
  final ReturnCondition condition;

  /// Proportional credit per unit (birr) — `sale_return_items.unit_price`.
  final Decimal creditUnit;

  Decimal get creditTotal => creditUnit * Decimal.parse(quantity.toString());
}

/// A return with its lines, oldest first.
class SaleReturnView {
  const SaleReturnView({
    required this.id,
    required this.occurredAt,
    required this.refundAmount,
    required this.refundMethod,
    required this.exchangeSaleId,
    required this.reason,
    required this.note,
    required this.items,
  });

  final String id;
  final DateTime occurredAt;
  final Decimal refundAmount;
  final RefundMethod? refundMethod;
  final String? exchangeSaleId;
  final ReturnReason? reason;
  final String? note;
  final List<SaleReturnItemView> items;

  Decimal get credit => items.fold(Decimal.zero, (a, i) => a + i.creditTotal);

  bool get isExchange => exchangeSaleId != null;
}

/// Local mirror of `sale_returns` / `sale_return_items` (docs/19 §13.5).
///
/// Mutating methods join the caller's transaction (Drift transactions are
/// zone-scoped) so the repository can compose return rows, lot reversals,
/// stock updates and the sync event atomically.
@DriftAccessor(tables: [SaleReturnsTable, SaleReturnItemsTable, SaleItemsTable])
class SaleReturnsDao extends DatabaseAccessor<AppDatabase>
    with _$SaleReturnsDaoMixin {
  SaleReturnsDao(super.db);

  static Decimal _dec(double v) => Decimal.parse(v.toString());

  Future<bool> exists(String returnId) async {
    final row = await (select(saleReturnsTable)
          ..where((t) => t.id.equals(returnId)))
        .getSingleOrNull();
    return row != null;
  }

  Future<void> insertReturn({
    required String id,
    required String shopId,
    required String saleId,
    required String userId,
    required String? shiftId,
    required DateTime occurredAt,
    required int refundAmountSantim,
    required RefundMethod? refundMethod,
    required String? exchangeSaleId,
    required ReturnReason reason,
    required String? note,
  }) {
    return into(saleReturnsTable).insert(
      SaleReturnsTableCompanion.insert(
        id: id,
        shopId: shopId,
        saleId: saleId,
        userId: userId,
        shiftId: Value(shiftId),
        occurredAt: occurredAt,
        refundAmount: refundAmountSantim,
        refundMethod: Value(refundMethod?.wire),
        exchangeSaleId: Value(exchangeSaleId),
        reason: Value(reason.wire),
        note: Value(note),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  Future<void> insertItem({
    required String id,
    required String returnId,
    required String saleItemId,
    required Decimal quantity,
    required ReturnCondition condition,
    required int creditUnitSantim,
  }) {
    return into(saleReturnItemsTable).insert(
      SaleReturnItemsTableCompanion.insert(
        id: id,
        returnId: returnId,
        saleItemId: saleItemId,
        quantity: quantity.toDouble(),
        condition: condition.wire,
        unitPrice: creditUnitSantim,
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  /// Remove a return and its lines. Used when the server refuses a local
  /// `sale.return` for good: the phantom rows would otherwise keep counting
  /// towards the over-return check and the exchange-credit ratio forever.
  Future<void> deleteReturn(String returnId) async {
    await (delete(saleReturnItemsTable)
          ..where((t) => t.returnId.equals(returnId)))
        .go();
    await (delete(saleReturnsTable)..where((t) => t.id.equals(returnId))).go();
  }

  /// Quantity already returned per sale item of [saleId], across every
  /// return so far — the over-return check is cumulative, not per event.
  Future<Map<String, Decimal>> returnedQtyBySaleItem(String saleId) async {
    final rows = await customSelect(
      'SELECT ri.sale_item_id AS sale_item_id, SUM(ri.quantity) AS qty '
      'FROM sale_return_items ri '
      'JOIN sale_returns r ON r.id = ri.return_id '
      'WHERE r.sale_id = ? '
      'GROUP BY ri.sale_item_id',
      variables: [Variable.withString(saleId)],
      readsFrom: {saleReturnsTable, saleReturnItemsTable},
    ).get();
    return {
      for (final r in rows)
        r.read<String>('sale_item_id'): _dec(r.read<double>('qty')),
    };
  }

  /// `Σ qty × credit_unit` of returns whose `exchange_sale_id` is [saleId]:
  /// the credit that rode into this sale as its discount (docs/19 §13.3),
  /// added back before the proportional-credit ratio. Int santim.
  Future<int> exchangeCreditIntoSale(String saleId) async {
    final rows = await customSelect(
      'SELECT ri.quantity AS qty, ri.unit_price AS unit_price '
      'FROM sale_return_items ri '
      'JOIN sale_returns r ON r.id = ri.return_id '
      'WHERE r.exchange_sale_id = ?',
      variables: [Variable.withString(saleId)],
      readsFrom: {saleReturnsTable, saleReturnItemsTable},
    ).get();
    var total = Decimal.zero;
    for (final r in rows) {
      total += _dec(r.read<double>('qty')) *
          decimalFromSantim(r.read<int>('unit_price'));
    }
    return santimFromDecimal(total);
  }

  /// The credit rule instance for [sale] (docs/19 §13.3).
  Future<ReturnCreditCalculator> calculatorFor(SaleRow sale) async {
    final exchangeCredit = await exchangeCreditIntoSale(sale.id);
    return ReturnCreditCalculator(
      subtotalSantim: sale.subtotal,
      effectiveTotalSantim: sale.total + exchangeCredit,
    );
  }

  /// Returns of one sale with their lines, oldest first. Reactive so the
  /// detail screen updates as returns land (locally or via pull).
  Stream<List<SaleReturnView>> watchReturnsForSale(String saleId) {
    return customSelect(
      'SELECT r.id AS return_id, r.occurred_at, r.refund_amount, '
      '       r.refund_method, r.exchange_sale_id, r.reason, r.note, '
      '       ri.sale_item_id, ri.quantity, ri.condition, ri.unit_price, '
      '       si.product_name_snapshot '
      'FROM sale_returns r '
      'LEFT JOIN sale_return_items ri ON ri.return_id = r.id '
      'LEFT JOIN sale_items si ON si.id = ri.sale_item_id '
      'WHERE r.sale_id = ? '
      'ORDER BY r.occurred_at ASC, r.id ASC, ri.id ASC',
      variables: [Variable.withString(saleId)],
      readsFrom: {saleReturnsTable, saleReturnItemsTable, saleItemsTable},
    ).watch().map(_groupReturns);
  }

  Future<List<SaleReturnView>> returnsForSale(String saleId) =>
      watchReturnsForSale(saleId).first;

  static List<SaleReturnView> _groupReturns(List<QueryRow> rows) {
    final out =
        <String, ({SaleReturnView head, List<SaleReturnItemView> items})>{};
    for (final r in rows) {
      final id = r.read<String>('return_id');
      final entry = out.putIfAbsent(
        id,
        () => (
          head: SaleReturnView(
            id: id,
            occurredAt: r.read<DateTime>('occurred_at'),
            refundAmount: decimalFromSantim(r.read<int>('refund_amount')),
            refundMethod: switch (r.readNullable<String>('refund_method')) {
              'cash' => RefundMethod.cash,
              'mobile_money' => RefundMethod.mobileMoney,
              _ => null,
            },
            exchangeSaleId: r.readNullable<String>('exchange_sale_id'),
            reason: ReturnReason.fromWire(r.readNullable<String>('reason')),
            note: r.readNullable<String>('note'),
            items: const [],
          ),
          items: <SaleReturnItemView>[],
        ),
      );
      final saleItemId = r.readNullable<String>('sale_item_id');
      if (saleItemId != null) {
        entry.items.add(
          SaleReturnItemView(
            saleItemId: saleItemId,
            productName: r.readNullable<String>('product_name_snapshot') ?? '',
            quantity: r.read<double>('quantity'),
            condition: ReturnCondition.fromWire(r.read<String>('condition')) ??
                ReturnCondition.resellable,
            creditUnit: decimalFromSantim(r.read<int>('unit_price')),
          ),
        );
      }
    }
    return [
      for (final e in out.values)
        SaleReturnView(
          id: e.head.id,
          occurredAt: e.head.occurredAt,
          refundAmount: e.head.refundAmount,
          refundMethod: e.head.refundMethod,
          exchangeSaleId: e.head.exchangeSaleId,
          reason: e.head.reason,
          note: e.head.note,
          items: List.unmodifiable(e.items),
        ),
    ];
  }
}
