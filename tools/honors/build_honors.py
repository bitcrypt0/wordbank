#!/usr/bin/env python3
"""Builds the 25 honors 1/1 artworks as pure SVG path art.

Each honors word gets bespoke lettering — an ornate OFL display face converted
to baked <path> outlines (no font dependency survives into the art) — plus a
hand-tuned decoration, palette, and a halo outline so the word stays legible
on whatever material it is curated onto.

Outputs:
  assets/honors/<Word>.svg     the <g>…</g> fragment stored onchain per token
  assets/honors/manifest.json  word -> {file, category, material, background}
                               (curation consumed by gen_assets_sol.py and the
                               trait-assignment tool; honors surfaces are curated,
                               not random — they are 1/1s)

All fragments: single-line, single-quoted attributes, integer-ish coords.
Run:  python tools/honors/build_honors.py
"""

import json
from pathlib import Path

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[2]
FONTS = ROOT / "assets" / "honors" / "fonts"
OUT = ROOT / "assets" / "honors"

CENTER_X, CENTER_Y = 500, 510

# Materials whose writing area is too cramped (height and/or width) to host a
# 1/1 word plus its layered enhancement — owner directive, 2026-06-12. These
# stay in the regular rotation; they just never get curated for honors.
SMALL_MATERIALS = {6: "Banner", 7: "Ribbon", 17: "Stained Glass"}

_font_cache: dict[str, TTFont] = {}


def load_font(name: str) -> TTFont:
    if name not in _font_cache:
        _font_cache[name] = TTFont(FONTS / f"{name}.ttf")
    return _font_cache[name]


def word_path(word: str, fontname: str, target_w: float, max_size: float, tracking_em: float = 0.02,
              skew: float = 0.0, baseline_shift: float = 0.0):
    """Returns (d, transform_attr, scale) for the word baked into one path."""
    font = load_font(fontname)
    glyphset = font.getGlyphSet()
    cmap = font.getBestCmap()
    upem = font["head"].unitsPerEm

    x = 0.0
    cmds = []
    track = tracking_em * upem
    for ch in word:
        code = ord(ch)
        if code not in cmap:
            code = ord(ch.upper())
        gname = cmap[code]
        pen = SVGPathPen(glyphset, ntos=lambda v: format(v, ".0f"))
        glyphset[gname].draw(TransformPen(pen, (1, 0, 0, 1, x, 0)))
        cmds.append(pen.getCommands())
        x += glyphset[gname].width + track
    width_units = x - track

    scale = min(target_w / width_units, max_size / upem)
    # Visual center: cap height ~0.70 em above baseline.
    baseline = CENTER_Y + 0.35 * scale * upem + baseline_shift
    tx = CENTER_X - (width_units * scale) / 2 + (skew * scale * upem) * 0.18
    transform = (
        f"matrix({scale:.4f} 0 {(-skew * scale):.4f} {-scale:.4f} {tx:.1f} {baseline:.1f})"
        if skew
        else f"matrix({scale:.4f} 0 0 {-scale:.4f} {tx:.1f} {baseline:.1f})"
    )
    return " ".join(cmds), transform, scale, width_units * scale


def lettering(word, fontname, fill, halo, target_w=580, max_size=175, tracking=0.02, skew=0.0,
              halo_px=11, baseline_shift=0.0, extra_attrs=""):
    d, tr, s, w = word_path(word, fontname, target_w, max_size, tracking, skew, baseline_shift)
    sw = halo_px / s
    return (
        f"<path d='{d}' transform='{tr}' fill='{fill}' stroke='{halo}' "
        f"stroke-width='{sw:.0f}' paint-order='stroke' stroke-linejoin='round'{extra_attrs}/>",
        w,
    )


