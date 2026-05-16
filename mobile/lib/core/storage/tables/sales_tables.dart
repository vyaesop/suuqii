import 'package:drift/drift.dart';

@DataClassName('SaleRow')
class SalesTable extends Table {
  @override
  String get tableName => 'sales';

  TextColumn get id => text()();
  TextColumn get shopId => text()();
  TextColumn get shiftId => text().nullable()();
  TextColumn get userId => text()();
  RealColumn get subtotal => real()();
  RealColumn get discount => real().withDefault(const Constant(0))();
  RealColumn get total => real()();
  RealColumn get costTotal => real()();
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
  TextColumn get saleId => text().references(SalesTable, #id, onDelete: KeyAction.cascade)();
  TextColumn get productId => text()();
  TextColumn get productNameSnapshot => text()();
  RealColumn get quantity => real()();
  RealColumn get unitPrice => real()();
  RealColumn get unitCost => real()();

  @override
  Set<Column> get primaryKey => {id};
}
