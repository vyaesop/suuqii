/// Ethiopic (ፊደል) search folding.
///
/// Amharic has several letter families that sound identical and are used
/// interchangeably in everyday spelling: ሀ/ሐ/ኀ, ሰ/ሠ, አ/ዐ, ጸ/ፀ. A product
/// saved as "ሳሙና" must be findable by a cashier who types "ሣሙና" — to them it
/// is the same word. Fold both the haystack and the needle through
/// [foldForSearch] before substring-matching.
///
/// Folds applied (each series maps order-by-order, ኻልቤት to ካዕብ):
///   ሐ-series, ኀ-series → ሀ-series      (all "h")
///   ሠ-series           → ሰ-series      (both "s")
///   ዐ-series           → አ-series      (both glottal)
///   ፀ-series           → ጸ-series      (both "ts'")
///   ሧ → ሷ, ሗ → ኋ                       (labialized variants)
///   ሃ → ሀ, ኣ → አ                       (1st/4th orders sound the same
///                                        for laryngeals; spelling varies)
///   ዉ → ው                              ("ነው" vs "ነዉ" both common)
///   ፡ (Ethiopic wordspace) → ' '
///
/// ASCII is lowercased, preserving the case-insensitive matching the previous
/// SQL `LIKE` gave Latin-script names.
library;

final Map<int, int> _fold = _buildFold();

Map<int, int> _buildFold() {
  final m = <int, int>{};
  void series(String from, String to) {
    assert(from.length == to.length, 'fold series must map 1:1');
    for (var i = 0; i < from.length; i++) {
      m[from.codeUnitAt(i)] = to.codeUnitAt(i);
    }
  }

  // Targets are already canonical (note ሀ not ሃ, አ not ኣ in 4th position),
  // so a single pass per character suffices.
  series('ሐሑሒሓሔሕሖ', 'ሀሁሂሀሄህሆ');
  series('ኀኁኂኃኄኅኆ', 'ሀሁሂሀሄህሆ');
  series('ሠሡሢሣሤሥሦ', 'ሰሱሲሳሴስሶ');
  series('ዐዑዒዓዔዕዖ', 'አኡኢአኤእኦ');
  series('ፀፁፂፃፄፅፆ', 'ጸጹጺጻጼጽጾ');
  series('ሧ', 'ሷ');
  series('ሗ', 'ኋ');
  series('ሃ', 'ሀ');
  series('ኣ', 'አ');
  series('ዉ', 'ው');
  series('፡', ' ');
  return m;
}

/// Canonical form of [s] for search matching. Not for display or storage —
/// it deliberately erases spelling distinctions.
String foldForSearch(String s) {
  // Ethiopic is entirely in the BMP, so UTF-16 code units are safe here;
  // astral characters (emoji, etc.) pass through as unmapped surrogate pairs.
  final b = StringBuffer();
  for (final code in s.toLowerCase().codeUnits) {
    b.writeCharCode(_fold[code] ?? code);
  }
  return b.toString();
}

/// Whether [haystack] contains [needle] under [foldForSearch] equivalence.
bool matchesSearch(String haystack, String needle) =>
    foldForSearch(haystack).contains(foldForSearch(needle));
