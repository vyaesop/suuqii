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
    this.expiryDate,
    this.deletedAt,
  });

  final String id;
  final String shopId;
  final String name;
  final String unit;
  final Decimal quantityOnHand;
  final Decimal reorderThreshold;
  final Decimal costPerUnit;

  /// Local calendar date (midnight); null = no expiry tracked.
  /// Ingredients expire too — supplies stay quantity-tracked without lots.
  final DateTime? expiryDate;
  final DateTime? deletedAt;

  bool get isLow =>
      reorderThreshold > Decimal.zero && quantityOnHand <= reorderThreshold;

  /// Days from today (local) until expiry: negative = already expired,
  /// 0 = expires today. Null when no expiry date is set.
  int? get daysToExpiry {
    final e = expiryDate;
    if (e == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return DateTime(e.year, e.month, e.day).difference(today).inDays;
  }

  bool get isExpired => (daysToExpiry ?? 1) < 0;

  bool expiresWithin(int days) {
    final d = daysToExpiry;
    return d != null && d <= days;
  }
}
