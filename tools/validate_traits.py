#!/usr/bin/env python3
"""Validates the trait tables in assets/traits/materials.json.

Checks, per material:
  1. Every ink has WCAG contrast ratio >= 3.0 against the writing surface
     (display-size text threshold; the word is 100px+ tall).
  2. Every background differs from the surface enough to keep the material
     silhouette readable: contrast ratio >= 1.3 OR hue distance >= 30 deg.
  3. The POS bias groups are complete: every material offers at least one
     background for each of NOUN / VERB / ADJ / ADV.
  4. Fragment hygiene: single-line, single-quoted attributes only, <g> root,
     printable ASCII (mirrors tools/gen_assets_sol.py gating).
  5. Tier values are 0..4 and the tier census matches the architecture table
     (4 Common, 5 Uncommon, 5 Rare, 4 Epic, 2 Legendary).

Exit code 0 = all good. Run after every table edit, before regenerating
RendererAssets.sol.
"""

import colorsys
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MATERIALS = ROOT / "assets" / "traits" / "materials.json"

EXPECTED_TIER_CENSUS = {0: 4, 1: 5, 2: 5, 3: 4, 4: 2}
POS = ("NOUN", "VERB", "ADJ", "ADV")


def srgb_to_lin(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(hexcolor: str) -> float:
    r, g, b = (int(hexcolor[i : i + 2], 16) / 255 for i in (1, 3, 5))
    return 0.2126 * srgb_to_lin(r) + 0.7152 * srgb_to_lin(g) + 0.0722 * srgb_to_lin(b)


def contrast(a: str, b: str) -> float:
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def hue_deg(hexcolor: str) -> float:
    r, g, b = (int(hexcolor[i : i + 2], 16) / 255 for i in (1, 3, 5))
    return colorsys.rgb_to_hsv(r, g, b)[0] * 360


def hue_dist(a: str, b: str) -> float:
    d = abs(hue_deg(a) - hue_deg(b)) % 360
    return min(d, 360 - d)


def main() -> int:
    doc = json.loads(MATERIALS.read_text())
    mats = doc["materials"]
    errors: list[str] = []
    census: dict[int, int] = {}

    for m in mats:
        name, surface = m["name"], m["surface"]
        census[m["tier"]] = census.get(m["tier"], 0) + 1
        if not 0 <= m["tier"] <= 4:
            errors.append(f"{name}: tier {m['tier']} out of range")

        frag = m["fragment"]
        if "\n" in frag or '"' in frag or "\\" in frag:
            errors.append(f"{name}: fragment contains newline/double-quote/backslash")
        if not (frag.startswith("<g") and frag.endswith("</g>")):
            errors.append(f"{name}: fragment is not a <g> group")
        if not all(31 < ord(ch) < 127 for ch in frag):
            errors.append(f"{name}: fragment has non-printable/non-ASCII chars")

        for ink in m["inks"]:
            c = contrast(ink["color"], surface)
            if c < 3.0:
                errors.append(f"{name}: ink '{ink['name']}' contrast {c:.2f} < 3.0 vs surface {surface}")

        seen_bias = set()
        for bg in m["backgrounds"]:
            seen_bias.add(bg["bias"])
            cr = contrast(bg["color"], surface)
            hd = hue_dist(bg["color"], surface)
            if cr < 1.3 and hd < 30:
                errors.append(
                    f"{name}: background '{bg['name']}' too close to surface "
                    f"(contrast {cr:.2f}, hue dist {hd:.0f} deg)"
                )
        missing = [p for p in POS if p not in seen_bias]
        if missing:
            errors.append(f"{name}: bias groups missing {missing}")

    if census != EXPECTED_TIER_CENSUS:
        errors.append(f"tier census {census} != architecture table {EXPECTED_TIER_CENSUS}")

    names = [m["name"] for m in mats]
    if len(names) != len(set(names)):
        errors.append("duplicate material names")

    if errors:
        print(f"FAIL — {len(errors)} problem(s):")
        for e in errors:
            print("  -", e)
        return 1
    total_combos = sum(len(m["inks"]) * len(m["backgrounds"]) for m in mats)
    print(f"OK — {len(mats)} materials, {total_combos} permitted ink x background combinations, all checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
