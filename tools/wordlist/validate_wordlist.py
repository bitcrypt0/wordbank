#!/usr/bin/env python3
"""Validates assets/wordlist.json against the charter's checklist:

  - exactly 10,000 entries, all unique (case-insensitively)
  - every glyph used is inside the onchain font subset
  - category coverage matches the shipped distribution and every category is
    deep enough to survive collection burn-down
  - the 25 honors words are present, capitalized, with their NORMATIVE categories
  - no entry hits the profanity blocklist; regular words are lowercase a-z, 3-12 chars

Exit 0 = ship-ready.  Run:  python tools/wordlist/validate_wordlist.py
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = Path(__file__).resolve().parent / "data"

HONORS = {
    "Rekt": "VERB", "Pepe": "NOUN", "Degen": "ADJ", "Lambo": "NOUN", "Snipe": "VERB",
    "Liquid": "NOUN", "Pump": "VERB", "Dump": "VERB", "Rug": "VERB", "Floor": "NOUN",
    "Yield": "NOUN", "Swap": "VERB", "Trade": "VERB", "Stake": "VERB", "Airdrop": "NOUN",
    "Farm": "VERB", "Satoshi": "NOUN", "Hype": "VERB", "Fee": "NOUN", "Gas": "NOUN",
    "Sweep": "VERB", "Mint": "VERB", "Dev": "NOUN", "Token": "NOUN", "Moon": "NOUN",
}

# Shipped totals incl. honors (12 N / 12 V / 1 ADJ after the owner-directed
# Degen NOUN -> ADJ recategorization, 2026-06-12).
EXPECTED = {"NOUN": 4999, "VERB": 2500, "ADJ": 1701, "ADV": 800}


def main() -> int:
    errors: list[str] = []
    words = json.loads((ROOT / "assets" / "wordlist.json").read_text(encoding="utf-8"))["words"]
    glyphs = set(json.loads((ROOT / "assets" / "font" / "font_chunks.json").read_text())["glyphs"])
    blocked = {
        w.strip().lower()
        for w in (DATA / "badwords_en.txt").read_text(encoding="utf-8").splitlines()
        if w.strip()
    }

    if len(words) != 10_000:
        errors.append(f"count {len(words)} != 10000")

    seen: set[str] = set()
    counts: dict[str, int] = {}
    regular_re = re.compile(r"^[a-z]{3,12}$")
    for e in words:
        w, c = e["word"], e["category"]
        key = w.lower()
        if key in seen:
            errors.append(f"duplicate (case-insensitive): {w}")
        seen.add(key)
        counts[c] = counts.get(c, 0) + 1
        if not set(w) <= glyphs:
            errors.append(f"glyphs outside font subset: {w}")
        if key in blocked:
            errors.append(f"blocklist hit: {w}")
        if w not in HONORS and not regular_re.match(w):
            errors.append(f"regular word malformed: {w!r}")

    if counts != EXPECTED:
        errors.append(f"category counts {counts} != {EXPECTED}")

    by_word = {e["word"]: e["category"] for e in words}
    for hw, hc in HONORS.items():
        if hw not in by_word:
            errors.append(f"honors word missing: {hw}")
        elif by_word[hw] != hc:
            errors.append(f"honors category wrong: {hw} is {by_word[hw]}, must be {hc}")

    if errors:
        print(f"FAIL — {len(errors)} problem(s):")
        for e in errors[:50]:
            print("  -", e)
        return 1
    print(f"OK — 10,000 unique words, counts {counts}, all honors present, all glyphs in subset")
    return 0


if __name__ == "__main__":
    sys.exit(main())
