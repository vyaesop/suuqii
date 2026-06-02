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
  /// Unit in which [quantity] is expressed. May differ from the supply's unit
  /// (e.g. supply in "kg", recipe in "g"). Null means same unit as supply.
  TextColumn get recipeUnit => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
