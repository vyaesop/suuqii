/// Variant display name and SKU composition — the shared rule of
/// docs/19-boutique-shop-type.md §13.2, parity-tested against
/// `backend/app/core/variant_naming.py` on the same fixture list.
///
/// Names are recomposed by the server on `style.update`; SKUs are composed
/// here on the client and only *stored* by the server, so collision handling
/// lives in this file alone.
library;

/// U+0020 U+00B7 U+0020 — the separator both sides use verbatim.
const variantNameSeparator = ' · ';

final RegExp _latinColour = RegExp(r'^[A-Za-z][A-Za-z ]*$');
final RegExp _whitespace = RegExp(r'\s+');

/// `"Slim jeans" + "32" + "Blue"` → `"Slim jeans · 32 · Blue"`. Empty or
/// whitespace-only size/colour parts are dropped, so a colour-only bag reads
/// `"Tote · ቀይ"` and a free-size item is just the style name.
String composeVariantName(String styleName, String? size, String? color) {
  final parts = <String>[
    styleName.trim(),
    if (size != null && size.trim().isNotEmpty) size.trim(),
    if (color != null && color.trim().isNotEmpty) color.trim(),
  ];
  return parts.join(variantNameSeparator);
}

/// Colour code for a SKU: first 3 letters of the first word, uppercased, for
/// a Latin colour; anything else (Ethiopic, digits, mixed) is kept verbatim
/// minus whitespace — Ethiopic has no meaningful 3-letter abbreviation and
/// tags are hand-written anyway. [letters] widens the Latin abbreviation for
/// collision resolution.
String _colourCode(String color, {int letters = 3}) {
  final trimmed = color.trim();
  if (trimmed.isEmpty) return '';
  if (_latinColour.hasMatch(trimmed)) {
    final firstWord = trimmed.split(_whitespace).first;
    final take = letters.clamp(1, firstWord.length);
    return firstWord.substring(0, take).toUpperCase();
  }
  return trimmed.replaceAll(_whitespace, '');
}

String _sizeCode(String? size) =>
    size == null ? '' : size.replaceAll(_whitespace, '').toUpperCase();

/// `("JN", "32", "Blue")` → `"JN-32-BLU"`; `("JN", "XL", null)` → `"JN-XL"`;
/// `("BAG", null, "ቀይ")` → `"BAG-ቀይ"`. A null/blank prefix means the shop
/// does not use SKUs → null.
String? composeSku(String? prefix, String? size, String? color) =>
    _composeSku(prefix, size, color, colourLetters: 3);

String? _composeSku(
  String? prefix,
  String? size,
  String? color, {
  required int colourLetters,
}) {
  if (prefix == null || prefix.trim().isEmpty) return null;
  final p = prefix.trim().toUpperCase();
  final s = _sizeCode(size);
  final c = color == null ? '' : _colourCode(color, letters: colourLetters);
  return [p, s, c].where((part) => part.isNotEmpty).join('-');
}

/// One (size, colour) cell of a style matrix.
typedef VariantCell = ({String? size, String? color});

/// SKUs for [cells] with collisions inside one style resolved the way §13.2
/// prescribes: extend the Latin colour code to 4, 5… letters (`BLU` → `BLUE`
/// → …), then append `2`, `3`… to the base code. [taken] holds SKUs already
/// live on the style (for `style.add_variants`), so new ones never reuse
/// them. Output order matches [cells]; a null prefix yields all nulls.
List<String?> resolveSkuCollisions(
  String? prefix,
  List<VariantCell> cells, {
  Set<String> taken = const {},
}) {
  final used = <String>{...taken};
  final out = <String?>[];
  for (final cell in cells) {
    final base = composeSku(prefix, cell.size, cell.color);
    if (base == null) {
      out.add(null);
      continue;
    }
    var sku = base;
    if (used.contains(sku)) {
      sku = _widenColour(prefix!, cell, used) ?? _numberSuffix(base, used);
    }
    used.add(sku);
    out.add(sku);
  }
  return out;
}

/// Try `BLUE`, `BLUES`… up to the whole first word of a Latin colour.
String? _widenColour(String prefix, VariantCell cell, Set<String> used) {
  final color = cell.color?.trim();
  if (color == null || !_latinColour.hasMatch(color)) return null;
  final wordLength = color.split(_whitespace).first.length;
  for (var letters = 4; letters <= wordLength; letters++) {
    final candidate = _composeSku(
      prefix,
      cell.size,
      color,
      colourLetters: letters,
    );
    if (candidate != null && !used.contains(candidate)) return candidate;
  }
  return null;
}

String _numberSuffix(String base, Set<String> used) {
  for (var n = 2;; n++) {
    final candidate = '$base$n';
    if (!used.contains(candidate)) return candidate;
  }
}

/// Rewrite one variant SKU after the style's prefix changed: the old `P-`
/// head is swapped for the new one, null stays null. Mirrors
/// `backend/app/core/variant_naming.py::rewrite_sku_prefix` line for line —
/// the two run independently (the client rewrites optimistically, the server
/// rewrites on `style.update`) and any divergence shows up as a SKU that
/// flips back after sync.
///
/// Clearing the prefix drops the leading segment, and returns null when that
/// leaves nothing — the literal reading of "replace the old prefix with the
/// new one". Callers must therefore treat a null result as "clear this SKU",
/// not "leave it alone".
String? rewriteSkuPrefix(String? sku, String? oldPrefix, String? newPrefix) {
  if (sku == null) return null;
  final old = (oldPrefix ?? '').trim().toUpperCase();
  final fresh = (newPrefix ?? '').trim().toUpperCase();
  if (old.isEmpty) return sku;
  if (sku == old) return fresh.isEmpty ? null : fresh;
  if (!sku.startsWith('$old-')) return sku;
  final rest = sku.substring(old.length + 1);
  if (fresh.isEmpty) return rest.isEmpty ? null : rest;
  return '$fresh-$rest';
}
