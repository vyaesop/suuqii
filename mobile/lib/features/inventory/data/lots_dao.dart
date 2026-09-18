import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/tables/sales_tables.dart';
import 'package:suuqii/core/storage/tables/stock_lots_table.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/inventory/domain/entities/stock_lot.dart';
import 'package:uuid/uuid.dart';

part 'lots_dao.g.dart';

/// A lot of a product expiring soon (or expired), joined with its product for
/// the inventory "expiring soon" view.
class ExpiringLot {
  const ExpiringLot({
    required this.lot,
    required this.productName,
    required this.productUnit,
  });
  final StockLot lot;
  final String productName;
  final String productUnit;
}

/// One lot a return put units back onto.
class ReversedLot {
  const ReversedLot({
    required this.lotId,
    required this.quantity,
    required this.unitCostSantim,
  });
  final String lotId;
  final Decimal quantity;
  final int unitCostSantim;
}

/// Result of [LotsDao.reverseItemConsumptions].
class ReversedConsumption {
  const ReversedConsumption({required this.lots, required this.unitCostSantim});

  final List<ReversedLot> lots;

  /// Weighted unit cost (int santim) of what went back on the lots; 0 when
  /// nothing was lotted (oversold units).
  final int unitCostSantim;
}

/// Local mirror of stock lots + FEFO consumption (docs/16-inventory-lots.md).
///
/// All mutating methods participate in the caller's Drift transaction (Drift
/// transactions are zone-scoped), so repositories can compose lot writes with
/// stock updates and sync-event enqueues atomically.
@DriftAccessor(tables: [StockLotsTable, LotConsumptionsTable, SaleItemsTable])
class LotsDao extends DatabaseAccessor<AppDatabase> with _$LotsDaoMixin {
  LotsDao(super.db);

  static Decimal _dec(double v) => Decimal.parse(v.toString());

  StockLot _toDomain(StockLotRow r) => StockLot(
        id: r.id,
        productId: r.productId,
        qtyReceived: _dec(r.qtyReceived),
        qtyRemaining: _dec(r.qtyRemaining),
        unitCost: decimalFromSantim(r.unitCostSantim),
        expiryDate: r.expiryDate == null ? null : DateTime.parse(r.expiryDate!),
        receivedAt: r.receivedAt,
        note: r.note,
      );

