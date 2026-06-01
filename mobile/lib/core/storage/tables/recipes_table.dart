import 'package:drift/drift.dart';

@DataClassName('RecipeItemRow')
class RecipeItemsTable extends Table {
  @override
  String get tableName => 'recipe_items';

  TextColumn get id => text()();
  TextColumn get shopId => text()();
  TextColumn get productId => text()();
  TextColumn get supplyId => text()();
  RealColumn get quantity => real()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
