import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/tables/recipes_table.dart';
import 'package:suuqii/features/inventory/domain/entities/recipe_item.dart';

part 'recipes_dao.g.dart';

@DriftAccessor(tables: [RecipeItemsTable])
class RecipesDao extends DatabaseAccessor<AppDatabase> with _$RecipesDaoMixin {
  RecipesDao(super.db);

  Future<List<RecipeItem>> getForProduct(String productId) async {
    final rows = await (select(recipeItemsTable)
          ..where((t) => t.productId.equals(productId)))
        .get();
    return rows.map(_toDomain).toList();
  }

  /// Batch-load recipes for multiple products in a single query.
  Future<Map<String, List<RecipeItem>>> getForProducts(
    List<String> productIds,
  ) async {
    if (productIds.isEmpty) return {};
    final rows = await (select(recipeItemsTable)
          ..where((t) => t.productId.isIn(productIds)))
        .get();
    final result = <String, List<RecipeItem>>{};
    for (final row in rows) {
      result.putIfAbsent(row.productId, () => []).add(_toDomain(row));
    }
    return result;
  }

  Stream<List<RecipeItem>> watchForProduct(String productId) {
    return (select(recipeItemsTable)
          ..where((t) => t.productId.equals(productId)))
        .watch()
        .map((rows) => rows.map(_toDomain).toList());
  }

  /// Replace all recipe items for a product atomically.
  Future<void> setRecipe(String productId, List<RecipeItem> items) async {
    await (delete(recipeItemsTable)
          ..where((t) => t.productId.equals(productId)))
        .go();
    if (items.isEmpty) return;
    await batch((b) {
      for (final item in items) {
        b.insert(
          recipeItemsTable,
          RecipeItemsTableCompanion.insert(
            id: item.id,
            shopId: item.shopId,
            productId: item.productId,
            supplyId: item.supplyId,
            quantity: item.quantity.toDouble(),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  RecipeItem _toDomain(RecipeItemRow r) => RecipeItem(
        id: r.id,
        shopId: r.shopId,
        productId: r.productId,
        supplyId: r.supplyId,
        quantity: Decimal.parse(r.quantity.toString()),
      );
}
