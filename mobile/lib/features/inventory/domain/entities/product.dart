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
  });

  final String id;
  final String shopId;
  final String name;
  final String? category;
  final Decimal purchasePrice;
  final Decimal sellingPrice;
  final Decimal stock;
  final Decimal lowStockThreshold;
  final String unit;
  final String? barcode;
  final String? imageUrl;
  final DateTime? clientUpdatedAt;

  bool get isLowStock => stock <= lowStockThreshold;

  /// A single stock movement (restock, sale, adjustment, etc).
  /// Read from `inventory_logs`; produced by sales, adjustments, and refunds.

  Product copyWith({Decimal? stock, Decimal? sellingPrice}) => Product(
        id: id,
        shopId: shopId,
        name: name,
        category: category,
        purchasePrice: purchasePrice,
        sellingPrice: sellingPrice ?? this.sellingPrice,
        stock: stock ?? this.stock,
        lowStockThreshold: lowStockThreshold,
        unit: unit,
        barcode: barcode,
        imageUrl: imageUrl,
        clientUpdatedAt: clientUpdatedAt,
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
