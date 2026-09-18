import 'package:drift/drift.dart';

@DataClassName('SaleRow')
class SalesTable extends Table {
  @override
  String get tableName => 'sales';

  TextColumn get id => text()();
  TextColumn get shopId => text()();
  TextColumn get shiftId => text().nullable()();
  TextColumn get userId => text()();
  /// Money columns are stored as int64 santim (1 birr = 100 santim).
  IntColumn get subtotal => integer()();
  IntColumn get discount => integer().withDefault(const Constant(0))();
  IntColumn get total => integer()();
  IntColumn get costTotal => integer()();
  TextColumn get paymentMethod => text()();
  TextColumn get status => text().withDefault(const Constant('completed'))();
  DateTimeColumn get occurredAt => dateTime()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SaleItemRow')
class SaleItemsTable extends Table {
  @override
  String get tableName => 'sale_items';

  TextColumn get id => text()();
  TextColumn get saleId =>
      text().references(SalesTable, #id, onDelete: KeyAction.cascade)();
  TextColumn get productId => text()();
  TextColumn get productNameSnapshot => text()();
  RealColumn get quantity => real()();

  /// Money columns are stored as int64 santim (1 birr = 100 santim).
  IntColumn get unitPrice => integer()();
  IntColumn get unitCost => integer()();

  /// Price before any per-line discount (Phase 3 line pricing), int64
  /// santim. Null = same as [unitPrice].
  IntColumn get listPrice => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