def glyph(ch: str, fontname: str, size_px: float, cx: float, baseline_y: float, fill: str) -> str:
    """One glyph baked to a path, centered horizontally on cx with its baseline at baseline_y."""
    font = load_font(fontname)
    glyphset = font.getGlyphSet()
    cmap = font.getBestCmap()
    upem = font["head"].unitsPerEm
    g = glyphset[cmap[ord(ch)]]
    pen = SVGPathPen(glyphset, ntos=lambda v: format(v, ".0f"))
    g.draw(pen)
    s = size_px / upem
    tr = f"matrix({s:.4f} 0 0 {-s:.4f} {cx - g.width * s / 2:.1f} {baseline_y:.1f})"
    return f"<path d='{pen.getCommands()}' transform='{tr}' fill='{fill}'/>"


# ---------------------------------------------------------------------------
# The 25 styles. Each returns the full <g>…</g> fragment.
# (category: Category enum index; material/background: curated indices)
#
# Layering rule (owner directive): the lettering is always the LAST element of
# the fragment — every enhancement renders BENEATH the word (Satoshi's ₿ is
# the reference), and the word itself sits centered on the material.
# ---------------------------------------------------------------------------

def art_rekt():
    p, w = lettering("Rekt", "PirataOne", "#efe9da", "#1a1d24", target_w=540, max_size=200)
    crack = (
        "<path d='M468 318 L506 408 L478 470 L522 540 L492 612 L524 700' fill='none' "
        "stroke='#8e2434' stroke-width='10' stroke-linecap='round' opacity='0.9'/>"
    )
    shards = "<g fill='#8e2434'><path d='M452 330 l-26 -38 l8 44 Z'/><path d='M540 688 l30 40 l-10 -46 Z'/></g>"
    return f"<g>{crack}{shards}{p}</g>"


def art_pepe():
    # Eyes peek out from behind the word's top edge, the whole face centered.
    eyes = (
        "<g transform='translate(0 70)'><ellipse cx='446' cy='330' rx='52' ry='44' fill='#f4f2e6' stroke='#27331c' stroke-width='7'/>"
        "<ellipse cx='562' cy='330' rx='52' ry='44' fill='#f4f2e6' stroke='#27331c' stroke-width='7'/>"
        "<circle cx='458' cy='338' r='15' fill='#27331c'/><circle cx='572' cy='338' r='15' fill='#27331c'/>"
        "<path d='M394 306 Q446 270 500 302' fill='none' stroke='#27331c' stroke-width='9' stroke-linecap='round'/>"
        "<path d='M512 302 Q566 268 616 304' fill='none' stroke='#27331c' stroke-width='9' stroke-linecap='round'/></g>"
    )
    p, w = lettering("Pepe", "TitanOne", "#3f7a3a", "#1c2e18", target_w=540, max_size=185)
    return f"<g>{eyes}{p}</g>"


def art_degen():
    def die(cx, cy, rot, pips):
        ps = "".join(f"<circle cx='{px}' cy='{py}' r='7' fill='#26211c'/>" for px, py in pips)
        return (
            f"<g transform='rotate({rot} {cx} {cy})'><rect x='{cx-44}' y='{cy-44}' width='88' height='88' rx='14' "
            f"fill='#f0e8d8' stroke='#26211c' stroke-width='6'/>{ps}</g>"
        )
    # Dice tucked behind the word's corners — one peeking above-left, one
    # below-right — so the word stays dead-center.
    d1 = die(320, 424, -14, [(298, 402), (342, 446)])
    d2 = die(680, 596, 11, [(658, 574), (680, 596), (702, 618)])
    p, w = lettering("Degen", "Rye", "#26211c", "#f0e8d8", target_w=560, max_size=160)
    return f"<g>{d1}{d2}{p}</g>"


