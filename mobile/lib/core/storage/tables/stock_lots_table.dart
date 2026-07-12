import 'package:drift/drift.dart';

/// A purchase/production batch of a product (docs/16-inventory-lots.md).
///
/// Sales consume lots FEFO (first-expiry-first-out, then FIFO by receipt
/// time), which is what makes per-batch margins exact instead of
/// weighted-average mush.
@DataClassName('StockLotRow')
class StockLotsTable extends Table {
  @override
  String get tableName => 'stock_lots';

  TextColumn get id => text()();
  TextColumn get productId => text()();
  RealColumn get qtyReceived => real()();
  RealColumn get qtyRemaining => real()();

  /// Money: int64 santim (1 birr = 100 santim), same convention as products.
  IntColumn get unitCostSantim => integer()();

  /// Expiry date stored as a "YYYY-MM-DD" TEXT (matches the sync wire format
  /// exactly and sorts lexicographically == chronologically, so FEFO ordering
  /// and "expired" comparisons work with plain string comparison). Null =
  /// never expires.
  TextColumn get expiryDate => text().nullable()();

  DateTimeColumn get receivedAt => dateTime()();
  TextColumn get note => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One draw-down from a lot: a sale, spoilage, adjustment, or the reversal
/// of a refunded sale (negative quantity). Per-batch margin reports are
/// aggregations over this table (server-side; local rows keep the invariant
/// `product.stock ≈ Σ lots.qty_remaining` truthful offline).
@DataClassName('LotConsumptionRow')
class LotConsumptionsTable extends Table {
  @override
  String get tableName => 'lot_consumptions';

  TextColumn get id => text()();
  TextColumn get lotId => text()();

  /// Set for movement == 'sale' / 'refund_reversal'.
  TextColumn get saleItemId => text().nullable()();

  /// 'sale' | 'spoilage' | 'adjustment' | 'refund_reversal'.
  TextColumn get movement => text()();

  /// Positive = consumed from the lot; refund reversals carry negative qty.
  RealColumn get quantity => real()();

  /// Lot unit cost at consumption time, int64 santim.
  IntColumn get unitCostSantim => integer()();

  DateTimeColumn get consumedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
