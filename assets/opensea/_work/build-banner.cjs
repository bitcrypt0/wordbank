/*
 * WORDBANK — OpenSea collection asset generator (Agent 8 / uiux-design).
 *
 * Produces, from the brand system, three on-brand assets:
 *   - wordbank-banner.svg / .png   (1400x400, the required banner)
 *   - wordbank-avatar.svg  / .png  (350x350, collection icon)
 *   - wordbank-featured.svg/ .png  (600x400, featured image)
 *
 * Type is OUTLINED to SVG paths from the project's SIL-OFL Fraunces face, so
 * the SVGs render identically with no font installed. PNGs are rasterized with
 * sharp. Run with NODE_PATH pointing at app/node_modules (see build.sh).
 *
 * Colors are sampled straight from the brand: app/design/THEME.md +
 * assets/traits/materials.json. No gradients, no glass, one soft shadow.
 */
const fs = require("fs");
const path = require("path");
const ot = require("opentype.js");
const sharp = require("sharp");

const WORK = __dirname;
const OUT = path.resolve(WORK, "..");

// --- Fonts (static instances of Fraunces-VF, instantiated via fonttools) ---
const fontDisplay = ot.parse(fs.readFileSync(path.join(WORK, "fraunces-display-600.ttf")));
const fontText = ot.parse(fs.readFileSync(path.join(WORK, "fraunces-text-500.ttf")));

// --- Sampled palette (THEME.md / materials.json) ---
const C = {
  paper: "#f6f1e4",      // Paper ground
  ink: "#1b1b22",        // India Ink
  inkSoft: "#3a3a40",    // Graphite
  sepia: "#6b4a2b",      // Sepia eyebrow
  hair: "#e2d9c2",       // Paper edge hairline
  indigo: "#2c3a64",     // Indigo
  crimson: "#8e2434",    // Crimson / Carmine
  teal: "#1f6f6b",       // Teal
  gold: "#9a7218",       // Gold Leaf (text-safe burnished)
  goldLeaf: "#c9a227",   // Gold Leaf surface
  parchment: "#e6d3a4",  // Parchment surface
  parchEdge: "#c2a064",
  shadow: "#1a1206",     // the one soft shadow
};

// ---- helpers -------------------------------------------------------------
// Internal outline supersample factor. We outline glyphs at SS× the display
// size and shrink with a scale() transform, because opentype.js + resvg lose
// or mangle tight-curve glyphs (s, a, e...) when the path coordinates are
// tiny (e.g. a 24px word). Large coordinates keep every contour intact.
const SS = 10;

// Outline `text` at `size` px with em-fraction letterspacing. Returns:
//   { paths, width, scale } — `paths` is a string of separate <path> elements
//   in SS×-magnified coordinates (one per glyph, so resvg never drops any),
//   `scale` (= 1/SS) is what callers apply, and `width` is the DISPLAY-unit
//   advance width. Place with renderText(ob, tx, ty, fill).
function outline(font, text, size, letterSpacing = 0) {
  const lsDisp = letterSpacing * size;
  const lsBig = lsDisp * SS;
  const big = size * SS;
  let total = 0;
  let x = 0;
  let paths = "";
  for (const ch of text) {
    // Draw each glyph at the origin (x=0) and position it with a per-glyph
    // translate. Baking a large x into the path coordinates can make
    // opentype.js emit a glyph's inner counter (e.g. the bowl of "D") with a
    // winding/precision the rasterizer drops at certain offsets, filling the
    // counter solid. Keeping every glyph at the origin avoids that entirely.
    const p = font.getPath(ch, 0, 0, big);
    const d = p.toPathData(3);
    if (d.trim()) paths += `<path d="${d}" transform="translate(${x.toFixed(2)} 0)"/>`;
    x += font.getAdvanceWidth(ch, big) + lsBig;
  }
  for (const ch of text) total += font.getAdvanceWidth(ch, size) + lsDisp;
  total -= lsDisp;
  return { paths, width: total, scale: 1 / SS };
}

// Place an outlined run: translate to (tx, ty) at display scale, then shrink
// the SS×-magnified glyph paths back down. fill colors the whole run.
function renderText(ob, tx, ty, fill) {
  return `<g transform="translate(${(+tx).toFixed(2)} ${(+ty).toFixed(2)}) scale(${ob.scale})" fill="${fill}">${ob.paths}</g>`;
}

// Bounding box (cap metrics) of an outlined string at size.
function bbox(font, text, size, letterSpacing = 0) {
  const ls = letterSpacing * size;
  let x = 0;
  let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity;
  let i = 0;
  for (const ch of text) {
    const p = font.getPath(ch, x, 0, size);
    const b = p.getBoundingBox();
    if (b.x1 < x1) x1 = b.x1;
    if (b.y1 < y1) y1 = b.y1;
    if (b.x2 > x2) x2 = b.x2;
    if (b.y2 > y2) y2 = b.y2;
    x += font.getAdvanceWidth(ch, size) + ls;
    i++;
  }
  return { x1, y1, x2, y2, w: x2 - x1, h: y2 - y1 };
}

