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
  /// Money columns are stored as int64 santim (1 birr = 100 santim).
  IntColumn get openingCash => integer()();
  IntColumn get declaredClosingCash => integer().nullable()();
  IntColumn get expectedClosingCash => integer().nullable()();
  TextColumn get note => text().nullable()();
  TextColumn get deviceId => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
