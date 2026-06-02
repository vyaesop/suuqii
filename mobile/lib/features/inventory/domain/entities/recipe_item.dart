import 'package:decimal/decimal.dart';
import 'package:suuqii/core/utils/unit_conversion.dart';

class RecipeItem {
  const RecipeItem({
    required this.id,
    required this.shopId,
    required this.productId,
    required this.supplyId,
    required this.quantity,
    this.recipeUnit,
    this.supplyName,
    this.supplyUnit,
    this.supplyCostPerUnit,
  });

  final String id;
  final String shopId;
  final String productId;
  final String supplyId;
  final Decimal quantity;

  /// Unit the recipe quantity is expressed in. Null → same as supplyUnit.
  final String? recipeUnit;

  // Enrichment fields (populated by RecipesRepository)
  final String? supplyName;
  final String? supplyUnit;
  final Decimal? supplyCostPerUnit;

  /// Effective unit used in this recipe line (falls back to supply's unit).
  String get effectiveUnit => recipeUnit ?? supplyUnit ?? 'piece';

  /// Cost of this ingredient line, converting units if necessary.
  Decimal get lineCost {
    if (supplyCostPerUnit == null || supplyUnit == null) return Decimal.zero;
    // Convert recipe quantity → supply unit, then multiply by cost per supply unit.
    final qtyInSupplyUnit = convertUnit(quantity, effectiveUnit, supplyUnit!);
    return qtyInSupplyUnit * supplyCostPerUnit!;
  }
}
