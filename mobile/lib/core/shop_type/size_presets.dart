/// Size-set presets for the style wizard (docs/19-boutique-shop-type.md
/// §6.2). Presets are constants in the app, not rows in the DB: the style
/// stores only the preset *key* (`styles.size_set`), so "add missing sizes"
/// can offer the rest of the run later. Labels stay Latin/numeric everywhere —
/// that is how tags are written in Ethiopian shops.
library;

class SizePreset {
  const SizePreset({required this.key, required this.sizes});

  /// Wire value of `styles.size_set`.
  final String key;

  /// Sizes in run order. Empty for [freeSize] (no size dimension) and
  /// [customSizes] (the owner types their own).
  final List<String> sizes;

  bool get hasFixedSizes => sizes.isNotEmpty;
}

const letterSizes = SizePreset(
  key: 'letter',
  sizes: ['XS', 'S', 'M', 'L', 'XL', 'XXL', '3XL'],
);

/// EU numeric — tops, dresses.
const numericSizes = SizePreset(
  key: 'numeric',
  sizes: ['34', '36', '38', '40', '42', '44', '46', '48'],
);

/// Waist inches — trousers, jeans.
const waistSizes = SizePreset(
  key: 'waist',
  sizes: ['26', '28', '30', '32', '34', '36', '38', '40', '42'],
);

const shoeEuSizes = SizePreset(
  key: 'shoe_eu',
  sizes: ['35', '36', '37', '38', '39', '40', '41', '42', '43', '44', '45', '46'],
);

const kidsAgeSizes = SizePreset(
  key: 'kids_age',
  sizes: [
    '0–3m',
    '3–6m',
    '6–12m',
    '1y',
    '2y',
    '3y',
    '4y',
    '6y',
    '8y',
    '10y',
    '12y',
    '14y',
  ],
);

/// One size fits all: the style has no size dimension, so there is one
/// variant per colour (or a single variant when there are no colours).
const freeSize = SizePreset(key: 'free', sizes: []);

/// Owner types a comma-separated list.
const customSizes = SizePreset(key: 'custom', sizes: []);

const sizePresets = [
  letterSizes,
  numericSizes,
  waistSizes,
  shoeEuSizes,
  kidsAgeSizes,
  freeSize,
  customSizes,
];

SizePreset? sizePresetByKey(String? key) {
  for (final preset in sizePresets) {
    if (preset.key == key) return preset;
  }
  return null;
}

/// `"S, M ,L,,"` → `["S", "M", "L"]`: trims, drops blanks, keeps first
/// occurrence of duplicates (case-sensitive — "m" and "M" are different tags).
List<String> parseCustomSizes(String text) {
  final seen = <String>{};
  final out = <String>[];
  for (final raw in text.split(RegExp(r'[,\n;]'))) {
    final size = raw.trim();
    if (size.isEmpty || !seen.add(size)) continue;
    out.add(size);
  }
  return out;
}

/// Sort sizes for display: preset order when the style has a known preset,
/// otherwise the order they were first seen. Sizes outside the preset (added
/// as custom later) go after the preset ones, in input order.
List<String> orderSizes(Iterable<String> sizes, {String? presetKey}) {
  final preset = sizePresetByKey(presetKey);
  final distinct = <String>[];
  for (final s in sizes) {
    if (!distinct.contains(s)) distinct.add(s);
  }
  if (preset == null || !preset.hasFixedSizes) return distinct;
  final rank = {
    for (var i = 0; i < preset.sizes.length; i++) preset.sizes[i]: i,
  };
  final inPreset = distinct.where(rank.containsKey).toList()
    ..sort((a, b) => rank[a]!.compareTo(rank[b]!));
  final extra = distinct.where((s) => !rank.containsKey(s));
  return [...inPreset, ...extra];
}