def art_lambo():
    # Speed lines tucked inside the copper plate's inner face (x >= 180),
    # trailing off the word's left edge — never poking past the bevel.
    lines = (
        "<g stroke='#f3e9d8' stroke-linecap='round' opacity='0.85'>"
        "<path d='M184 434 H310' stroke-width='13'/><path d='M184 504 H282' stroke-width='10'/>"
        "<path d='M184 574 H318' stroke-width='13'/></g>"
    )
    p, w = lettering("Lambo", "Bungee", "#221d18", "#f3e9d8", target_w=520, max_size=150, skew=0.28)
    return f"<g>{lines}{p}</g>"


def art_snipe():
    ch = (
        "<g stroke='#92271f' fill='none' opacity='0.88'>"
        "<circle cx='500' cy='508' r='218' stroke-width='9'/>"
        "<circle cx='500' cy='508' r='150' stroke-width='4' opacity='0.6'/>"
        "<path d='M500 252 V332 M500 684 V764 M244 508 H324 M676 508 H756' stroke-width='11'/>"
        "</g><circle cx='500' cy='508' r='13' fill='#92271f'/>"
    )
    p, w = lettering("Snipe", "AllertaStencil", "#2e2b27", "#f6f2e8", target_w=520, max_size=160)
    return f"<g>{ch}{p}</g>"


def art_liquid():
    p, w = lettering("Liquid", "Pacifico", "#1d4e74", "#eef4f8", target_w=560, max_size=170, tracking=0.0)
    drops = (
        "<g fill='#3f7fae'><path d='M392 660 q-26 44 0 66 q26 -22 0 -66 Z'/>"
        "<path d='M608 672 q-20 36 0 54 q20 -18 0 -54 Z'/>"
        "<path d='M502 690 q-14 26 0 40 q14 -14 0 -40 Z' opacity='0.8'/></g>"
        "<path d='M330 648 Q420 668 500 652 Q586 636 672 656' fill='none' stroke='#3f7fae' "
        "stroke-width='6' stroke-linecap='round' opacity='0.55'/>"
    )
    return f"<g>{drops}{p}</g>"


def art_pump():
    # The rising arrow cuts diagonally across the centered word, behind it —
    # head peeking out top-right, tail bottom-left.
    arrow = (
        "<g fill='#9fe0b0' opacity='0.92' transform='translate(0 -55)'><path d='M306 668 L426 560 L488 612 L612 472 L584 452 L688 408 "
        "L668 520 L640 498 L494 664 L432 612 L332 700 Z' stroke='#1a241e' stroke-width='7' "
        "stroke-linejoin='round'/></g>"
    )
    p, w = lettering("Pump", "Bungee", "#9fe0b0", "#1a241e", target_w=520, max_size=165)
    return f"<g>{arrow}{p}</g>"


def art_dump():
    arrow = (
        "<g fill='#a3242a' opacity='0.92'><path d='M308 384 L428 488 L490 438 L614 572 L586 594 L690 640 "
        "L670 528 L642 548 L496 386 L434 438 L334 352 Z' stroke='#f6f4ee' stroke-width='7' "
        "stroke-linejoin='round'/></g>"
    )
    p, w = lettering("Dump", "Bungee", "#a3242a", "#f6f4ee", target_w=520, max_size=165)
    return f"<g>{arrow}{p}</g>"


def art_rug():
    rug = (
        "<g transform='rotate(-4 500 620)'><rect x='240' y='580' width='520' height='86' rx='8' fill='#7a3024'/>"
        "<rect x='240' y='596' width='520' height='12' fill='#a3503c' opacity='0.8'/>"
        "<rect x='240' y='636' width='520' height='12' fill='#a3503c' opacity='0.8'/>"
        "<g stroke='#7a3024' stroke-width='6' stroke-linecap='round'>"
        "<path d='M236 588 l-22 8 M236 612 l-24 4 M236 636 l-22 6 M236 658 l-20 8'/>"
        "<path d='M764 588 l22 8 M764 612 l24 4 M764 636 l22 6 M764 658 l20 8'/></g></g>"
        "<g stroke='#9a8d76' stroke-width='5' opacity='0.7' stroke-linecap='round'>"
        "<path d='M778 560 q34 -10 60 8 M788 600 q30 -6 54 12'/></g>"
    )
    # Rug raised so the centered word stands right on it, mid-pull.
    p, w = lettering("Rug", "BerkshireSwash", "#7a3024", "#f8f1e4", target_w=420, max_size=185)
    return f"<g><g transform='translate(0 -20)'>{rug}</g>{p}</g>"


