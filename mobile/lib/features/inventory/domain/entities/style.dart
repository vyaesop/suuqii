import 'package:decimal/decimal.dart';

/// The shared half of a boutique garment (docs/19-boutique-shop-type.md §2).
/// Every size × colour of it is an ordinary product row with `styleId == id`.
class Style {
  const Style({
    required this.id,
    required this.shopId,
    required this.name,
    required this.defaultSellingPrice,
    required this.defaultPurchasePrice,
    this.brand,
    this.category,
    this.segment,
    this.imageUrl,
    this.sizeSet,
    this.skuPrefix,
    this.clientUpdatedAt,
  });

  final String id;
  final String shopId;
  final String name;
  final String? brand;
  final String? category;

  /// men | women | kids | unisex, or null.
  final String? segment;
  final String? imageUrl;
  final Decimal defaultSellingPrice;

  /// "0" for cashiers — the server masks costs in `GET /v1/styles`.
  final Decimal defaultPurchasePrice;

  /// Size preset key (`letter`, `waist`, …); null = custom sizes.
  final String? sizeSet;
  final String? skuPrefix;
  final DateTime? clientUpdatedAt;

  Style copyWith({
    String? name,
    String? brand,
    String? category,
    String? segment,
    String? imageUrl,
    Decimal? defaultSellingPrice,
    Decimal? defaultPurchasePrice,
    String? sizeSet,
    String? skuPrefix,
    DateTime? clientUpdatedAt,
    bool clearBrand = false,
    bool clearCategory = false,
    bool clearSegment = false,
    bool clearImageUrl = false,
    bool clearSizeSet = false,
    bool clearSkuPrefix = false,
  }) =>
      Style(
        id: id,
        shopId: shopId,
        name: name ?? this.name,
        brand: clearBrand ? null : (brand ?? this.brand),
        category: clearCategory ? null : (category ?? this.category),
        segment: clearSegment ? null : (segment ?? this.segment),
        imageUrl: clearImageUrl ? null : (imageUrl ?? this.imageUrl),
        defaultSellingPrice: defaultSellingPrice ?? this.defaultSellingPrice,
        defaultPurchasePrice:
            defaultPurchasePrice ?? this.defaultPurchasePrice,
        sizeSet: clearSizeSet ? null : (sizeSet ?? this.sizeSet),
        skuPrefix: clearSkuPrefix ? null : (skuPrefix ?? this.skuPrefix),
        clientUpdatedAt: clientUpdatedAt ?? this.clientUpdatedAt,
      );
}

/// Style-level aggregates computed from its live variants, for the inventory
/// list and the POS grid. Always derived locally from `products` so it stays
/// consistent with the stock counts shown next to it (the server's
/// `variant_count` / `stock_total` / `sizes_out` are the same numbers a sync
/// cycle later).
class StyleSummary {
  const StyleSummary({
    required this.style,
    required this.variantCount,
    required this.stockTotal,
    required this.sizesOut,
  });

  final Style style;
  final int variantCount;
  final Decimal stockTotal;

  /// Variants at or below their low-stock threshold.
  final int sizesOut;

  /// A "broken run": some sizes are gone while others are still on the shelf
  /// — the buying-trip signal (docs/19 §1).
  bool get hasBrokenRun =>
      sizesOut > 0 && sizesOut < variantCount && stockTotal > Decimal.zero;
}

const styleSegments = ['men', 'women', 'kids', 'unisex'];
