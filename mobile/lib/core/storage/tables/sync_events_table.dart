import 'package:drift/drift.dart';

@DataClassName('SyncEventRow')
class SyncEventsTable extends Table {
  @override
  String get tableName => 'sync_events';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get clientEventId => text().unique()();
  TextColumn get op => text()();
  TextColumn get payload => text()();
  DateTimeColumn get occurredAt => dateTime()();
  DateTimeColumn get enqueuedAt => dateTime().withDefault(currentDateAndTime)();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
}
