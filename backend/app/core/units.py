"""Unit conversion for recipe quantities — server-side mirror of the mobile
lib/core/utils/unit_conversion.dart. A recipe may express an ingredient in a
different unit than the supply is stocked in (recipe: 100 g, supply: kg);
converting wrong here would be a 1000× inventory error.
"""
from decimal import Decimal

_CATEGORY = {
    "mg": "weight", "g": "weight", "kg": "weight", "quintal": "weight",
    "ml": "volume", "liter": "volume", "cup": "volume",
    "piece": "count", "pack": "pack", "m": "length",
}

# Factors to a canonical base (grams / ml), exact decimal strings.
_TO_BASE = {
    "mg": Decimal("0.001"),
    "g": Decimal("1"),
    "kg": Decimal("1000"),
    "quintal": Decimal("100000"),
    "ml": Decimal("1"),
    "liter": Decimal("1000"),
    "cup": Decimal("240"),
}


def convert_unit(qty: Decimal, from_unit: str, to_unit: str) -> Decimal:
    """Convert qty between compatible units; returns qty unchanged when the
    units are unknown or in different categories (same fallback the client
    uses, so both sides stay consistent)."""
    if from_unit == to_unit:
        return qty
    f = _TO_BASE.get(from_unit)
    t = _TO_BASE.get(to_unit)
    if f is None or t is None or _CATEGORY.get(from_unit) != _CATEGORY.get(to_unit):
        return qty
    return qty * f / t