// The WORDBANK glyph mark (the constructed serif-cut W on a solid plate),
// scaled into a box of `s` px at (px,py). Geometry mirrors components/Logo.tsx
// and app/icon.svg exactly (viewBox 0 0 64 64).
function glyphMark(px, py, s, ground, ink) {
  const k = s / 64;
  const T = (n) => (n * k).toFixed(3);
  const X = (n) => (px + n * k).toFixed(3);
  const Y = (n) => (py + n * k).toFixed(3);
  return `
  <g>
    <rect x="${px.toFixed(2)}" y="${py.toFixed(2)}" width="${s.toFixed(2)}" height="${s.toFixed(2)}" rx="${T(6)}" fill="${ground}"/>
    <rect x="${X(3.5)}" y="${Y(3.5)}" width="${T(57)}" height="${T(57)}" rx="${T(3.5)}" fill="none" stroke="${ink}" stroke-width="${T(1)}" opacity="0.28"/>
    <g stroke="${ink}" fill="none">
      <polyline points="${X(15)},${Y(20)} ${X(24.5)},${Y(45.5)} ${X(32)},${Y(24.5)} ${X(39.5)},${Y(45.5)} ${X(49)},${Y(20)}" stroke-width="${T(5.2)}" stroke-linecap="butt" stroke-linejoin="miter"/>
      <path d="M${X(10.8)} ${Y(18.4)} h${T(8.4)} M${X(44.8)} ${Y(18.4)} h${T(8.4)}" stroke-width="${T(3.2)}"/>
    </g>
  </g>`;
}

// A small "word plate": a word outlined in `ink` on a solid `ground` plate
// with a hairline edge and the one soft shadow. Centered in the plate.
function wordPlate(x, y, w, h, word, ground, ink, edge, opts = {}) {
  const fontSize = opts.fontSize || h * 0.42;
  const ob = outline(fontText, word, fontSize, opts.ls || 0.02);
  const bb = bbox(fontText, word, fontSize, opts.ls || 0.02);
  // center horizontally & vertically (use cap box)
  const tx = x + (w - bb.w) / 2 - bb.x1;
  const ty = y + h / 2 + bb.h / 2 - (bb.y2); // baseline so cap box is centered
  const rx = opts.rx != null ? opts.rx : 7;
  const edgeStroke = edge ? `<rect x="${(x+1).toFixed(2)}" y="${(y+1).toFixed(2)}" width="${(w-2).toFixed(2)}" height="${(h-2).toFixed(2)}" rx="${rx}" fill="none" stroke="${edge}" stroke-width="1.5" opacity="0.7"/>` : "";
  return `
  <g filter="url(#plateShadow)">
    <rect x="${x.toFixed(2)}" y="${y.toFixed(2)}" width="${w.toFixed(2)}" height="${h.toFixed(2)}" rx="${rx}" fill="${ground}"/>
  </g>
  ${edgeStroke}
  ${renderText(ob, tx, ty, ink)}`;
}