def art_floor():
    slab = (
        "<rect x='232' y='618' width='536' height='30' fill='#f1efe6' stroke='#2a2a28' stroke-width='5'/>"
        "<g fill='#f1efe6' opacity='0.75'><rect x='560' y='692' width='40' height='40' "
        "transform='rotate(18 580 712)' stroke='#2a2a28' stroke-width='4'/></g>"
        "<path d='M580 656 q6 18 0 30' stroke='#f1efe6' stroke-width='4' fill='none' opacity='0.6'/>"
    )
    # Slab raised under the centered word's baseline — the word stands on it.
    p, w = lettering("Floor", "CinzelDecorative", "#f1efe6", "#2a2a28", target_w=540, max_size=160)
    return f"<g><g transform='translate(0 -30)'>{slab}</g>{p}</g>"


def art_yield():
    # Sprout leaves peek above the centered word; coin cluster peeks below-left.
    sprout = (
        "<g transform='translate(-120 124)'><path d='M672 332 q4 -56 -10 -88' stroke='#41522a' stroke-width='9' fill='none' stroke-linecap='round'/>"
        "<path d='M664 268 q-50 -34 -88 -16 q18 44 88 16 Z' fill='#5d7a38'/>"
        "<path d='M666 252 q44 -42 86 -30 q-12 48 -86 30 Z' fill='#73933f'/></g>"
    )
    coins = "<g fill='#9a7218' opacity='0.85' transform='translate(40 330)'><circle cx='306' cy='306' r='17'/><circle cx='346' cy='282' r='12'/><circle cx='282' cy='270' r='10'/></g>"
    p, w = lettering("Yield", "CinzelDecorative", "#41522a", "#f3ecd8", target_w=540, max_size=160)
    return f"<g>{sprout}{coins}{p}</g>"


def art_swap():
    # Two near-half-circle arcs (recycle-style swirl) with solid arrowheads,
    # encircling the word: top arc apex ~248, bottom ~772, both inside the paper.
    arrows = (
        "<g fill='none' stroke-linecap='round'>"
        "<path d='M240 478 A262 262 0 0 1 760 478' stroke='#c2552e' stroke-width='14'/>"
        "<path d='M760 542 A262 262 0 0 1 240 542' stroke='#1f6f6b' stroke-width='14'/></g>"
        "<path d='M766 522 L740 474 L792 480 Z' fill='#c2552e'/>"
        "<path d='M234 498 L210 548 L262 542 Z' fill='#1f6f6b'/>"
    )
    p, w = lettering("Swap", "TitanOne", "#1f6f6b", "#f6f1e4", target_w=480, max_size=165)
    return f"<g>{arrows}{p}</g>"


def art_trade():
    def candle(cx, top, bot, body_top, body_bot, col):
        return (
            f"<path d='M{cx} {top} V{bot}' stroke='{col}' stroke-width='5'/>"
            f"<rect x='{cx-17}' y='{body_top}' width='34' height='{body_bot-body_top}' fill='{col}'/>"
        )
    chart = "<g opacity='0.9' transform='translate(0 160)'>" + candle(282, 300, 452, 330, 414, "#2e6b46") + candle(330, 268, 430, 292, 376, "#7c2218") + candle(378, 240, 392, 258, 344, "#2e6b46") + "</g>"
    chart2 = "<g opacity='0.9' transform='translate(0 160)'>" + candle(626, 380, 250, 286, 352, "#2e6b46") + candle(674, 420, 286, 314, 392, "#7c2218") + candle(722, 330, 232, 252, 306, "#2e6b46") + "</g>"
    # Candle clusters flank the centered word at its own height, behind it.
    p, w = lettering("Trade", "SpaceMono", "#33291f", "#efe3d2", target_w=480, max_size=150)
    return f"<g>{chart}{chart2}{p}</g>"


