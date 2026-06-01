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
  RealColumn get costPerUnit => real().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
