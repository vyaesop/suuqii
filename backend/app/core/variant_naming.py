"""
Variant naming — the shared rule for composing a variant's display name and
SKU (docs/19-boutique-shop-type.md §13.2).

A variant is an ordinary `products` row, so its `name` is what appears on
receipts, in `product_name_snapshot`, in search and in the recent strip. Both
sides compose it the same way so a variant created on a phone and one created
by CSV import look identical. The mobile twin is
`mobile/lib/core/shop_type/variant_naming.dart`; `tests/test_variant_naming.py`
carries the fixture list both implementations must agree on.

The SKU is *client*-composed and server-stored: the server never derives one
on its own. `compose_sku` lives here anyway so the parity fixture can pin the
rule, and `rewrite_sku_prefix` is what `style.update` uses when the prefix
changes.
"""
from __future__ import annotations

import re

NAME_SEP = " · "  # U+0020 U+00B7 U+0020 — "Slim jeans · 32 · Blue"

_LATIN_COLOUR = re.compile(r"^[A-Za-z][A-Za-z ]*$")
_WHITESPACE = re.compile(r"\s+")


def _clean(value: str | None) -> str:
    return (value or "").strip()


def compose_variant_name(style_name: str, size: str | None, color: str | None) -> str:
    """`style · size · color`, skipping empty parts."""
    parts = [_clean(style_name)]
    if _clean(size):
        parts.append(_clean(size))
    if _clean(color):
        parts.append(_clean(color))
    return NAME_SEP.join(parts)


def colour_code(color: str | None) -> str:
    """Latin colour → first three letters of the first word, upper-cased
    ("Blue" → "BLU", "Dark green" → "DAR"). Anything else (Ethiopic, digits,
    mixed) is kept verbatim minus whitespace — there is no meaningful
    three-letter abbreviation of "ቀይ", and hand-written tags copy it anyway."""
    c = _clean(color)
    if not c:
        return ""
    if _LATIN_COLOUR.match(c):
        return c.split(" ", 1)[0][:3].upper()
    return _WHITESPACE.sub("", c)


def compose_sku(prefix: str | None, size: str | None, color: str | None) -> str | None:
    """`PREFIX-SIZE-COLOUR` with empty parts dropped; None when there is no
    prefix (a style without a prefix has no SKUs at all)."""
    p = _clean(prefix).upper()
    if not p:
        return None
    s = _WHITESPACE.sub("", _clean(size)).upper()
    c = colour_code(color)
    return "-".join(part for part in (p, s, c) if part)


def rewrite_sku_prefix(sku: str | None, old_prefix: str | None, new_prefix: str | None) -> str | None:
    """Swap a variant's SKU prefix when its style's `sku_prefix` changes.

    Only SKUs that actually start with the old prefix are touched — a SKU the
    owner typed by hand keeps its shape. Null stays null. Setting the prefix to
    empty drops the leading segment (and the whole SKU when nothing is left),
    which is the literal reading of "replace the old prefix with the new one".
    """
    if sku is None:
        return None
    old = _clean(old_prefix).upper()
    new = _clean(new_prefix).upper()
    if not old:
        return sku
    if sku == old:
        return new or None
    if not sku.startswith(old + "-"):
        return sku
    rest = sku[len(old) + 1:]
    if not new:
        return rest or None
    return f"{new}-{rest}"
