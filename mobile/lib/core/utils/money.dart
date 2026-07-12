import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

/// Money utilities. Always operate on Decimal — never double.
///
/// [locale] must be a locale intl has data for — screens should go through
/// `context.money(...)` (core/utils/formats.dart), which verifies the active
/// locale and falls back to `en`. The birr symbol stays "ETB" in every
/// language: it is what Ethiopian retail users read on receipts.
String formatMoney(Decimal amount, {String symbol = 'ETB', String? locale}) {
  final fmt = NumberFormat.decimalPattern(locale);
  return '$symbol ${fmt.format(amount.toDouble())}';
}

Decimal d(num v) => Decimal.parse(v.toString());
Decimal ds(String v) => Decimal.parse(v);

final Decimal _hundred = Decimal.fromInt(100);

/// Persistence boundary: money is stored as int64 **santim** (1 birr = 100
/// santim) so SQL arithmetic (SUM, subtraction) is exact. Domain code keeps
/// using [Decimal] birr; these two helpers are the ONLY sanctioned conversion.
///
/// Rounds half away from zero ("half up" for positive amounts), e.g.
/// 12.345 → 1235 santim.
int santimFromDecimal(Decimal amount) =>
    (amount * _hundred).round().toBigInt().toInt();

/// Exact inverse of [santimFromDecimal]: santim → Decimal birr.
/// `s / 100` always has finite decimal precision, so no scale is needed.
Decimal decimalFromSantim(int santim) =>
    (Decimal.fromInt(santim) / _hundred).toDecimal();