  Future<void> insertLot({
    required String id,
    required String productId,
    required Decimal quantity,
    required int unitCostSantim,
    required DateTime receivedAt,
    String? expiryDate,
    String? note,
  }) {
    return into(stockLotsTable).insert(
      StockLotsTableCompanion.insert(
        id: id,
        productId: productId,
        qtyReceived: quantity.toDouble(),
        qtyRemaining: quantity.toDouble(),
        unitCostSantim: unitCostSantim,
        expiryDate: Value(expiryDate),
        receivedAt: receivedAt,
        note: Value(note),
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

  /// Open lots in FEFO order: earliest expiry first (NULLs last), then FIFO
  /// by receipt time. Mirrors the server's consumption order exactly.
  Future<List<StockLotRow>> openLotsFefo(String productId) {
    return (select(stockLotsTable)
          ..where((t) => t.productId.equals(productId))
          ..where((t) => t.qtyRemaining.isBiggerThanValue(0))
          ..orderBy([
            (t) => OrderingTerm.asc(t.expiryDate.isNull()),
            (t) => OrderingTerm.asc(t.expiryDate),
            (t) => OrderingTerm.asc(t.receivedAt),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .get();
  }

  Stream<List<StockLot>> watchOpenLots(String productId) {
    return (select(stockLotsTable)
          ..where((t) => t.productId.equals(productId))
          ..where((t) => t.qtyRemaining.isBiggerThanValue(0))
          ..orderBy([
            (t) => OrderingTerm.asc(t.expiryDate.isNull()),
            (t) => OrderingTerm.asc(t.expiryDate),
            (t) => OrderingTerm.asc(t.receivedAt),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .watch()
        .map((rows) => rows.map(_toDomain).toList());
  }

  /// Consume [quantity] from lots (a specific one when [lotId] is given, else
  /// FEFO), writing one lot_consumptions row per lot drawn from. Returns the
  /// weighted unit cost (int santim) of what was consumed.
  ///
  /// Consumption beyond available lots (oversell — allowed by design) is
  /// costed at [fallbackCostSantim] and leaves no consumption row since there
  /// is no lot to draw from; the server recomputes COGS authoritatively.
  Future<int> consumeFefo({
    required String productId,
    required Decimal quantity,
    required String movement,
    required int fallbackCostSantim,
    String? saleItemId,
    String? lotId,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now().toUtc();
    final lots = lotId != null
        ? await (select(stockLotsTable)..where((t) => t.id.equals(lotId))).get()
        : await openLotsFefo(productId);

    var remaining = quantity;
    var costAccum = Decimal.zero; // santim
    for (final lot in lots) {
      if (remaining <= Decimal.zero) break;
      final available = _dec(lot.qtyRemaining);
      final take = available < remaining ? available : remaining;
      if (take <= Decimal.zero) continue;
      remaining -= take;
      costAccum += take * Decimal.fromInt(lot.unitCostSantim);
      await (update(stockLotsTable)..where((t) => t.id.equals(lot.id))).write(
        StockLotsTableCompanion(
          qtyRemaining: Value((available - take).toDouble()),
        ),
      );
      await into(lotConsumptionsTable).insert(
        LotConsumptionsTableCompanion.insert(
          id: const Uuid().v4(),
          lotId: lot.id,
          saleItemId: Value(saleItemId),
          movement: movement,
          quantity: take.toDouble(),
          unitCostSantim: lot.unitCostSantim,
          consumedAt: at,
        ),
      );
    }
    if (remaining > Decimal.zero) {
      costAccum += remaining * Decimal.fromInt(fallbackCostSantim);
    }
    if (quantity <= Decimal.zero) return fallbackCostSantim;
    // Half-away-from-zero, same policy as santimFromDecimal.
    return (costAccum / quantity)
        .toDecimal(scaleOnInfinitePrecision: 12)
        .round()
        .toBigInt()
        .toInt();
  }

  /// Refund path: put this sale's consumed quantities back on their exact
  /// lots and record 'refund_reversal' rows (negative quantity), so batch
  /// reports stay truthful after refunds.
  Future<void> reverseSaleConsumptions(String saleId, {DateTime? now}) async {
    final at = now ?? DateTime.now().toUtc();
    final rows = await customSelect(
      'SELECT lc.lot_id, lc.sale_item_id, lc.quantity, lc.unit_cost_santim '
      'FROM lot_consumptions lc '
      'JOIN sale_items si ON si.id = lc.sale_item_id '
      "WHERE si.sale_id = ? AND lc.movement = 'sale'",
      variables: [Variable.withString(saleId)],
      readsFrom: {lotConsumptionsTable, saleItemsTable},
    ).get();
    for (final r in rows) {
      final qty = r.read<double>('quantity');
      final lotId = r.read<String>('lot_id');
      await customUpdate(
        'UPDATE stock_lots SET qty_remaining = qty_remaining + ? WHERE id = ?',
        variables: [Variable.withReal(qty), Variable.withString(lotId)],
        updates: {stockLotsTable},
        updateKind: UpdateKind.update,
      );
      await into(lotConsumptionsTable).insert(
        LotConsumptionsTableCompanion.insert(
          id: const Uuid().v4(),
          lotId: lotId,
          saleItemId: Value(r.readNullable<String>('sale_item_id')),
          movement: 'refund_reversal',
          quantity: -qty,
          unitCostSantim: r.read<int>('unit_cost_santim'),
          consumedAt: at,
        ),
      );
    }
  }

  /// Partial-return path (docs/19 §13.3): put [quantity] of one sale item
  /// back onto the lots it was drawn from, oldest draw first, skipping what
  /// earlier returns already put back. Writes one `refund_reversal` row
  /// (negative quantity) per lot touched and returns those lots with the
  /// quantity and unit cost restored, plus the weighted unit cost — the
  /// caller needs the same lots again for a damaged unit's spoilage pair.
  ///
  /// Units sold beyond any lot (oversell) have no consumption row and so
  /// nothing to return to; they still count towards stock via the caller.
  Future<ReversedConsumption> reverseItemConsumptions({
    required String saleItemId,
    required Decimal quantity,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now().toUtc();
    // Ordered by insertion (rowid), not by id: every lot one sale line draws
    // from is written with the SAME consumed_at and a random UUID id, so
    // ordering by id would hand the units back to the lots in an arbitrary
    // order. rowid is the exact draw order, which is what "FIFO over that
    // item's consumptions" means.
    final rows = await customSelect(
      'SELECT lot_id, quantity, unit_cost_santim FROM lot_consumptions '
      "WHERE sale_item_id = ? AND movement IN ('sale', 'refund_reversal') "
      'ORDER BY consumed_at ASC, rowid ASC',
      variables: [Variable.withString(saleItemId)],
      readsFrom: {lotConsumptionsTable},
    ).get();
    // Net outstanding per lot, in first-draw order (sale rows are positive,
    // earlier reversals negative). Cost is the lot's original draw cost.
    final outstanding = <String, Decimal>{};
    final cost = <String, int>{};
    for (final c in rows) {
      final lotId = c.read<String>('lot_id');
      outstanding[lotId] = (outstanding[lotId] ?? Decimal.zero) +
          _dec(c.read<double>('quantity'));
      cost.putIfAbsent(lotId, () => c.read<int>('unit_cost_santim'));
    }

    final touched = <ReversedLot>[];
    var remaining = quantity;
    var costAccum = Decimal.zero; // santim
    for (final entry in outstanding.entries) {
      if (remaining <= Decimal.zero) break;
      final take = entry.value < remaining ? entry.value : remaining;
      if (take <= Decimal.zero) continue;
      final lotId = entry.key;
      final unitCost = cost[lotId]!;
      await customUpdate(
        'UPDATE stock_lots SET qty_remaining = qty_remaining + ? WHERE id = ?',
        variables: [Variable.withReal(take.toDouble()), Variable.withString(lotId)],
        updates: {stockLotsTable},
        updateKind: UpdateKind.update,
      );
      await into(lotConsumptionsTable).insert(
        LotConsumptionsTableCompanion.insert(
          id: const Uuid().v4(),
          lotId: lotId,
          saleItemId: Value(saleItemId),
          movement: 'refund_reversal',
          quantity: -take.toDouble(),
          unitCostSantim: unitCost,
          consumedAt: at,
        ),
      );
      touched.add(ReversedLot(lotId: lotId, quantity: take, unitCostSantim: unitCost));
      costAccum += take * Decimal.fromInt(unitCost);
      remaining -= take;
    }
    final restored = quantity - remaining;
    final weighted = restored <= Decimal.zero
        ? 0
        : (costAccum / restored)
            .toDecimal(scaleOnInfinitePrecision: 12)
            .round()
            .toBigInt()
            .toInt();
    return ReversedConsumption(lots: touched, unitCostSantim: weighted);
  }

  /// The damaged half of a return: the unit came back onto its lot (via
  /// [reverseItemConsumptions]) but cannot be sold, so it goes straight back
  /// off as `spoilage` on the same lots at the same cost. Net lot quantity
  /// unchanged; the loss shows up in spoilage reporting instead of vanishing.
  Future<void> spoilReturnedLots({
    required String saleItemId,
    required List<ReversedLot> lots,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now().toUtc();
    for (final lot in lots) {
      await customUpdate(
        'UPDATE stock_lots SET qty_remaining = qty_remaining - ? WHERE id = ?',
        variables: [
          Variable.withReal(lot.quantity.toDouble()),
          Variable.withString(lot.lotId),
        ],
        updates: {stockLotsTable},
        updateKind: UpdateKind.update,
      );
      await into(lotConsumptionsTable).insert(
        LotConsumptionsTableCompanion.insert(
          id: const Uuid().v4(),
          lotId: lot.lotId,
          saleItemId: Value(saleItemId),
          movement: 'spoilage',
          quantity: lot.quantity.toDouble(),
          unitCostSantim: lot.unitCostSantim,
          consumedAt: at,
        ),
      );
    }
  }

  /// Mirror pass: replace local lots with the server's open lots, except for
  /// products that still have pending local sync events (their local lots are
  /// ahead of what the server knows — local wins until the queue drains).
  ///
  /// Orphaned lot_consumptions rows (their lot got replaced) are left in
  /// place: per-batch reporting is server-side, local rows only support the
  /// offline refund-reversal path.
  Future<void> replaceFromServer(
    List<StockLot> lots,
    Set<String> skipProductIds,
  ) async {
    await transaction(() async {
      if (skipProductIds.isEmpty) {
        await delete(stockLotsTable).go();
      } else {
        await (delete(stockLotsTable)
              ..where((t) => t.productId.isNotIn(skipProductIds.toList())))
            .go();
      }
      final toInsert =
          lots.where((l) => !skipProductIds.contains(l.productId)).toList();
      await batch((b) {
        for (final l in toInsert) {
          b.insert(
            stockLotsTable,
            StockLotsTableCompanion.insert(
              id: l.id,
              productId: l.productId,
              qtyReceived: l.qtyReceived.toDouble(),
              qtyRemaining: l.qtyRemaining.toDouble(),
              unitCostSantim: santimFromDecimal(l.unitCost),
              expiryDate: Value(
                l.expiryDate == null ? null : expiryDateString(l.expiryDate!),
              ),
              receivedAt: l.receivedAt,
              note: Value(l.note),
            ),
            mode: InsertMode.insertOrReplace,
          );
        }
      });
    });
  }

  /// Open lots expiring within [days] (or already expired), joined with their
  /// product, for the inventory "expiring soon" view. Reactive.
  Stream<List<ExpiringLot>> watchExpiring({required String shopId, int days = 7}) {
    final now = DateTime.now();
    final horizon =
        expiryDateString(DateTime(now.year, now.month, now.day + days));
    return customSelect(
      'SELECT l.id, l.product_id, l.qty_received, l.qty_remaining, '
      '       l.unit_cost_santim, l.expiry_date, l.received_at, l.note, '
      '       p.name AS product_name, p.unit AS product_unit '
      'FROM stock_lots l '
      'JOIN products p ON p.id = l.product_id '
      'WHERE l.qty_remaining > 0 AND l.expiry_date IS NOT NULL '
      '  AND l.expiry_date <= ? AND p.deleted_at IS NULL AND p.shop_id = ? '
      'ORDER BY l.expiry_date ASC, l.received_at ASC',
      variables: [Variable.withString(horizon), Variable.withString(shopId)],
      readsFrom: {stockLotsTable, db.productsTable},
    ).watch().map(
      (rows) => rows.map((r) {
        return ExpiringLot(
          lot: StockLot(
            id: r.read<String>('id'),
            productId: r.read<String>('product_id'),
            qtyReceived: _dec(r.read<double>('qty_received')),
            qtyRemaining: _dec(r.read<double>('qty_remaining')),
            unitCost: decimalFromSantim(r.read<int>('unit_cost_santim')),
            expiryDate: DateTime.parse(r.read<String>('expiry_date')),
            receivedAt: r.read<DateTime>('received_at'),
            note: r.readNullable<String>('note'),
          ),
          productName: r.read<String>('product_name'),
          productUnit: r.read<String>('product_unit'),
        );
      }).toList(),
    );
  }
}
