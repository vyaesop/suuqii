import 'package:drift/drift.dart';

@DataClassName('SupplyRow')
class SuppliesTable extends Table {
  @override
  String get tableName => 'supplies';

  TextColumn get id => text()();
  TextColumn get shopId => text()();
  TextColumn get name => text()();
  TextColumn get unit => text().withDefault(const Constant('piece'))();
  RealColumn get quantityOnHand => real().withDefault(const Constant(0))();
  RealColumn get reorderThreshold => real().withDefault(const Constant(0))();
  /// Money: int64 santim (1 birr = 100 santim). Quantities above stay real —
  /// they can be fractional (e.g. kg).
  IntColumn get costPerUnit => integer().withDefault(const Constant(0))();

  /// "YYYY-MM-DD" TEXT, same convention as stock_lots.expiry_date.
  /// Ingredients (flour, milk) expire too; supplies stay quantity-tracked
  /// without lots (v1 keeps them simple).
  TextColumn get expiryDate => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
