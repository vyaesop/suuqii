import 'package:drift/drift.dart';

@DataClassName('ProductRow')
class ProductsTable extends Table {
  @override
  String get tableName => 'products';

  TextColumn get id => text()();
  TextColumn get shopId => text()();
  TextColumn get name => text()();
  TextColumn get category => text().nullable()();
  /// Money columns are stored as int64 santim (1 birr = 100 santim) so SQL
  /// arithmetic stays exact. Convert at the DAO boundary via
  /// santimFromDecimal / decimalFromSantim.
  IntColumn get purchasePrice => integer()();
  IntColumn get sellingPrice => integer()();
  RealColumn get stock => real().withDefault(const Constant(0))();
  RealColumn get lowStockThreshold => real().withDefault(const Constant(0))();
  TextColumn get unit => text().withDefault(const Constant('piece'))();
  TextColumn get barcode => text().nullable()();
  TextColumn get imageUrl => text().nullable()();

  /// Boutique variants (docs/19 §3): the style this size × colour belongs to.
  /// Null for ordinary products. No FK — products and styles mirror from the
  /// server independently and either may arrive first.
  TextColumn get styleId => text().nullable()();
  TextColumn get size => text().nullable()();
  TextColumn get color => text().nullable()();
  TextColumn get sku => text().nullable()();

  /// Haggling floor, int64 santim. Null = no floor set (Phase 3 line pricing).
  IntColumn get minSellingPrice => integer().nullable()();
  DateTimeColumn get clientUpdatedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