// ---- BANNER 1400x400 -----------------------------------------------------
function buildBanner() {
  const W = 1400, H = 400;
  // Wordmark: WORDBANK, centered horizontally, slightly above center so the
  // tagline sits beneath and the specimen row sits above; all clear of the
  // bottom-left 400px avatar square.
  const wmSize = 124;            // pixel cap target ~ tuned below
  const wmLS = 0.04;             // letterspacing, refined
  let ob = outline(fontDisplay, "WORDBANK", wmSize, wmLS);
  let bb = bbox(fontDisplay, "WORDBANK", wmSize, wmLS);
  // scale to a target width (keep clear of edges: target ~ 760px)
  const targetW = 760;
  const scale = targetW / bb.w;
  const finalSize = wmSize * scale;
  ob = outline(fontDisplay, "WORDBANK", finalSize, wmLS);
  bb = bbox(fontDisplay, "WORDBANK", finalSize, wmLS);
  const cx = W / 2;
  const wmY = 214; // baseline of wordmark
  const wmTx = cx - bb.w / 2 - bb.x1;

  // Eyebrow above the wordmark
  const eyebrow = "AN  ONCHAIN  TYPE  SPECIMEN";
  const ebSize = 21;
  const ebLS = 0.34;
  const ebOb = outline(fontText, eyebrow, ebSize, ebLS);
  const ebBb = bbox(fontText, eyebrow, ebSize, ebLS);
  const ebY = 96;
  const ebTx = cx - ebBb.w / 2 - ebBb.x1;

  // Tagline below the wordmark
  const tagline = "the word is the art";
  const tagSize = 31;
  const tagLS = 0.015;
  const tagOb = outline(fontText, tagline, tagSize, tagLS);
  const tagBb = bbox(fontText, tagline, tagSize, tagLS);
  const tagY = 284;
  const tagTx = cx - tagBb.w / 2 - tagBb.x1;

  // Specimen word-plate row: small plates on their materials, parchment->gold.
  // Placed in a single quiet row UNDER the tagline, centered, well above the
  // bottom edge and clear of the bottom-left avatar zone.
  // SIX plates reading the brand motto: HODL · TO · PLAY · HODL · TO · EARN
  // — the phrase "HODL TO PLAY, HODL TO EARN".
  //  ⚠ "HODL" is intentional crypto slang for "hold" and appears in BOTH
  //  phrases (plates 1 and 4); every occurrence is spelled HODL — never "HOLD".
  // The two short "TO" plates are narrower than the word plates.
  // A comma is set as a small ink mark on the paper ground BETWEEN the PLAY
  // plate and the second HODL plate (i.e. after the first phrase), not boxed.
  // Materials assigned across the collection's palette, parchment -> gold leaf:
  //   HODL = parchment, TO = ink, PLAY = teal, HODL = goldLeaf, TO = crimson,
  //   EARN = indigo.  (Plate 4 keeps its gold-leaf treatment; only its letters
  //   changed from HOLD to HODL.)
  // Each: [word, ground, ink, edge, narrow?]
  const specimens = [
    ["HODL", C.parchment, C.ink,    C.parchEdge, false],
    ["TO",   C.ink,       C.paper,  null,        true ],
    ["PLAY", C.teal,      C.paper,  null,        false],
    ["HODL", C.goldLeaf,  C.ink,    "#e8cc6a",   false],
    ["TO",   C.crimson,   C.paper,  null,        true ],
    ["EARN", C.indigo,    C.paper,  null,        false],
  ];
  const plateW = 98, narrowW = 56, plateH = 50, gap = 12;
  // Widen the single gap after PLAY (index 2 -> 3) to seat the ink comma on the
  // paper ground between the two phrases. The comma index = the plate it sits
  // AFTER (the PLAY plate, index 2).
  const commaAfter = 2;
  const commaGap = 30;            // wider gap to give the comma breathing room
  const rowW = specimens.reduce((s, sp) => s + (sp[4] ? narrowW : plateW), 0)
    + (specimens.length - 1) * gap + (commaGap - gap);
  let sx = cx - rowW / 2;
  const sy = 318;
  let platesSvg = "";
  let commaSvg = "";
  specimens.forEach(([word, g, ik, ed, narrow], i) => {
    const w = narrow ? narrowW : plateW;
    platesSvg += wordPlate(sx, sy, w, plateH, word, g, ik, ed, { fontSize: narrow ? 24 : 26, ls: 0.06, rx: 8 });
    sx += w;
    if (i === commaAfter) {
      // Render an ink comma glyph centered in the wide gap, baseline aligned to
      // the plate text baseline so it reads as punctuation between the phrases.
      const commaSize = 56;
      const cob = outline(fontText, ",", commaSize);
      const cbb = bbox(fontText, ",", commaSize);
      const ctx = sx + commaGap / 2 - cbb.w / 2 - cbb.x1;
      // The plate text caps are centered in the plate; align the comma's
      // baseline to roughly the foot of those caps.
      const cty = sy + plateH / 2 + 26 * 0.5; // ~cap-foot of a 26px plate word
      commaSvg += renderText(cob, ctx, cty, C.ink);
      sx += commaGap;
    } else if (i < specimens.length - 1) {
      sx += gap;
    }
  });

  // Two thin rule lines flanking the eyebrow (specimen-sheet register)
  const ruleY = ebY - ebSize * 0.34;
  const ruleGap = 30;
  const ruleLen = 150;
  const leftRuleX2 = ebTx + ebBb.x1 - ruleGap;
  const rightRuleX1 = ebTx + ebBb.x1 + ebBb.w + ruleGap;

  const svg = `<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="WORDBANK — an onchain type specimen. The word is the art.">
  <defs>
    <filter id="plateShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="4" stdDeviation="6" flood-color="${C.shadow}" flood-opacity="0.22"/>
    </filter>
  </defs>
  <!-- Paper ground (single solid rect, per the collection's rule) -->
  <rect width="${W}" height="${H}" fill="${C.paper}"/>
  <!-- specimen-sheet outer hairline frame -->
  <rect x="20.5" y="20.5" width="${W-41}" height="${H-41}" rx="6" fill="none" stroke="${C.hair}" stroke-width="2"/>
  <rect x="27.5" y="27.5" width="${W-55}" height="${H-55}" rx="4" fill="none" stroke="${C.hair}" stroke-width="1" opacity="0.6"/>

  <!-- eyebrow rules -->
  <line x1="${leftRuleX2 - ruleLen}" y1="${ruleY}" x2="${leftRuleX2}" y2="${ruleY}" stroke="${C.sepia}" stroke-width="1" opacity="0.55"/>
  <line x1="${rightRuleX1}" y1="${ruleY}" x2="${rightRuleX1 + ruleLen}" y2="${ruleY}" stroke="${C.sepia}" stroke-width="1" opacity="0.55"/>

  <!-- eyebrow -->
  ${renderText(ebOb, ebTx, ebY, C.sepia)}

  <!-- WORDBANK wordmark -->
  ${renderText(ob, wmTx, wmY, C.ink)}

  <!-- tagline -->
  ${renderText(tagOb, tagTx, tagY, C.inkSoft)}

  <!-- specimen word-plate row -->
  ${platesSvg}
  <!-- ink comma on the paper ground, between the two phrases (after PLAY) -->
  ${commaSvg}
</svg>`;
  return { svg, W, H };
}

