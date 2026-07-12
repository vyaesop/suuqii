import 'package:drift/drift.dart';

@DataClassName('ExpenseRow')
class ExpensesTable extends Table {
  @override
  String get tableName => 'expenses';

  TextColumn get id => text()();
  TextColumn get shopId => text()();
  TextColumn get userId => text()();
  TextColumn get shiftId => text().nullable()();
  TextColumn get title => text()();
  /// Money: int64 santim (1 birr = 100 santim).
  IntColumn get amount => integer()();
  TextColumn get category => text().withDefault(const Constant('other'))();
  TextColumn get description => text().nullable()();
  DateTimeColumn get occurredAt => dateTime()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
