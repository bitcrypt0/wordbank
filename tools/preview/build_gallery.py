#!/usr/bin/env python3
"""Builds the owner preview gallery from the Renderer's real tokenURI output.

Reads assets/previews/manifest.json (written by test/preview/PreviewGen.t.sol —
every URI in it came out of the sealed Renderer running in the EVM), decodes
each data URI down to its SVG, and writes:

  assets/previews/<file>.svg     standalone, double-clickable artwork files
  assets/previews/index.html     browsable labeled gallery (no server needed)

Full refresh:
  forge test --match-contract PreviewGen
  python tools/preview/build_gallery.py

Never edit the SVGs by hand — change the Renderer / asset tables and refresh.
"""

import base64
import html
import json
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PREVIEWS = ROOT / "assets" / "previews"
MANIFEST = PREVIEWS / "manifest.json"

JSON_PREFIX = "data:application/json;base64,"
SVG_PREFIX = "data:image/svg+xml;base64,"

PAGE_HEADER = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>WORDBANK — Art Preview Gallery</title>
<style>
  body { margin: 0; padding: 32px; background: #14130f; color: #efe9da;
         font-family: Georgia, 'Times New Roman', serif; }
  h1 { font-weight: normal; letter-spacing: 0.08em; }
  p.note { color: #b5ad99; max-width: 70em; line-height: 1.5; }
  h2 { margin-top: 48px; border-bottom: 1px solid #3a372d; padding-bottom: 8px;
       font-weight: normal; letter-spacing: 0.06em; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(290px, 1fr)); gap: 24px; }
  .card { background: #1d1b16; border: 1px solid #322f26; border-radius: 10px;
          padding: 14px; }
  .card object { width: 100%; aspect-ratio: 1; display: block; border-radius: 6px;
                 pointer-events: none; }
  .label { margin-top: 10px; font-size: 14px; line-height: 1.55; }
  .label b { font-size: 17px; }
  .tag { color: #b5ad99; }
</style>
</head>
<body>
<h1>WORDBANK &mdash; Art Preview Gallery</h1>
<p class="note">Every image below was decoded from the <i>actual onchain
tokenURI output</i> of the Renderer contract &mdash; what you see here is
byte-for-byte what will mint. Visual rarity (material, ink, background, 1/1
lettering) is purely cosmetic and never affects bounty odds, rewards, or
backing.</p>
"""


def decode_entry(entry: dict) -> str:
    uri = entry["uri"]
    assert uri.startswith(JSON_PREFIX), f"{entry['file']}: bad URI prefix"
    meta = json.loads(base64.b64decode(uri[len(JSON_PREFIX):]))
    image = meta["image"]
    assert image.startswith(SVG_PREFIX), f"{entry['file']}: bad image prefix"
    svg = base64.b64decode(image[len(SVG_PREFIX):]).decode("utf-8")
    ET.fromstring(svg)  # well-formed XML gate — fails the build if not
    attrs = {a["trait_type"]: a["value"] for a in meta["attributes"]}
    # The pre-reveal placeholder is trait-free by design (only a Status attr) —
    # it carries none of the Word/Material attributes the real tokens cross-check.
    if entry.get("note") == "unrevealed":
        assert attrs.get("Status") == "Unrevealed", entry["file"]
    else:
        assert attrs["Word"] == entry["word"], entry["file"]
        assert attrs["Material"] == entry["material"], entry["file"]
    return svg


def card(entry: dict) -> str:
    e = {k: html.escape(str(v)) for k, v in entry.items()}
    honors = " &middot; <b>1/1</b>" if entry["honors"] else ""
    return (
        f'<div class="card"><object type="image/svg+xml" data="{e["file"]}.svg"></object>'
        f'<div class="label"><b>{e["word"]}</b> <span class="tag">({e["category"]})</span><br>'
        f'<span class="tag">Material:</span> {e["material"]} &middot; '
        f'<span class="tag">Ink:</span> {e["ink"]}<br>'
        f'<span class="tag">Background:</span> {e["background"]}{honors}</div></div>'
    )


def main() -> None:
    manifest = json.loads(MANIFEST.read_text())["previews"]
    sections = {"unrevealed": [], "material coverage": [], "palette bias example": [], "honors 1/1": []}
    for entry in manifest:
        svg = decode_entry(entry)
        (PREVIEWS / f"{entry['file']}.svg").write_text(svg, encoding="utf-8")
        sections.setdefault(entry["note"], []).append(card(entry))

    titles = {
        "unrevealed": "Before the reveal &mdash; the pre-reveal placeholder every token shows during minting",
        "material coverage": "Materials &mdash; every surface, representative inks &amp; backgrounds",
        "palette bias example": "Word-type palettes &mdash; how part of speech tints the backdrop",
        "honors 1/1": "The 25 1/1s &mdash; each in bespoke lettering",
    }
    body = []
    for note, cards in sections.items():
        if not cards:
            continue
        body.append(f"<h2>{titles.get(note, html.escape(note))}</h2>")
        body.append(f'<div class="grid">{"".join(cards)}</div>')
    (PREVIEWS / "index.html").write_text(PAGE_HEADER + "\n".join(body) + "\n</body>\n</html>\n", encoding="utf-8")
    print(f"gallery: {len(manifest)} previews -> assets/previews/index.html")


if __name__ == "__main__":
    main()
