# WORDBANK visual trait system — decisions & rationale

Agent 2 (renderer-art). The architecture delegates four decisions to this document:
the OFL typeface, the concrete ink/background constraint tables, the template set,
and the word list. All four are decided below. **None of it touches gameplay**
(system invariant 6): the BountyEngine and RewardsDistributor never read a visual
trait, and the metadata description states this on every token.

## Typeface: Fraunces (SIL OFL 1.1)

One face across all 10,000 tokens — the word is the art; uniform type makes the
collection read as a set. Chosen instance: **opsz 144, wght 564, SOFT 0, WONK 1**
(display optical size, semibold weight, crisp serifs, the "wonky" alternate forms on).

Why Fraunces:
- **Display-grade at 1000px canvases.** Its 144pt optical size is drawn for exactly
  this use; high contrast and tight spacing hold up rasterized at marketplace thumbnail
  sizes and full screen alike.
- **Era-neutral bookishness.** The materials run papyrus → newsprint; an old-style
  soft serif with modern construction sits believably on all of them.
- **Distinctive without gimmick.** WONK=1 letterforms give the collection a
  recognizable silhouette ("that's a WORDBANK word") while staying legible.
- **Subsets tiny.** A–Z + a–z with kerning, hinting stripped: **6,740 bytes** WOFF2 —
  one SSTORE2 chunk, ~1.4M gas once, shared by every tokenURI.

Pipeline: `tools/font/subset_font.py` (pins the variable axes, subsets, emits
`assets/font/font_chunks.json` for the loader). License: `assets/font/OFL.txt`.

## Materials: 20 surfaces in 5 tiers

The architecture's tier table lists 20 materials (4 Common, 5 Uncommon, 5 Rare,
4 Epic, 2 Legendary) — note: the agent charter says "19" in one place; the
architecture table governs. The Rare tier's "slate" slot ships as **Concrete**:
the original slate drawing read as concrete, so the owner directed a rename
rather than a redraw (owner-confirmed 2026-06-12; the material's chalk-ink
palette and rarity share are unchanged from the slate slot). Each material is one reusable `<g>` SVG fragment
(stored once via SSTORE2), a `surface` color, and a **safeWidth** — the usable
text width of its writing area (the stained-glass pane is 470px; a paper sheet
is 700px). The Renderer scales the word to `safeWidth / (0.55em × length)`,
capped at 190px.

Rarity shares (offchain assignment, `rarity.json`): Common 52%, Uncommon 26%,
Rare 13.5%, Epic 6.5%, **Legendary 2%**, split evenly inside each tier. Rarity is
aesthetic flex only — a gold-leaf word has exactly the same odds, rewards, and
backing as a paper word.

## Constraint tables: `validInks[material]` / `validBackgrounds[material]`

Inks and backgrounds are **material-relative indices**, never global ids. The
tables in `materials.json` are the single source of truth and are enforced by
`tools/validate_traits.py`:

- every ink ≥ **3.0 WCAG contrast** against its material's surface (display-size
  text threshold — the word is 100px+ tall);
- every background either ≥ 1.3 contrast or ≥ 30° hue distance from the surface,
  so the material silhouette always reads against the backdrop;
- backgrounds are always **one solid `<rect>`** — no gradients anywhere in the
  Renderer's output (checked by unit tests);
- every material offers at least one background in each POS bias group.

Ink palettes are era-honest per material: iron gall on parchment, chalk on
chalkboard and concrete, gilt and bone on leather, patina/enamel/silver on
copper, carbon and ochre on papyrus. The validator caught and forced fixes to 12
too-marginal combinations during curation — the tables ship contrast-proven.

## POS palette bias (color only, never odds)

Backgrounds are grouped by part of speech in every material's table:
**nouns → earthy · verbs → vivid · adjectives → pastel · adverbs → cool/muted.**
The bias lives in the offchain assignment (`tools/assign_traits.py`): a token
draws from its category's group with probability **0.7**, else uniformly from the
material's whole table. Sentences displayed together therefore tend toward
coherent color chords (earthy subjects, vivid actions) without becoming a
readable signal. The Renderer itself just looks indices up; nothing onchain
branches on category for anything but the attribute string.

## Honors (25 one-of-ones)

