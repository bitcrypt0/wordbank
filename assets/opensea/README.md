# WORDBANK — OpenSea collection assets

Designed by Agent 8 (uiux-design), 2026-06-16, from the WORDBANK brand system
(`app/design/THEME.md`, `LOGO.md`, `components/Logo.tsx`, and the sampled
palette in `assets/traits/materials.json`).

## The concept

A type-specimen sheet, not a DeFi banner. Paper ground (`#f6f1e4`), India Ink
type (`#1b1b22`), the collection's own Fraunces face, a hairline specimen
frame, and one soft shadow. The wordmark is the hero — "the word is the art" —
and a restrained row of six "word plates" spells the collection's motto on the
materials palette — HODL · TO · PLAY · HOLD · TO · EARN ("hodl to play, hold to
earn"). Note HODL (crypto slang) and HOLD (normal spelling) are intentionally
different. The plates run parchment → ink → teal → gold leaf → crimson →
indigo; the two short "TO" plates are narrower. No gradients, no glassmorphism,
no neon. The site, the NFTs, and these assets are literally the same palette and
typeface.

## Files

| File | Size | Use on OpenSea |
|------|------|----------------|
| `wordbank-banner.png`  | **1400×400** | **Collection banner** (the required one) |
| `wordbank-banner.svg`  | 1400×400 | Source/vector master (text outlined) |
| `wordbank-avatar.png`  | 350×350  | Collection logo / icon (the W glyph mark) |
| `wordbank-avatar.svg`  | 350×350  | Source/vector master |
| `wordbank-featured.png`| 600×400  | Featured image |
| `wordbank-featured.svg`| 600×400  | Source/vector master |

All PNGs are the exact pixel sizes above and are small (banner ≈ 40 KB).
The text in every SVG is converted to **outline paths**, so the SVGs render
identically anywhere even without the Fraunces font installed.

## How to upload on OpenSea (for the owner)

1. Go to your collection on OpenSea → **Edit** (or the collection settings).
2. **Logo image:** upload `wordbank-avatar.png` (350×350).
3. **Featured image:** upload `wordbank-featured.png` (600×400).
4. **Banner image:** upload `wordbank-banner.png` (1400×400). OpenSea wants a
   raster image here — use the **PNG**, not the SVG.
5. Save. OpenSea overlays your logo at the **bottom-left** of the banner and
   crops the banner toward the center on phones. This banner was designed for
   that: the whole left-bottom corner is left empty for the logo, and all the
   important text sits in the centre so nothing gets cut off.

## Reproducing / editing the assets

The `_work/` folder holds the generator and the font cuts:

```
cd assets/opensea/_work
NODE_PATH="../../../app/node_modules" node build-banner.cjs
```

- `build-banner.cjs` builds all three SVGs and rasterizes them to PNG.
- `fraunces-*.ttf` are static instances of `app/app/fonts/Fraunces-VF.ttf`
  (the project's SIL-OFL face), made with `fonttools varLib.instancer` at
  chosen optical-size/weight axes for the display and text cuts.
- Rasterization uses **sharp** (already a dependency of `app/`): the SVG is
  rendered at 3× and downscaled with a Lanczos kernel for crisp edges.
- `opentype.js` is used only by the build script to outline the type; it is
  **not** added to `app/package.json` (installed with `--no-save`, dev tooling
  only). No new runtime dependency was introduced.
