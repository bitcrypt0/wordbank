#!/usr/bin/env python3
"""Validates assets/templates.json and prints sample sentences.

Checks: fragments.length == slots.length + 1; slots <= 7 (normative cap);
categories valid; ids sequential; no double spaces or double quotes in
fragments. Prints each template filled with sample words so a human can
read the grammar.  Run:  python tools/validate_templates.py
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SAMPLES = {"NOUN": "ember", "VERB": "wander", "ADJ": "luminous", "ADV": "softly"}
CATS = set(SAMPLES)


def main() -> int:
    doc = json.loads((ROOT / "assets" / "templates.json").read_text(encoding="utf-8"))
    errors: list[str] = []
    for i, t in enumerate(doc["templates"]):
        tid, slots, frags = t["id"], t["slots"], t["fragments"]
        if tid != i:
            errors.append(f"template {i}: id {tid} not sequential")
        if not 1 <= len(slots) <= doc["maxSlots"]:
            errors.append(f"template {tid}: {len(slots)} slots outside 1..{doc['maxSlots']}")
        if len(frags) != len(slots) + 1:
            errors.append(f"template {tid}: {len(frags)} fragments != {len(slots)} slots + 1")
        if not set(slots) <= CATS:
            errors.append(f"template {tid}: unknown category in {slots}")
        sentence = frags[0]
        for s, f in zip(slots, frags[1:]):
            sentence += SAMPLES[s] + f
        if '"' in sentence or "  " in sentence:
            errors.append(f"template {tid}: double space or quote in: {sentence}")
        print(f"  [{tid:>2}] ({len(slots)} slots) {sentence}")

    if errors:
        print(f"FAIL — {len(errors)} problem(s):")
        for e in errors:
            print("  -", e)
        return 1
    n = len(doc["templates"])
    print(f"OK — {n} templates, slot counts {[len(t['slots']) for t in doc['templates']]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