// ---- AVATAR 350x350 ------------------------------------------------------
function buildAvatar() {
  const S = 350;
  // The glyph mark, centered, on paper, with a hairline frame band.
  const markSize = 232;
  const px = (S - markSize) / 2;
  const py = (S - markSize) / 2 - 6;
  const mark = glyphMark(px, py, markSize, C.ink, C.paper);
  const svg = `<svg width="${S}" height="${S}" viewBox="0 0 ${S} ${S}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="WORDBANK">
  <rect width="${S}" height="${S}" fill="${C.paper}"/>
  <rect x="14.5" y="14.5" width="${S-29}" height="${S-29}" rx="10" fill="none" stroke="${C.hair}" stroke-width="2"/>
  ${mark}
</svg>`;
  return { svg, W: S, H: S };
}

// ---- FEATURED 600x400 ----------------------------------------------------
function buildFeatured() {
  const W = 600, H = 400;
  const cx = W / 2;
  // glyph mark on top, wordmark beneath, tagline.
  const markSize = 120;
  const mark = glyphMark(cx - markSize / 2, 70, markSize, C.ink, C.paper);

  let ob = outline(fontDisplay, "WORDBANK", 100, 0.03);
  let bb = bbox(fontDisplay, "WORDBANK", 100, 0.03);
  const targetW = 420;
  const fs = 100 * (targetW / bb.w);
  ob = outline(fontDisplay, "WORDBANK", fs, 0.03);
  bb = bbox(fontDisplay, "WORDBANK", fs, 0.03);
  const wmY = 290;
  const wmTx = cx - bb.w / 2 - bb.x1;

  const tagline = "the word is the art";
  const tagOb = outline(fontText, tagline, 24, 0.02);
  const tagBb = bbox(fontText, tagline, 24, 0.02);
  const tagTx = cx - tagBb.w / 2 - tagBb.x1;

  const svg = `<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="WORDBANK — the word is the art">
  <rect width="${W}" height="${H}" fill="${C.paper}"/>
  <rect x="18.5" y="18.5" width="${W-37}" height="${H-37}" rx="6" fill="none" stroke="${C.hair}" stroke-width="2"/>
  ${mark}
  ${renderText(ob, wmTx, wmY, C.ink)}
  ${renderText(tagOb, tagTx, 330, C.inkSoft)}
</svg>`;
  return { svg, W, H };
}

async function emit(name, { svg, W, H }) {
  const svgPath = path.join(OUT, name + ".svg");
  fs.writeFileSync(svgPath, svg);
  const pngPath = path.join(OUT, name + ".png");
  // Render the SVG at 3x via density (SVG default is 96dpi in resvg), then
  // downscale to exact target with a high-quality kernel. Supersampling keeps
  // small outlined text crisp; no palette quantization (it mangles AA text).
  const supersample = 3;
  await sharp(Buffer.from(svg), { density: 96 * supersample })
    .resize(W, H, { fit: "fill", kernel: "lanczos3" })
    .png({ compressionLevel: 9, palette: false })
    .toFile(pngPath);
  const st = fs.statSync(pngPath);
  console.log(`${name}: SVG ${(fs.statSync(svgPath).size/1024).toFixed(1)}KB, PNG ${W}x${H} ${(st.size/1024).toFixed(1)}KB`);
}

(async () => {
  await emit("wordbank-banner", buildBanner());
  await emit("wordbank-avatar", buildAvatar());
  await emit("wordbank-featured", buildFeatured());
  console.log("done");
})();