def art_stake():
    # A real chain: three oval links joined by solid edge-on connectors
    # (the old four touching ovals read as letters).
    chain = (
        "<g fill='none' stroke='#d9c9a8' stroke-width='10'>"
        "<ellipse cx='330' cy='654' rx='52' ry='28'/><ellipse cx='500' cy='654' rx='52' ry='28'/>"
        "<ellipse cx='670' cy='654' rx='52' ry='28'/></g>"
        "<g fill='#d9c9a8'><rect x='386' y='646' width='60' height='16' rx='8'/>"
        "<rect x='554' y='646' width='60' height='16' rx='8'/></g>"
    )
    # Chain runs just under the centered word's baseline, anchoring it.
    p, w = lettering("Stake", "CinzelDecorative", "#f2ead8", "#2a1f14", target_w=540, max_size=158)
    return f"<g><g transform='translate(0 -39)'>{chain}</g>{p}</g>"


def art_airdrop():
    # Re-homed from Banner to Cardboard (a supply-drop crate) after the owner
    # barred small-area materials from 1/1 use. Canopy peeks above the centered
    # word, the cords drop behind it, and the crate hangs out below.
    chute = (
        "<g><path d='M380 372 Q500 250 620 372 Z' fill='#9d2c1f'/>"
        "<path d='M428 372 Q500 286 572 372 Z' fill='#f0e7d4' opacity='0.45'/>"
        "<g stroke='#3f2d1d' stroke-width='5'><path d='M388 374 L478 596 M500 366 L500 596 M612 374 L522 596'/></g>"
        "<rect x='458' y='592' width='84' height='64' rx='8' fill='#8a6a3c' stroke='#3f2d1d' stroke-width='5'/>"
        "<path d='M458 620 H542' stroke='#f4efe6' stroke-width='4'/></g>"
    )
    p, w = lettering("Airdrop", "TitanOne", "#19294a", "#f6f1e2", target_w=540, max_size=130)
    return f"<g>{chute}{p}</g>"


def art_farm():
    rows = (
        "<g fill='none' stroke='#5a4226' stroke-width='8' opacity='0.85'>"
        "<path d='M250 660 Q500 624 750 660'/><path d='M282 700 Q500 668 718 700'/>"
        "<path d='M320 738 Q500 712 680 738'/></g>"
        "<g fill='#73933f'><path d='M312 648 q-4 -34 14 -52 q14 22 -2 52 Z'/>"
        "<path d='M666 644 q-2 -30 14 -46 q12 20 -2 46 Z'/><path d='M492 688 q-4 -28 12 -44 q12 18 -2 44 Z'/></g>"
    )
    p, w = lettering("Farm", "BerkshireSwash", "#f2ead8", "#33231a", target_w=500, max_size=180)
    return f"<g>{rows}{p}</g>"


def art_satoshi():
    rings = (
        "<g fill='none' stroke='#a8841c'><circle cx='500' cy='508' r='258' stroke-width='8' opacity='0.75'/>"
        "<circle cx='500' cy='508' r='236' stroke-width='3' opacity='0.6'/></g>"
        "<g stroke='#a8841c' stroke-width='5' opacity='0.7'>"
        "<path d='M500 240 V214 M500 776 V802 M232 508 H206 M768 508 H794 "
        "M312 320 L294 302 M688 320 L706 302 M312 696 L294 714 M688 696 L706 714'/></g>"
    )
    # The bitcoin mark: a large engraved B with the two vertical strokes
    # crossing its cap line and baseline, layered directly UNDER the word
    # (no backing disc) — the word renders on top of it.
    b = glyph("B", "CinzelDecorative", 340, 500, 627, "#a8841c")
    mark = (
        f"{b}"
        "<g fill='#a8841c'><rect x='470' y='348' width='18' height='46'/><rect x='504' y='348' width='18' height='46'/>"
        "<rect x='470' y='624' width='18' height='46'/><rect x='504' y='624' width='18' height='46'/></g>"
    )
    p, w = lettering("Satoshi", "CinzelDecorative", "#1d2030", "#e8cc6a", target_w=470, max_size=120)
    return f"<g>{rings}{mark}{p}</g>"


