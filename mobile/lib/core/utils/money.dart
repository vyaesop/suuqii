import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

/// Money utilities. Always operate on Decimal — never double.
final _fmt = NumberFormat.decimalPattern();

String formatMoney(Decimal amount, {String symbol = 'ETB'}) {
  return '$symbol ${_fmt.format(amount.toDouble())}';
}

Decimal d(num v) => Decimal.parse(v.toString());
Decimal ds(String v) => Decimal.parse(v);
