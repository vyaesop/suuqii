"""
Size-set presets and the size ordering rule (docs/19-boutique-shop-type.md
§6.2, §14.1).

Presets are constants, not rows: a style stores only the preset *key* in
`styles.size_set`. The wizard on the client owns the same table
(`mobile/lib/core/shop_type/size_presets.dart`) — keys and run orders here
are a verbatim mirror of it, because the size curve is only readable if the
server sorts a run the way the client laid it out. Keep the two in sync.

The ordering rule is separate from the presets so every report that shows a
run (today the size curve) sorts identically and cannot drift from the next
one.
"""
from __future__ import annotations

# key → sizes in run order. `free` (no size dimension) and `custom` (the owner
# typed their own list) have no fixed run, so they fall back to the generic
# ordering below.
SIZE_PRESETS: dict[str, tuple[str, ...]] = {
    "letter": ("XS", "S", "M", "L", "XL", "XXL", "3XL"),
    # EU numeric — tops, dresses.
    "numeric": ("34", "36", "38", "40", "42", "44", "46", "48"),
    # Waist inches — trousers, jeans.
    "waist": ("26", "28", "30", "32", "34", "36", "38", "40", "42"),
    "shoe_eu": ("35", "36", "37", "38", "39", "40", "41", "42", "43", "44", "45", "46"),
    "kids_age": (
        "0–3m", "3–6m", "6–12m", "1y", "2y", "3y", "4y", "6y", "8y", "10y", "12y", "14y",
    ),
    "free": (),
    "custom": (),
}


def _generic_key(size: str) -> tuple[int, float, str]:
    """Sort key for a size outside any preset: numerics first, then text.

    "38" before "40" before "M" — a plain lexicographic sort would put "38"
    after "380" and "10" before "2", which reads as a bug on a size run.
    A None size (a `free` style has no size dimension) sorts last so the
    single unsized row never displaces the real ones.
    """
    try:
        return (0, float(size), size)
    except (TypeError, ValueError):
        return (1, 0.0, size)


def sort_sizes(sizes: list[str | None], preset_key: str | None = None) -> list[str | None]:
    """Distinct [sizes] in display order for a style whose size_set is
    [preset_key].

    Preset order first for the sizes the preset knows; anything added later
    outside the preset (a custom size bolted onto a `letter` run) follows,
    ordered generically, so it is visible rather than silently dropped.
    """
    distinct: list[str | None] = []
    for s in sizes:
        if s not in distinct:
            distinct.append(s)
    run = SIZE_PRESETS.get(preset_key or "", ())
    rank = {size: i for i, size in enumerate(run)}
    in_preset = sorted((s for s in distinct if s in rank), key=lambda s: rank[s])
    extra = sorted((s for s in distinct if s not in rank and s is not None), key=_generic_key)
    unsized: list[str | None] = [s for s in distinct if s is None]
    return [*in_preset, *extra, *unsized]
