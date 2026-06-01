import 'package:decimal/decimal.dart';

class Supply {
  const Supply({
    required this.id,
    required this.shopId,
    required this.name,
    required this.unit,
    required this.quantityOnHand,
    required this.reorderThreshold,
    required this.costPerUnit,
    this.deletedAt,
  });

  final String id;
  final String shopId;
  final String name;
  final String unit;
  final Decimal quantityOnHand;
  final Decimal reorderThreshold;
  final Decimal costPerUnit;
  final DateTime? deletedAt;

  bool get isLow =>
      reorderThreshold > Decimal.zero && quantityOnHand <= reorderThreshold;
}
