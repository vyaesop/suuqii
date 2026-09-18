"""
Shop-type feature table (docs/19-boutique-shop-type.md §13.1).

Before this module every shop-type decision was a string comparison against
"bakery" scattered across the API, the sync handlers and the reports. Adding a
third type that way would have doubled those sites and left a fourth type
paying the same tax again. Call sites now ask for the *feature* they need
("does this shop have production runs?") and the type→features mapping lives
in exactly one place, mirrored verbatim on the mobile side
(`mobile/lib/core/shop_type/shop_features.dart`).

Unknown or missing shop_type resolves to the regular feature set: failing
towards the plainest behaviour is the safe direction (no supplies, no
oversell, no line pricing).
"""
from __future__ import annotations

from dataclasses import dataclass

REGULAR = "regular"
BAKERY = "bakery"
BOUTIQUE = "boutique"


@dataclass(frozen=True)
class ShopFeatures:
    has_supplies: bool        # ingredient inventory (supplies, recipes)
    has_production: bool      # production.record; also gates the baker role
    has_handovers: bool       # baker → counter handovers
    tracks_expiry: bool       # expiry dates on lots / FEFO ordering
    allows_oversell: bool     # stock may go negative at the till (handover lag)
    has_variants: bool        # styles with size/colour variants
    has_line_pricing: bool    # per-line negotiated price + floor rule
    has_returns: bool         # partial returns / exchanges (sale.return)
    default_unit: str = "piece"
    locks_unit: bool = False  # unit picker hidden; every product is a piece
    # l10n key the UI uses for the spoilage movement: "spoilage" or
    # "damaged_lost". Carried here so both sides label the same movement the
    # same way for the same shop type.
    spoilage_label_key: str = "spoilage"


SHOP_FEATURES: dict[str, ShopFeatures] = {
    REGULAR: ShopFeatures(
        has_supplies=False, has_production=False, has_handovers=False,
        tracks_expiry=True, allows_oversell=False,
        has_variants=False, has_line_pricing=False, has_returns=False,
    ),
    BAKERY: ShopFeatures(
        has_supplies=True, has_production=True, has_handovers=True,
        tracks_expiry=True, allows_oversell=True,
        has_variants=False, has_line_pricing=False, has_returns=False,
    ),
    BOUTIQUE: ShopFeatures(
        has_supplies=False, has_production=False, has_handovers=False,
        tracks_expiry=False, allows_oversell=False,
        has_variants=True, has_line_pricing=True, has_returns=True,
        locks_unit=True, spoilage_label_key="damaged_lost",
    ),
}

SHOP_TYPES: frozenset[str] = frozenset(SHOP_FEATURES)

# For pydantic `pattern=` validators; kept next to the table so the two can
# never disagree.
SHOP_TYPE_PATTERN = "^(" + "|".join(sorted(SHOP_TYPES)) + ")$"


def features_for(shop_type: str | None) -> ShopFeatures:
    """Feature set for [shop_type]; unknown → regular (fail safe)."""
    return SHOP_FEATURES.get(shop_type or "", SHOP_FEATURES[REGULAR])