def art_hype():
    base, w = lettering("Hype", "Monoton", "#e0b15e", "#1a1d24", target_w=540, max_size=170, halo_px=6)
    echo1 = base.replace("<path ", "<path transform-origin='500 510' opacity='0.4' transform='translate(-9 -7) ", 1) if False else ""
    # Echo copies: re-render shifted for a vibration effect.
    d, tr, s, _ = word_path("Hype", "Monoton", 540, 170)
    sw = 6 / s
    def echo(dx, dy, op):
        etr = tr.replace("matrix(", "translate({} {}) matrix(".format(dx, dy))
        return f"<path d='{d}' transform='{etr}' fill='#e0b15e' opacity='{op}'/>"
    return f"<g>{echo(-10, -8, 0.30)}{echo(10, 8, 0.30)}{base}</g>"


def art_fee():
    # A postage stamp: perforated edge (semicircular notches all around, one
    # continuous path), double inner frame, a small denomination "1", and a
    # faded postmark over the corner. Drop shadow separates it from pale
    # materials (newsprint, paper).
    top = "h8 " + "a10 10 0 0 0 20 0 h16 " * 9 + "a10 10 0 0 0 20 0 h8 "
    right = "v8 " + "a10 10 0 0 0 0 20 v16 " * 9 + "a10 10 0 0 0 0 20 v8 "
    bottom = "h-8 " + "a10 10 0 0 0 -20 0 h-16 " * 9 + "a10 10 0 0 0 -20 0 h-8 "
    left = "v-8 " + "a10 10 0 0 0 0 -20 v-16 " * 9 + "a10 10 0 0 0 0 -20 v-8 "
    outline = f"M320 330 {top}{right}{bottom}{left}Z"
    denom = glyph("1", "SpaceMono", 46, 614, 424, "#26211c")
    stamp = (
        "<filter id='h18s' x='-20%' y='-20%' width='140%' height='140%'>"
        "<feDropShadow dx='0' dy='9' stdDeviation='10' flood-color='#101012' flood-opacity='0.38'/></filter>"
        f"<path d='{outline}' fill='#fbf8ec' filter='url(#h18s)'/>"
        "<rect x='352' y='362' width='296' height='296' fill='none' stroke='#26211c' stroke-width='5'/>"
        "<rect x='364' y='374' width='272' height='272' fill='none' stroke='#26211c' stroke-width='2' opacity='0.55'/>"
        f"{denom}"
        "<g stroke='#56524a' stroke-width='5' fill='none' opacity='0.45'>"
        "<circle cx='678' cy='348' r='56'/>"
        "<path d='M716 312 q34 16 64 4 M720 344 q32 14 60 2 M716 376 q30 12 56 2'/></g>"
    )
    p, w = lettering("Fee", "SpaceMono", "#1d1d1f", "#fbf8ec", target_w=240, max_size=140)
    return f"<g>{stamp}{p}</g>"


def art_gas():
    # One big flame centered directly behind the word — tip burning above it,
    # bulb glowing out under the baseline.
    flame = (
        "<g><path d='M500 250 q-128 150 -72 266 q34 72 72 62 q36 12 72 -62 q56 -116 -72 -266 Z' fill='#8e2a18'/>"
        "<path d='M500 372 q-62 86 -34 134 q16 34 34 28 q18 6 34 -28 q28 -48 -34 -134 Z' fill='#e0b15e'/></g>"
    )
    p, w = lettering("Gas", "Bungee", "#221d18", "#f3e9d8", target_w=420, max_size=165)
    return f"<g>{flame}{p}</g>"


