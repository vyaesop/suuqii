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

/// Itemized cash-drawer math for a shift. Shown to the cashier so they
/// can see exactly how the expected balance is derived.
class ShiftBreakdown {
  const ShiftBreakdown({
    required this.openingCash,
    required this.cashSales,
    required this.debtCollected,
    required this.expenses,
    required this.cashRefunds,
  });

  final Decimal openingCash;
  final Decimal cashSales;
  final Decimal debtCollected;
  final Decimal expenses;
  final Decimal cashRefunds;

  Decimal get expected =>
      openingCash + cashSales + debtCollected - expenses - cashRefunds;
}


