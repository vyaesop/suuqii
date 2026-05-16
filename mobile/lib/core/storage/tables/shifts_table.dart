import 'package:drift/drift.dart';

@DataClassName('ShiftRow')
class ShiftsTable extends Table {
  @override
  String get tableName => 'shifts';

  TextColumn get id => text()();
  TextColumn get shopId => text()();
  TextColumn get userId => text()();
  DateTimeColumn get openedAt => dateTime()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  RealColumn get openingCash => real()();
  RealColumn get declaredClosingCash => real().nullable()();
  RealColumn get expectedClosingCash => real().nullable()();
  TextColumn get note => text().nullable()();
  TextColumn get deviceId => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
