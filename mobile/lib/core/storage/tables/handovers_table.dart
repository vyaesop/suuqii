import 'package:drift/drift.dart';

/// A baker → counter handover (docs/18-handovers.md).
///
/// Deliberately carries no money and moves no stock: `production.record`
/// already created the units and the sale will consume them. What this stores
/// is the *control* — the baker's declared count and the counter's independent
/// count of the same transfer, so a gap between them has two names on it.
@DataClassName('HandoverRow')
class HandoversTable extends Table {
  @override
  String get tableName => 'handovers';

  TextColumn get id => text()();
  TextColumn get shopId => text()();

  /// The baker who handed the goods over.
  TextColumn get fromUserId => text()();

  /// Intended recipient, when the baker named one.
  TextColumn get toUserId => text().nullable()();

  /// Whoever actually counted — not necessarily [toUserId].
  TextColumn get acceptedByUserId => text().nullable()();
  TextColumn get shiftId => text().nullable()();

  DateTimeColumn get occurredAt => dateTime()();
  DateTimeColumn get acceptedAt => dateTime().nullable()();

  /// 'pending' | 'accepted' | 'disputed'.
  TextColumn get status => text().withDefault(const Constant('pending'))();

  TextColumn get note => text().nullable()();
  TextColumn get acceptNote => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One product line of a handover: two counts of the same quantity.
///
/// Unlike the server, `variance` is not a generated column — SQLite computes it
/// in the query instead. Keeping it out of the schema means there is exactly
/// one definition of the difference on each side and no chance of a stored
/// local value drifting from the server's.
@DataClassName('HandoverItemRow')
class HandoverItemsTable extends Table {
  @override
  String get tableName => 'handover_items';

  TextColumn get id => text()();
  TextColumn get handoverId => text()();
  TextColumn get productId => text()();

  /// Snapshot so a later rename doesn't rewrite history.
  TextColumn get productNameSnapshot => text()();

  /// The baker's count.
  RealColumn get qtyHanded => real()();

  /// The counter's count. Null until accepted.
  RealColumn get qtyReceived => real().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