def art_sweep():
    swoosh = (
        "<g fill='none' stroke-linecap='round'><path d='M240 654 Q480 600 760 648' stroke='#8a6a3c' stroke-width='11' opacity='0.8'/>"
        "<path d='M286 692 Q500 648 716 686' stroke='#8a6a3c' stroke-width='8' opacity='0.6'/>"
        "<path d='M348 726 Q520 692 668 720' stroke='#8a6a3c' stroke-width='6' opacity='0.45'/></g>"
        "<g fill='#8a6a3c' opacity='0.7'><circle cx='742' cy='614' r='6'/><circle cx='772' cy='588' r='4.5'/>"
        "<circle cx='760' cy='646' r='5'/><circle cx='792' cy='620' r='3.5'/></g>"
    )
    p, w = lettering("Sweep", "Pacifico", "#2a2620", "#f0e6cc", target_w=540, max_size=165, tracking=0.0)
    return f"<g>{swoosh}{p}</g>"


def art_mint():
    # Minting as in minting NFTs: a printer pressing out a freshly minted
    # picture card (sun + mountains = the classic image icon), with sparkles.
    printer = (
        "<g><rect x='398' y='300' width='204' height='44' rx='10' fill='#2e8a64'/>"
        "<rect x='350' y='332' width='300' height='100' rx='16' fill='#1f6f5a'/>"
        "<rect x='382' y='408' width='236' height='18' rx='7' fill='#143f33'/>"
        "<circle cx='616' cy='366' r='9' fill='#9fe0b0'/>"
        "<rect x='414' y='420' width='172' height='200' rx='10' fill='#f4faf4' stroke='#1f6f5a' stroke-width='6'/>"
        "<circle cx='468' cy='560' r='13' fill='#e0b15e'/>"
        "<path d='M428 612 L464 568 L492 598 L514 574 L556 612 Z' fill='#2e8a64'/>"
        "<path d='M664 448 l7 18 l18 7 l-18 7 l-7 18 l-7 -18 l-18 -7 l18 -7 Z' fill='#e0b15e'/>"
        "<path d='M336 464 l5 13 l13 5 l-13 5 l-5 13 l-5 -13 l-13 -5 l13 -5 Z' fill='#e0b15e'/></g>"
    )
    # Printer top peeks above the centered word; the freshly minted card slides
    # out beneath it, its picture face showing under the baseline.
    p, w = lettering("Mint", "TitanOne", "#1f6f5a", "#eaf6ee", target_w=480, max_size=165)
    return f"<g>{printer}{p}</g>"


def art_dev():
    term = (
        "<g stroke='#bcd9c4' stroke-width='12' fill='none' stroke-linecap='round' stroke-linejoin='round'>"
        "<path d='M252 408 L330 508 L252 608'/></g>"
        "<rect x='642' y='576' width='96' height='18' fill='#bcd9c4'/>"
    )
    p, w = lettering("Dev", "SpaceMono", "#bcd9c4", "#18211c", target_w=300, max_size=170)
    return f"<g>{term}{p}</g>"


def art_token():
    coin = (
        "<g><circle cx='500' cy='508' r='252' fill='#54381f'/>"
        "<circle cx='500' cy='508' r='252' fill='none' stroke='#d9b87c' stroke-width='10'/>"
        "<circle cx='500' cy='508' r='222' fill='none' stroke='#d9b87c' stroke-width='4' stroke-dasharray='14 10'/></g>"
    )
    p, w = lettering("Token", "Bungee", "#e5c06b", "#2a1c10", target_w=400, max_size=120)
    return f"<g>{coin}{p}</g>"


