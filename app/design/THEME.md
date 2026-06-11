# WORDBANK — theme rationale

*Agent 8 (uiux-design). Milestone 1, 2026-06-12.*

## The premise

The architecture doc's art brief is the design brief: **the word is the art**.
One strong typeface, materials as surfaces, solid-color grounds, restraint.
The site doesn't decorate the collection — it *is set like* the collection:
closer to a beautifully made book or a type-specimen sheet than to a DeFi
dashboard.

Three rules fall out of that premise, and every screen follows them:

1. **One voice.** The site is set in **Fraunces** — the exact SIL-OFL face
   embedded in every token's onchain SVG (`assets/font/`). Headings, body,
   buttons: all Fraunces. The single exception is data — amounts, addresses,
   token ids — set in the system mono stack so digits align and onchain
   values read as ledger entries, visually distinct from prose.
2. **Solid grounds.** The collection's backgrounds are always a single
   `<rect>` of solid color; so are the site's. No gradients, no glassmorphism,
   no texture images. Depth comes from one soft shadow (sampled from the
   Renderer's own `feDropShadow` flood color, `#1a1206`) so cards sit on the
   page the way materials sit on their grounds.
3. **Sampled pigments.** Every color token is taken from the Renderer's
   actual ink/surface/background tables (`assets/traits/materials.json`):
   the page is Paper (`#f6f1e4`), text is India Ink (`#1b1b22`), links are
   Indigo, danger is Crimson, success is Teal, honors are Gold Leaf. The
   site and the collection are literally the same palette.

## What the theme avoids (per charter)

Dark-purple gradients, glassmorphism cards, rocket emojis, neon glows,
crypto-dashboard density. Also: no decorative use of rarity — tier colors
appear only as labels, and rarity copy always restates that visual rarity
has **zero** gameplay effect (system invariant 6).

## Voice in components

- **Eyebrows** — letterspaced caps labels (sepia) above headings: the
  specimen-sheet register.
- **Plates** — cards are "plates" (as in printing): raised paper, hairline
  edge, one shadow.
- **Stats** — mono, tabular numerals, with a quiet one-line detail underneath.
- **States** — loading is a paper shimmer (skeleton); empty is a quiet
  `∅` plate with guidance; error is a crimson `⚠` plate with a retry. Every
  data-bearing component ships all three (dev toolbar, bottom right).

## Motion

Paper-weight: 140–220ms ease-out transitions, small translates, no bounces,
`prefers-reduced-motion` respected globally. Nothing animates that isn't
responding to the user.

## Accessibility

WCAG-AA contrast on paper for all text inks (`--ink`, `--ink-soft`,
`--ink-faint` ≥ 4.5:1; `--gold` is the darkened text-safe variant of gold
leaf). Semantic landmarks, keyboard-navigable controls, `:focus-visible`
ring in indigo, alt text on all artwork.
