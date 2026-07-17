import 'package:drift/drift.dart';

/// Small key/value store for sync bookkeeping (e.g. the server pull cursor).
/// Lives in the same database as the queue so logout's `clearAllShopData`
/// wipes it atomically with everything else — a fresh login re-pulls from 0.
@DataClassName('SyncMetaRow')
class SyncMetaTable extends Table {
  @override
  String get tableName => 'sync_meta';

  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
