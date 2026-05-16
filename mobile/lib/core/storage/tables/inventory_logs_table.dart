import 'package:drift/drift.dart';

@DataClassName('InventoryLogRow')
class InventoryLogsTable extends Table {
  @override
  String get tableName => 'inventory_logs';

  TextColumn get id => text()();
  TextColumn get shopId => text()();
  TextColumn get productId => text()();
  TextColumn get movement => text()();
  RealColumn get quantityDelta => real()();
  TextColumn get reason => text().nullable()();
  TextColumn get referenceType => text().nullable()();
  TextColumn get referenceId => text().nullable()();
  TextColumn get userId => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
