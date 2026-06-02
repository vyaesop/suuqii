import 'package:decimal/decimal.dart';

/// Unit categories determine which units are inter-convertible.
const Map<String, String> kUnitCategory = {
  // Weight
  'mg': 'weight',
  'g': 'weight',
  'kg': 'weight',
  'quintal': 'weight',
  // Volume
  'ml': 'volume',
  'liter': 'volume',
  // Count / discrete
  'piece': 'count',
  'pack': 'pack',
  'm': 'length',
  'cup': 'volume',
};

/// Compatible display units grouped by supply unit, ordered most-common first.
const Map<String, List<String>> kCompatibleUnits = {
  'kg': ['g', 'kg', 'quintal', 'mg'],
  'g': ['mg', 'g', 'kg', 'quintal'],
  'mg': ['mg', 'g', 'kg', 'quintal'],
  'quintal': ['g', 'kg', 'quintal', 'mg'],
  'liter': ['ml', 'liter'],
  'ml': ['ml', 'liter'],
  'cup': ['ml', 'cup', 'liter'],
  'piece': ['piece'],
  'pack': ['pack'],
  'm': ['m'],
};

/// Factors relative to a canonical base unit (grams for weight, ml for volume).
/// Using string keys so Decimal.parse gives exact rational arithmetic.
const Map<String, String> _toBase = {
  'mg': '0.001',      // 1 mg = 0.001 g
  'g': '1',           // base
  'kg': '1000',       // 1 kg = 1000 g
  'quintal': '100000', // 1 quintal = 100 kg = 100 000 g
  'ml': '1',          // base
  'liter': '1000',    // 1 liter = 1000 ml
  'cup': '240',       // 1 cup ≈ 240 ml
};

/// Convert [qty] expressed in [fromUnit] into [toUnit].
///
/// Returns [qty] unchanged when the units are in different categories
/// (e.g. g → ml is nonsensical) so the caller can still persist the value
/// without crashing.
Decimal convertUnit(Decimal qty, String fromUnit, String toUnit) {
  if (fromUnit == toUnit) return qty;

  final fromFactor = _toBase[fromUnit];
  final toFactor = _toBase[toUnit];

  // Only convert when both units have known factors AND are same-category.
  if (fromFactor == null ||
      toFactor == null ||
      kUnitCategory[fromUnit] != kUnitCategory[toUnit]) {
    return qty;
  }

  // qty (fromUnit) → base → toUnit  using exact Decimal arithmetic
  final base = qty * Decimal.parse(fromFactor);
  return (base / Decimal.parse(toFactor)).toDecimal(
    scaleOnInfinitePrecision: 10,
  );
}

/// Short, human-friendly label for a unit (e.g. "kilogram" → "kg").
/// Already using abbreviations, so this is mostly a pass-through.
String unitLabel(String unit) => unit;

/// Returns the list of recipe-compatible units for a given supply unit.
/// Falls back to [supplyUnit] alone when not in the map.
List<String> compatibleUnits(String supplyUnit) {
  return kCompatibleUnits[supplyUnit] ?? [supplyUnit];
}
