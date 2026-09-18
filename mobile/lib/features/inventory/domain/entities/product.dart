import 'package:decimal/decimal.dart';

class Product {
  const Product({
    required this.id,
    required this.shopId,
    required this.name,
    required this.purchasePrice,
    required this.sellingPrice,
    required this.stock,
    required this.lowStockThreshold,
    required this.unit,
    this.category,
    this.barcode,
    this.imageUrl,
    this.clientUpdatedAt,
    this.styleId,
    this.size,
    this.color,
    this.sku,
    this.minSellingPrice,
  });

  final String id;
  final String shopId;

  /// For a variant this is the composed display name
  /// ("Slim jeans · 32 · Blue", core/shop_type/variant_naming.dart), so
  /// receipts, search folding and `product_name_snapshot` need no special
  /// casing.
  final String name;
  final String? category;
  final Decimal purchasePrice;
  final Decimal sellingPrice;
  final Decimal stock;
  final Decimal lowStockThreshold;
  final String unit;
  final String? barcode;

  /// Own image; variants usually have none and fall back to the style image
  /// at the widget level (`imageUrl ?? style.imageUrl`).
  final String? imageUrl;
  final DateTime? clientUpdatedAt;

  /// Boutique variant fields (docs/19 §3). All null for ordinary products.
  final String? styleId;
  final String? size;
  final String? color;
  final String? sku;

  /// Haggling floor; null = no floor set.
  final Decimal? minSellingPrice;

  bool get isLowStock => stock <= lowStockThreshold;

  bool get isVariant => styleId != null;

  Product copyWith({
    String? name,
    String? category,
    Decimal? stock,
    Decimal? sellingPrice,
    String? sku,
    DateTime? clientUpdatedAt,
    bool clearSku = false,
  }) =>
      Product(
        id: id,
        shopId: shopId,
        name: name ?? this.name,
        category: category ?? this.category,
        purchasePrice: purchasePrice,
        sellingPrice: sellingPrice ?? this.sellingPrice,
        stock: stock ?? this.stock,
        lowStockThreshold: lowStockThreshold,
        unit: unit,
        barcode: barcode,
        imageUrl: imageUrl,
        clientUpdatedAt: clientUpdatedAt ?? this.clientUpdatedAt,
        styleId: styleId,
        size: size,
        color: color,
        sku: clearSku ? null : (sku ?? this.sku),
        minSellingPrice: minSellingPrice,
      );
}

/// A single stock movement (sale, restock, adjustment, refund).
class InventoryMovement {
  const InventoryMovement({
    required this.id,
    required this.movement,
    required this.quantityDelta,
    required this.createdAt,
    this.reason,
    this.referenceType,
    this.referenceId,
    this.userId,
  });

  final String id;
  final String movement;
  final Decimal quantityDelta;
  final String? reason;
  final String? referenceType;
  final String? referenceId;
  final String? userId;
  final DateTime createdAt;
}
