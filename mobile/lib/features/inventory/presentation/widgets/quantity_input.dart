import 'package:decimal/decimal.dart';
import 'package:flutter/services.dart';

/// Keyboard + formatters for a quantity field. Shops whose unit is locked to
/// `piece` (boutique) get an integer-only keyboard — nobody sells 1.5
/// shirts, and a stray decimal separator here would fail at checkout.
TextInputType quantityKeyboard({required bool integerOnly}) => integerOnly
    ? TextInputType.number
    : const TextInputType.numberWithOptions(decimal: true);

List<TextInputFormatter> quantityFormatters({required bool integerOnly}) =>
    integerOnly ? [FilteringTextInputFormatter.digitsOnly] : const [];

/// Parse a typed quantity, accepting a comma as decimal separator.
Decimal? parseQuantity(String text) =>
    Decimal.tryParse(text.trim().replaceAll(',', '.'));

/// "3" for whole quantities, "2.50" otherwise.
String formatQuantity(Decimal value) {
  final n = value.toDouble();
  if (n == n.roundToDouble()) return n.toInt().toString();
  return n.toStringAsFixed(2);
}
