import 'package:drift/drift.dart';

@DataClassName('DebtRow')
class DebtsTable extends Table {
  @override
  String get tableName => 'debts';

  TextColumn get id => text()();
  TextColumn get shopId => text()();
  TextColumn get saleId => text().nullable()();
  TextColumn get customerName => text()();
  TextColumn get customerPhone => text().nullable()();
  /// Money columns are stored as int64 santim (1 birr = 100 santim).
  IntColumn get amountOwed => integer()();
  IntColumn get amountPaid => integer().withDefault(const Constant(0))();
  DateTimeColumn get dueDate => dateTime().nullable()();
  TextColumn get status => text().withDefault(const Constant('open'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DebtPaymentRow')
class DebtPaymentsTable extends Table {
  @override
  String get tableName => 'debt_payments';

  TextColumn get id => text()();
  TextColumn get debtId =>
      text().references(DebtsTable, #id, onDelete: KeyAction.cascade)();
  TextColumn get shopId => text()();
  TextColumn get shiftId => text().nullable()();
  /// Money: int64 santim (1 birr = 100 santim).
  IntColumn get amount => integer()();
  DateTimeColumn get paidAt => dateTime()();
  TextColumn get method => text()();
  TextColumn get userId => text()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
