import 'package:decimal/decimal.dart';

class Shift {
  const Shift({
    required this.id,
    required this.shopId,
    required this.userId,
    required this.openedAt,
    required this.openingCash,
    this.closedAt,
    this.declaredClosingCash,
    this.expectedClosingCash,
    this.note,
  });

  final String id;
  final String shopId;
  final String userId;
  final DateTime openedAt;
  final DateTime? closedAt;
  final Decimal openingCash;
  final Decimal? declaredClosingCash;
  final Decimal? expectedClosingCash;
  final String? note;

  bool get isOpen => closedAt == null;

  Decimal? get variance =>
      (declaredClosingCash == null || expectedClosingCash == null)
          ? null
          : declaredClosingCash! - expectedClosingCash!;
}
