import 'package:flutter/foundation.dart';

/// A shop this account may act in, as returned by `GET /v1/shops/mine`.
///
/// The role is per-shop: the same person can be owner of their bakery and a
/// cashier in someone else's shop, and the app's capabilities follow whichever
/// shop is currently active.
@immutable
class ShopOption {
  const ShopOption({
    required this.id,
    required this.name,
    required this.shopType,
    required this.role,
    required this.isActive,
    this.currency = 'ETB',
  });

  factory ShopOption.fromJson(Map<String, dynamic> j) => ShopOption(
        id: j['id'] as String,
        name: j['name'] as String,
        shopType: j['shop_type'] as String? ?? 'regular',
        role: j['role'] as String? ?? 'cashier',
        isActive: j['is_active'] as bool? ?? false,
        currency: j['currency'] as String? ?? 'ETB',
      );

  final String id;
  final String name;
  final String shopType;
  final String role;

  /// True for the shop the current token is scoped to.
  final bool isActive;
  final String currency;

  bool get isBakery => shopType == 'bakery';

  @override
  bool operator ==(Object other) =>
      other is ShopOption &&
      other.id == id &&
      other.isActive == isActive &&
      other.role == role;

  @override
  int get hashCode => Object.hash(id, isActive, role);
}
