/// Feature table for the three shop types (docs/19-boutique-shop-type.md
/// §13.1). Mirrors `backend/app/core/shop_features.py` exactly.
///
/// Call sites ask for the *feature* they need (`features.hasSupplies`), never
/// for the type string: a fourth shop type then costs one constant here
/// instead of another `if (isBakery || isPharmacy)` at ~30 places.
class ShopFeatures {
  const ShopFeatures({
    required this.shopType,
    required this.hasSupplies,
    required this.hasProduction,
    required this.hasHandovers,
    required this.tracksExpiry,
    required this.allowsOversell,
    required this.hasVariants,
    required this.hasLinePricing,
    required this.hasReturns,
    required this.locksUnit,
    required this.spoilageLabelKey,
    this.defaultUnit = 'piece',
  });

  /// The canonical `shop_type` string this feature set belongs to. An unknown
  /// server type resolves to [regular], so this is `'regular'` for it too —
  /// keep the raw string on `Authenticated.shopType` when it must round-trip.
  final String shopType;

  /// Ingredient supplies tab and supply CRUD (bakery).
  final bool hasSupplies;

  /// Recipes on products and production runs (bakery). Cost is derived from
  /// the recipe, so the purchase-price field is hidden.
  final bool hasProduction;

  /// Baker → counter handovers and the baker role (bakery).
  final bool hasHandovers;

  /// Expiry dates on lots, "expiring soon" list, FEFO badges. Apparel does not
  /// expire, so boutiques hide every expiry input while keeping lots for cost.
  final bool tracksExpiry;

  /// Selling past the on-hand count is a warning, not a block. Bakery stock is
  /// only as current as the last synced handover from the baker's device.
  final bool allowsOversell;

  /// Styles with size × colour variants (boutique).
  final bool hasVariants;

  /// Per-line negotiated price with a floor (boutique, Phase 3).
  final bool hasLinePricing;

  /// Partial returns and exchanges (boutique, Phase 2).
  final bool hasReturns;

  /// Unit picker hidden; every product is [defaultUnit] and quantities are
  /// whole numbers.
  final bool locksUnit;

  /// Unit a new product gets when none is chosen.
  final String defaultUnit;

  /// Which wording the spoilage flow uses: [spoilageLabelSpoilage] ("Record
  /// spoilage") or [spoilageLabelDamagedLost] ("Damaged / lost"). The same
  /// `stock.spoil` op runs underneath either way.
  final String spoilageLabelKey;

  static const spoilageLabelSpoilage = 'spoilage';
  static const spoilageLabelDamagedLost = 'damaged_lost';

  static const regular = ShopFeatures(
    shopType: 'regular',
    hasSupplies: false,
    hasProduction: false,
    hasHandovers: false,
    tracksExpiry: true,
    allowsOversell: false,
    hasVariants: false,
    hasLinePricing: false,
    hasReturns: false,
    locksUnit: false,
    spoilageLabelKey: spoilageLabelSpoilage,
  );

  static const bakery = ShopFeatures(
    shopType: 'bakery',
    hasSupplies: true,
    hasProduction: true,
    hasHandovers: true,
    tracksExpiry: true,
    allowsOversell: true,
    hasVariants: false,
    hasLinePricing: false,
    hasReturns: false,
    locksUnit: false,
    spoilageLabelKey: spoilageLabelSpoilage,
  );

  static const boutique = ShopFeatures(
    shopType: 'boutique',
    hasSupplies: false,
    hasProduction: false,
    hasHandovers: false,
    tracksExpiry: false,
    allowsOversell: false,
    hasVariants: true,
    hasLinePricing: true,
    hasReturns: true,
    locksUnit: true,
    spoilageLabelKey: spoilageLabelDamagedLost,
  );

  /// Every type the app can register. Order is the registration card order.
  static const knownTypes = ['regular', 'bakery', 'boutique'];

  /// Features for [shopType]. Unknown values (a newer server type this build
  /// does not know) fail safe to [regular]: the plain retail surface is the
  /// one every other type is a superset of.
  static ShopFeatures of(String shopType) => switch (shopType) {
        'bakery' => bakery,
        'boutique' => boutique,
        _ => regular,
      };

  bool get isDamagedLostWording =>
      spoilageLabelKey == spoilageLabelDamagedLost;
}