def art_moon():
    # A large gilt crescent centered directly behind the word (the Satoshi
    # treatment), stars balancing it on the upper right.
    sky = (
        "<g><path d='M599 335 A210 210 0 1 0 599 665 A170 170 0 1 1 599 335 Z' fill='#c9a227'/>"
        "<g fill='#c9a227'><path d='M700 300 l8 22 l22 8 l-22 8 l-8 22 l-8 -22 l-22 -8 l22 -8 Z'/>"
        "<path d='M770 380 l6 16 l16 6 l-16 6 l-6 16 l-6 -16 l-16 -6 l16 -6 Z'/>"
        "<path d='M652 414 l5 13 l13 5 l-13 5 l-5 13 l-5 -13 l-13 -5 l13 -5 Z'/></g></g>"
    )
    p, w = lettering("Moon", "CinzelDecorative", "#27418a", "#f4ecd8", target_w=460, max_size=150)
    return f"<g>{sky}{p}</g>"


# word: (builder, Category enum index 0=NOUN 1=VERB 2=ADJ 3=ADV,
#        curated material idx, curated background idx)
HONORS = {
    "Rekt": (art_rekt, 1, 13, 3),
    "Pepe": (art_pepe, 0, 0, 1),
    # Degen: ADJ per the updated normative honors list (owner-directed
    # 2026-06-12); backdrop moved Loam -> Butter, Cardboard's pastel
    # adjective-bias group, to match the POS palette convention.
    "Degen": (art_degen, 2, 1, 4),
    "Lambo": (art_lambo, 0, 16, 6),
    "Snipe": (art_snipe, 1, 12, 1),
    "Liquid": (art_liquid, 0, 11, 3),
    "Pump": (art_pump, 1, 3, 2),
    "Dump": (art_dump, 1, 2, 2),
    "Rug": (art_rug, 1, 5, 2),
    "Floor": (art_floor, 0, 15, 6),
    "Yield": (art_yield, 0, 4, 1),
    "Swap": (art_swap, 1, 0, 3),
    "Trade": (art_trade, 1, 14, 3),
    "Stake": (art_stake, 1, 8, 1),
    "Airdrop": (art_airdrop, 0, 1, 5),
    "Farm": (art_farm, 1, 8, 0),
    "Satoshi": (art_satoshi, 0, 18, 6),
    "Hype": (art_hype, 1, 13, 6),
    "Fee": (art_fee, 0, 2, 6),
    "Gas": (art_gas, 0, 16, 2),
    "Sweep": (art_sweep, 1, 9, 7),
    "Mint": (art_mint, 1, 0, 5),
    "Dev": (art_dev, 0, 3, 6),
    "Token": (art_token, 0, 10, 3),
    "Moon": (art_moon, 0, 19, 3),
}


def main() -> None:
    manifest = {}
    total = 0
    for word, (builder, cat, mat, bg) in HONORS.items():
        if mat in SMALL_MATERIALS:
            raise SystemExit(f"{word}: {SMALL_MATERIALS[mat]} is too small to host a 1/1 (owner rule)")
        frag = builder()
        if '"' in frag or "\n" in frag or "\\" in frag:
            raise SystemExit(f"{word}: fragment contains forbidden characters")
        if not (frag.startswith("<g") and frag.endswith("</g>")):
            raise SystemExit(f"{word}: not a <g> group")
        # The lettering (recognizable by its halo's paint-order) must be the
        # last element, so every enhancement layers beneath the word.
        if "paint-order='stroke'" not in frag[frag.rfind("<path"):]:
            raise SystemExit(f"{word}: lettering must be the last element of the fragment")
        path = OUT / f"{word}.svg"
        path.write_text(frag, encoding="utf-8")
        manifest[word] = {"file": f"{word}.svg", "category": cat, "material": mat, "background": bg}
        total += len(frag)
        print(f"  {word:<8} {len(frag):>6} bytes")
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"25 honors artworks, {total} bytes total (avg {total // 25})")


if __name__ == "__main__":
    main()
