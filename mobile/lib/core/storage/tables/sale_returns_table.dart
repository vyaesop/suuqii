import 'package:drift/drift.dart';

import 'package:suuqii/core/storage/tables/sales_tables.dart';

/// A partial return / exchange against a sale (docs/19 §3.1, §13.3
/// `sale.return`). Schema shipped with Drift v11 so the version is bumped
/// once; the return flow itself lands in Phase 2.
@DataClassName('SaleReturnRow')
class SaleReturnsTable extends Table {
  @override
  String get tableName => 'sale_returns';

  TextColumn get id => text()();
  TextColumn get shopId => text()();
  TextColumn get saleId => text()();
  TextColumn get userId => text()();
  TextColumn get shiftId => text().nullable()();
  DateTimeColumn get occurredAt => dateTime()();

  /// Money handed back, int64 santim. 0 for an even exchange.
  IntColumn get refundAmount => integer()();

  /// cash | mobile_money | null when netted into an exchange.
  TextColumn get refundMethod => text().nullable()();

  /// The replacement sale when this return is half of an exchange.
  TextColumn get exchangeSaleId => text().nullable()();

  /// wrong_size | defect | changed_mind | other.
  TextColumn get reason => text().nullable()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SaleReturnItemRow')
class SaleReturnItemsTable extends Table {
  @override
  String get tableName => 'sale_return_items';

  TextColumn get id => text()();
  TextColumn get returnId =>
      text().references(SaleReturnsTable, #id, onDelete: KeyAction.cascade)();
  TextColumn get saleItemId => text().references(SaleItemsTable, #id)();
  RealColumn get quantity => real()();

  /// resellable | damaged.
  TextColumn get condition => text()();

  /// Credited per unit, int64 santim (= sale_items.unit_price).
  IntColumn get unitPrice => integer()();

  @override
  Set<Column> get primaryKey => {id};
}
