# The WORDBANK mark

## Concept — a word on a solid ground

The collection's entire art system is one sentence: *a word, set in one
typeface, on a solid-color material.* The mark is that system reduced to a
single glyph:

- **The plate** — a solid square with 6/64 corner radius: the collection's
  "background is always a single `<rect>`" rule, made emblem.
- **The frame** — a 1px hairline inset at 28% opacity: the specimen plate /
  bookplate register. It reads at display sizes and disappears gracefully
  at 16px.
- **The W** — a serif-cut W drawn as a single mitered polyline with two
  top serif bars. It is constructed geometry (not a font glyph), so the
  favicon renders identically everywhere with no font dependency, and it
  holds its weight from 16px to hero scale.

The mark inverts cleanly (ink-on-paper / paper-on-ink) and is themeable —
the component takes `ground`/`ink` colors, defaulting to CSS variables.

## Variants

| Variant | Where | File |
|---|---|---|
| Glyph only | favicon, footer, hero, tight spaces | `components/Logo.tsx` → `WordbankGlyph` |
| Horizontal lockup | header, documents | `components/Logo.tsx` → `WordbankLockup` (glyph + letterspaced FRAUNCES wordmark, optically aligned) |
| Favicon | browser tab | `app/icon.svg` — **identical geometry**, fixed colors, inverts for dark tabs via `prefers-color-scheme` |

**Rule: one mark everywhere.** If the glyph geometry ever changes, change
`WordbankGlyph` and `app/icon.svg` together — they are the same drawing.

## Construction (viewBox 0 0 64 64)

```
plate   rect 64×64, rx 6
frame   rect 3.5,3.5 57×57, rx 3.5, stroke 1, opacity .28
W       polyline 15,20 → 24.5,45.5 → 32,24.5 → 39.5,45.5 → 49,20
        stroke 5.2, butt caps, miter joins
serifs  M10.8 18.4 h8.4 · M44.8 18.4 h8.4, stroke 3.2
```

Clear space: half the plate width on all sides. Minimum size: 14px.

PNG fallback: `app/icon.png` (64×64, ~1.5KB) — rendered from the same
geometry for legacy browsers that ignore SVG favicons. Next.js emits
`<link rel="icon">` tags for both files automatically. If the mark ever
changes, regenerate the PNG (the GDI+ one-liner lives in the M2 session
log) along with the SVG.