The 25 normative words are pure **SVG path art** — ornate OFL display lettering
(Pirata One, Rye, Cinzel Decorative, Berkshire Swash, Pacifico, Monoton, Titan
One, Allerta Stencil, Bungee, Space Mono) converted to baked outlines by
`tools/honors/build_honors.py`, plus a bespoke decoration per word (Rekt's
cracked concrete, Satoshi's ₿ coin on gold leaf, Dev's terminal prompt on
chalkboard, Mint's NFT printer…). No font dependency survives into the art;
every piece carries a halo outline so it stays legible on its surface. Honors
tokens' surfaces are **curated, not random** (`assets/honors/manifest.json`) —
they are 1/1s; the provenance shuffle still decides which tokenId receives
which word. Metadata reports `Ink: Bespoke Lettering` and `1/1: Yes` for these
tokens ("honors" survives only as the internal field name in the frozen
`WordData` struct — collectors never see it).

Two owner rules govern 1/1 composition (directed 2026-06-12, both enforced at
build time by `tools/honors/build_honors.py`):

- **Enhancements layer beneath the word.** The bespoke lettering is always the
  last element of the fragment — every decoration renders behind it (Satoshi's
  ₿ mark is the reference treatment) — and the word sits centered on its
  material like every other token, never displaced to make room for art.
- **Small materials host no 1/1s.** Banner, Ribbon, and Stained Glass have
  writing areas too cramped for a word plus its layered enhancement; they stay
  in the regular rotation but are never curated for honors. (Airdrop, formerly
  on Banner, was re-homed to Cardboard — a supply drop — under this rule.)

## Pre-reveal placeholder (`unrevealedTokenURI`, interfaces-v4, 2026-06-13)

Before the provenance offset is fixed, every token renders an onchain
**"unrevealed" specimen card** instead of word art (otherwise marketplaces show
a gray box during the whole mint window). `Renderer.unrevealedTokenURI(tokenId)`
takes **only the tokenId** — never `WordData`, no trait, no slot lookup — so it
is *structurally* incapable of leaking the eventual assignment: the art is
byte-identical for every token except the displayed `#id`. The snapshot test
`test_unrevealed_differsOnlyByIdText` asserts exactly that.

Design: ink ground (`#1b1b22`), a double keyline frame, `WORDBANK` and
`UNREVEALED` set in the shared onchain WB font (reused, not re-embedded), a
three-dot seal, and the `#id`. The WB subset is **A–Z + a–z only** (no digits),
so the id is drawn from baked Fraunces digit + `#` outlines in
`src/libraries/Numerals.sol` (generated by `tools/font/build_numerals.py` from
`Fraunces-VF.ttf` at the same instance the WB subset pins). Colors are the
brand palette (`app/app/globals.css`), so the onchain card and the dApp's
"Before the Reveal" mint card agree. Owner preview: `assets/previews/unrevealed.svg`
and the "Before the reveal" section of `assets/previews/index.html`.

## Word list & templates

`assets/wordlist.json`: 10,000 unique words — 4,999 NOUN / 2,500 VERB / 1,701 ADJ
/ 800 ADV (noun/verb-heavy so templates keep filling as the collection burns
down; the off-round totals reflect the owner-directed recategorization of the
honors word Degen from NOUN to ADJ, 2026-06-12 — the regular pool is unchanged). Built by `tools/wordlist/build_wordlist.py` from WordNet 3.1 POS indexes
ranked by corpus frequency, with function-word, proper-noun, irregular-inflection,
and profanity filters; every word is base-form, lowercase a–z, 3–12 chars, inside
the font subset. The 25 honors words ship capitalized with their normative
categories. `tools/wordlist/validate_wordlist.py` gates all of this.

`assets/templates.json`: 18 templates, 2–7 slots (normative cap 7). Because the
list stores base forms, **every VERB slot sits after a modal/auxiliary, an
imperative opening, "to", or a plural subject** — generated sentences are always
grammatical. Fragments avoid "a/an" (word-initial-vowel hazard). Encoding
(fragments interleaved with category slots) is documented in the file for
agent 4's onchain loader.

## Storage gas (measured, one-time deploy cost)

| Asset | Bytes | Gas |
|---|---|---|
| Font (1 SSTORE2 chunk) | 6,740 | 1,435,953 |
| 20 materials + constraint tables | ~21 KB fragments + tables | 17,585,031 |
| 25 honors path artworks | 70,831 | 15,718,234 |
| **Total** | | **≈ 34.7M** (spread over ~46 loader txs, then `seal()`) |

`tokenURI` itself is view-only (offchain `eth_call`); worst case (honors on the
largest material) stays far under the 30M node-compat budget required by the
frozen `IRenderer`.

## Provenance & regeneration

`tools/assign_traits.py` deterministically (seed `WORDBANK-assignment-v1`)
produces `assets/assignments.json` — the full shuffled word/trait assignment
whose keccak256 is the provenance commitment. Regenerate everything with:

```
python tools/font/subset_font.py
python tools/font/build_numerals.py
python tools/validate_traits.py
python tools/honors/build_honors.py
python tools/wordlist/build_wordlist.py && python tools/wordlist/validate_wordlist.py
python tools/validate_templates.py
python tools/gen_assets_sol.py
forge test --match-contract PreviewGen && python tools/preview/build_gallery.py
python tools/assign_traits.py
```

The owner preview gallery (`assets/previews/index.html`) is decoded from real
`tokenURI` output every time — what the owner approves is exactly what mints.
