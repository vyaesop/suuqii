import 'package:decimal/decimal.dart';

/// Formats a date as the canonical "YYYY-MM-DD" string used on the sync wire
/// and in the stock_lots.expiry_date column.
String expiryDateString(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// A purchase/production batch of a product. See docs/16-inventory-lots.md.
class StockLot {
  const StockLot({
    required this.id,
    required this.productId,
    required this.qtyReceived,
    required this.qtyRemaining,
    required this.unitCost,
    required this.receivedAt,
    this.expiryDate,
    this.note,
  });

  final String id;
  final String productId;
  final Decimal qtyReceived;
  final Decimal qtyRemaining;

  /// Birr (Decimal) in the domain; stored as int santim locally and sent as a
  /// decimal string on the wire. "0" for cashiers (server masks costs).
  final Decimal unitCost;

  /// Local calendar date (midnight); null = never expires.
  final DateTime? expiryDate;
  final DateTime receivedAt;
  final String? note;

  bool get isOpen => qtyRemaining > Decimal.zero;

  /// Days from today (local) until expiry: negative = already expired,
  /// 0 = expires today. Null when the lot has no expiry date.
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
