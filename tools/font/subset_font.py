#!/usr/bin/env python3
"""WORDBANK font pipeline (agent 2 — renderer-art).

Takes the Fraunces variable font, pins it to the collection's single display
instance, subsets it to exactly the glyphs the word list can use, compresses
to WOFF2, and emits SSTORE2-ready chunk files for Renderer deployment/tests.

Outputs (all under assets/font/):
  WB-Fraunces-subset.woff2   the embedded font, byte-for-byte what goes onchain
  font_chunks.json           {"chunks": ["0x...", ...], "totalBytes": N}
                             each chunk <= 24575 bytes (SSTORE2 limit minus STOP byte)

Axis choices (the collection's one face):
  opsz=144 (display optical size), wght=564 (semibold-ish, confident at scale),
  SOFT=0 (crisp serifs, carves well on stone/slate materials),
  WONK=1 (the quirky letterforms — this is the brand).

Run:  python tools/font/subset_font.py
"""

import json
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = Path(__file__).resolve().parents[2]
FONT_DIR = ROOT / "assets" / "font"
SRC = FONT_DIR / "Fraunces-VF.ttf"
OUT_WOFF2 = FONT_DIR / "WB-Fraunces-subset.woff2"
OUT_CHUNKS = FONT_DIR / "font_chunks.json"

# The full glyph budget: lowercase for the 10,000-word list, uppercase for the
# honors words' stored strings and any future display use. Nothing else — every
# extra glyph is mainnet storage gas.
GLYPHS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

# SSTORE2 data limit: 24576 bytes of code minus the leading STOP byte.
CHUNK_LIMIT = 24575

AXES = {"opsz": 144, "wght": 564, "SOFT": 0, "WONK": 1}


def main() -> None:
    font = TTFont(SRC)
    instantiateVariableFont(font, AXES, inplace=True)

    options = subset.Options()
    options.flavor = "woff2"
    options.layout_features = ["kern", "liga"]  # keep kerning; drop everything exotic
    options.hinting = False  # we render at display sizes; hints are dead weight
    options.desubroutinize = True
    options.name_IDs = []  # strip all name records — onchain bytes are precious
    options.notdef_outline = False
    options.drop_tables += ["DSIG"]

    subsetter = subset.Subsetter(options=options)
    subsetter.populate(text=GLYPHS)
    subsetter.subset(font)

    font.flavor = "woff2"
    font.save(OUT_WOFF2)

    data = OUT_WOFF2.read_bytes()
    chunks = [data[i : i + CHUNK_LIMIT] for i in range(0, len(data), CHUNK_LIMIT)]
    OUT_CHUNKS.write_text(
        json.dumps(
            {
                "font": "Fraunces (SIL OFL 1.1), instance opsz=144 wght=564 SOFT=0 WONK=1",
                "glyphs": GLYPHS,
                "totalBytes": len(data),
                "chunks": ["0x" + c.hex() for c in chunks],
            },
            indent=2,
        )
    )
    print(f"subset font: {len(data)} bytes -> {len(chunks)} SSTORE2 chunk(s)")
    print(f"wrote {OUT_WOFF2.name}, {OUT_CHUNKS.name}")


if __name__ == "__main__":
    main()
