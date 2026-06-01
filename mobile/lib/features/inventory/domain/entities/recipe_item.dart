import 'package:decimal/decimal.dart';

class RecipeItem {
  const RecipeItem({
    required this.id,
    required this.shopId,
    required this.productId,
    required this.supplyId,
    required this.quantity,
    this.supplyName,
    this.supplyUnit,
    this.supplyCostPerUnit,
  });

  final String id;
  final String shopId;
  final String productId;
  final String supplyId;
  final Decimal quantity;
  final String? supplyName;
  final String? supplyUnit;
  final Decimal? supplyCostPerUnit;

  Decimal get lineCost =>
      supplyCostPerUnit != null ? quantity * supplyCostPerUnit! : Decimal.zero;
}
