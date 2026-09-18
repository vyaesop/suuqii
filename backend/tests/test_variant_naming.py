"""Variant naming parity fixture (docs/19-boutique-shop-type.md §13.2).

The fixture below is a JSON literal on purpose: the mobile test
(`mobile/test/variant_naming_test.dart`) copies it verbatim, so a variant
created on a phone and one created by CSV import or `style.create` on the
server carry the same name and SKU. Change it here first, then there.
"""
import json

from app.core.variant_naming import compose_sku, compose_variant_name, rewrite_sku_prefix

FIXTURE = json.loads(r"""
[
  {"case": "name+size+color", "style": "Slim jeans", "size": "32", "color": "Blue",
   "prefix": "JN", "name": "Slim jeans · 32 · Blue", "sku": "JN-32-BLU"},
  {"case": "name+size only", "style": "Slim jeans", "size": "XL", "color": null,
   "prefix": "JN", "name": "Slim jeans · XL", "sku": "JN-XL"},
  {"case": "name+color only", "style": "Tote bag", "size": null, "color": "Black",
   "prefix": "BAG", "name": "Tote bag · Black", "sku": "BAG-BLA"},
  {"case": "name only", "style": "Silk scarf", "size": null, "color": null,
   "prefix": "SC", "name": "Silk scarf", "sku": "SC"},
  {"case": "whitespace trimming", "style": "  Slim jeans ", "size": " 3 2 ", "color": " Dark green ",
   "prefix": " jn ", "name": "Slim jeans · 3 2 · Dark green", "sku": "JN-32-DAR"},
  {"case": "empty strings behave as null", "style": "Slim jeans", "size": "", "color": "  ",
   "prefix": "JN", "name": "Slim jeans", "sku": "JN"},
  {"case": "ethiopic colour kept verbatim", "style": "ቲሸርት", "size": "M", "color": "ቀይ",
   "prefix": "TS", "name": "ቲሸርት · M · ቀይ", "sku": "TS-M-ቀይ"},
  {"case": "ethiopic colour with inner space", "style": "Tote bag", "size": null, "color": "ጥቁር ሰማያዊ",
   "prefix": "BAG", "name": "Tote bag · ጥቁር ሰማያዊ", "sku": "BAG-ጥቁርሰማያዊ"},
  {"case": "shoe size and lowercase colour", "style": "Runner", "size": "42", "color": "white",
   "prefix": "sh", "name": "Runner · 42 · white", "sku": "SH-42-WHI"},
  {"case": "null prefix gives no sku", "style": "Slim jeans", "size": "32", "color": "Blue",
   "prefix": null, "name": "Slim jeans · 32 · Blue", "sku": null},
  {"case": "blank prefix gives no sku", "style": "Slim jeans", "size": "32", "color": "Blue",
   "prefix": "   ", "name": "Slim jeans · 32 · Blue", "sku": null},
  {"case": "mixed colour not latin-only kept verbatim", "style": "Cap", "size": null, "color": "Red2",
   "prefix": "CP", "name": "Cap · Red2", "sku": "CP-Red2"}
]
""")

PREFIX_REWRITE_FIXTURE = json.loads(r"""
[
  {"case": "prefix swapped", "sku": "JN-32-BLU", "old": "JN", "new": "DN", "expected": "DN-32-BLU"},
  {"case": "prefix-only sku swapped", "sku": "JN", "old": "JN", "new": "DN", "expected": "DN"},
  {"case": "case-insensitive old prefix", "sku": "JN-XL", "old": "jn", "new": "dn", "expected": "DN-XL"},
  {"case": "hand-typed sku untouched", "sku": "CUSTOM-1", "old": "JN", "new": "DN", "expected": "CUSTOM-1"},
  {"case": "similar prefix not a match", "sku": "JNX-32", "old": "JN", "new": "DN", "expected": "JNX-32"},
  {"case": "null stays null", "sku": null, "old": "JN", "new": "DN", "expected": null},
  {"case": "no old prefix leaves sku alone", "sku": "32-BLU", "old": null, "new": "DN", "expected": "32-BLU"},
  {"case": "prefix removed drops the segment", "sku": "JN-32-BLU", "old": "JN", "new": null, "expected": "32-BLU"},
  {"case": "prefix removed from prefix-only sku", "sku": "JN", "old": "JN", "new": "", "expected": null}
]
""")


def test_fixture_covers_the_required_cases():
    cases = {f["case"] for f in FIXTURE}
    for required in (
        "name+size+color", "name+size only", "name+color only", "name only",
        "whitespace trimming", "ethiopic colour kept verbatim", "null prefix gives no sku",
    ):
        assert required in cases


def test_compose_variant_name_matches_fixture():
    for f in FIXTURE:
        assert compose_variant_name(f["style"], f["size"], f["color"]) == f["name"], f["case"]


def test_compose_sku_matches_fixture():
    for f in FIXTURE:
        assert compose_sku(f["prefix"], f["size"], f["color"]) == f["sku"], f["case"]


def test_rewrite_sku_prefix_matches_fixture():
    for f in PREFIX_REWRITE_FIXTURE:
        assert rewrite_sku_prefix(f["sku"], f["old"], f["new"]) == f["expected"], f["case"]


def test_separator_is_space_middot_space():
    assert compose_variant_name("A", "B", "C") == "A · B · C"
