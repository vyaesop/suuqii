import 'package:decimal/decimal.dart';

import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/domain/entities/style.dart';

/// One tile of the POS grid: either a plain product or a style whose
/// variants are picked in a second step (docs/19 §6.3).
sealed class CatalogEntry {
  const CatalogEntry();

  /// Stable key for the grid so tiles keep state across list rebuilds.
  String get key;
}

class ProductEntry extends CatalogEntry {
  const ProductEntry(this.product);
  final Product product;

  @override
  String get key => 'p:${product.id}';
}

class StyleEntry extends CatalogEntry {
  const StyleEntry({
    required this.styleId,
    required this.style,
    required this.variants,
  });

  final String styleId;

  /// Null until the styles mirror has run; the tile then falls back to what
  /// the variants themselves carry.
  final Style? style;
  final List<Product> variants;

  @override
  String get key => 's:$styleId';

  /// Style name, or the composed name's head when the style row is missing.
  String get name =>
      style?.name ?? variants.first.name.split(' · ').first;

  String? get imageUrl =>
      style?.imageUrl ??
      variants.map((v) => v.imageUrl).whereType<String>().firstOrNull;

  /// The price shown on the tile. Variants may carry their own overrides, so
  /// the style default is only a fallback when the row is missing.
  Decimal get price => style?.defaultSellingPrice ?? variants.first.sellingPrice;

  Decimal get stockTotal =>
      variants.fold(Decimal.zero, (a, v) => a + v.stock);

  int get sizeCount => variants.map((v) => v.size).whereType<String>().toSet().length;

  /// Some sizes sold out while others remain — the "broken run" dot.
  bool get hasBrokenRun =>
      variants.any((v) => v.stock <= Decimal.zero) &&
      variants.any((v) => v.stock > Decimal.zero);

  bool get isLowStock => variants.every((v) => v.isLowStock);
}

/// Group a name-sorted product list for the POS grid. Variants collapse into
/// one [StyleEntry] per style (first-seen order, so styles land where their
/// name sorts); unstyled products stay as they are.
///
/// Exception: when [query] is an exact SKU/barcode hit, the matching variants
/// are shown ungrouped — a scanned tag must be one tap from the cart, not a
/// tile that opens a picker.
List<CatalogEntry> groupCatalog(
  List<Product> products,
  Map<String, Style> styles, {
  String query = '',
}) {
  final q = query.trim();
  if (q.isNotEmpty && products.every((p) => _matchesIdentifier(p, q))) {
    return [for (final p in products) ProductEntry(p)];
  }
  final out = <CatalogEntry>[];
  final byStyle = <String, List<Product>>{};
  for (final p in products) {
    final styleId = p.styleId;
    if (styleId == null) {
      out.add(ProductEntry(p));
      continue;
    }
    final bucket = byStyle[styleId];
    if (bucket == null) {
      final fresh = [p];
      byStyle[styleId] = fresh;
      out.add(
        StyleEntry(styleId: styleId, style: styles[styleId], variants: fresh),
      );
    } else {
      bucket.add(p);
    }
  }
  return out;
}

bool _matchesIdentifier(Product p, String q) =>
    (p.sku != null && p.sku!.toUpperCase() == q.toUpperCase()) ||
    (p.barcode != null && p.barcode!.isNotEmpty && p.barcode == q);
