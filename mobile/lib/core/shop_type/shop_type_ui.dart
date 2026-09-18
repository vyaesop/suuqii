import 'package:flutter/material.dart';

import 'package:suuqii/core/shop_type/shop_features.dart';
import 'package:suuqii/l10n/app_localizations.dart';

/// Icon for a shop type, shared by registration, the shop switcher and the
/// shop-name field so a boutique looks the same everywhere.
IconData shopTypeIcon(String shopType) => switch (shopType) {
      'bakery' => Icons.bakery_dining_rounded,
      'boutique' => Icons.checkroom_rounded,
      _ => Icons.storefront_rounded,
    };

/// Feature-driven wording. The spoilage flow is the same `stock.spoil` op for
/// every shop, but "spoilage" is the wrong word for a torn shirt — boutiques
/// read "Damaged / lost" instead (docs/19 §13.1).
extension ShopFeaturesL10n on ShopFeatures {
  /// Action title: "Record spoilage" / "Record damaged / lost".
  String spoilageActionTitle(AppLocalizations l) =>
      isDamagedLostWording ? l.damagedLostTitle : l.spoilageTitle;

  /// Noun used in movement lists and reports: "Spoilage" / "Damaged / lost".
  String spoilageNoun(AppLocalizations l) => isDamagedLostWording
      ? l.damagedLostMovement
      : l.productMovementSpoilage;

  /// Confirmation toast after recording.
  String spoilageSuccess(AppLocalizations l) =>
      isDamagedLostWording ? l.damagedLostSuccess : l.spoilageSuccess;
}
