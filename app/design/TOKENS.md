# Design tokens

Single source: CSS custom properties in [`app/globals.css`](../app/globals.css).
Components consume tokens only — no raw hex in component CSS (the one
exception: artwork colors, which come from the Renderer tables at render
time, exactly like the chain).

## Color

| Token | Value | Source in the collection | Use |
|---|---|---|---|
| `--paper` | `#f6f1e4` | Paper material surface | page ground |
| `--paper-raised` | `#fdfaf1` | — (paper, lifted) | cards/plates |
| `--paper-deep` | `#efe7d2` | paper shadow tones | wells, stripes |
| `--paper-edge` | `#e2d9c2` | Paper fragment stroke | borders |
| `--paper-fleck` | `#d8cdb0` | Paper fleck dots | hairlines, disabled |
| `--ink` | `#1b1b22` | India Ink | primary text |
| `--ink-soft` | `#4a4a52` | Graphite | secondary text |
| `--ink-faint` | `#807b6c` | — (AA-checked) | captions |
| `--sepia` | `#6b4a2b` | Sepia ink | eyebrows, quiet emphasis |
| `--indigo` | `#2c3a64` | Indigo ink | links, focus, info |
| `--teal` | `#1f6f6b` | Teal Surge bg | success, positive values |
| `--crimson` | `#8e2434` | Crimson ink | danger, irreversible |
| `--gold` | `#8a6d1c` | gold leaf (text-safe) | honors/legendary text |
| `--gold-leaf` | `#c9a227` | honors art gold | graphic accents only |
| `--tier-common…legendary` | see globals | Slate Mist / Olive / Indigo / Crimson / Gold | tier badges only |

Semantic aliases: `--bg`, `--fg`, `--link`, `--danger`, `--ok`, `--focus-ring`.

## Type

- `--font-serif`: Fraunces variable (local file, `app/fonts/Fraunces-VF.ttf`,
  weight axis 100–900, optical sizing auto) → Georgia fallback.
- `--font-mono`: system mono stack — data values, addresses, token ids.
- Scale (major third, 16px base): `--text-xs` 12 · `sm` 14 · `base` 16 ·
  `md` 20 · `lg` 25 · `xl` 31 · `2xl` 39 · `3xl` 49 · `4xl` 61.
- Leading: `--leading-tight` 1.12 (display), `snug` 1.3, `body` 1.55.
- `--tracking-caps` 0.14em for eyebrow/caps labels.

## Space, shape, elevation

- Space: 4px base, `--space-1…9` = 4/8/12/16/24/32/48/64/96.
- Radii: `--radius-1` 3px (controls), `--radius-2` 6px (plates).
- Shadows: `--shadow-lift` (resting card), `--shadow-plate` (hero/art plate);
  both rgba of `#1a1206` — the Renderer's own shadow flood color.
- Container: `--container` 72rem.

## Motion

`--dur-fast` 140ms, `--dur-base` 220ms, `--ease-out` cubic-bezier(.25,.6,.3,1).
Global `prefers-reduced-motion` kill-switch in globals.css.

## Primitive classes (globals.css)

`.container` · `.eyebrow` · `.mono` · `.rule` · `.plate` / `.plate--flat` ·
`.well` · `.btn` / `.btn--ghost` / `.btn--danger` (+ disabled) · `.badge` ·
`.skeleton` · `.visually-hidden`.

## Component inventory

### Added in Milestone 2

| Component | File | States designed |
|---|---|---|
| IrreversibleAction (🔒 pattern) | `components/Irreversible.tsx` | blocked · available (consequence + checkbox + type-to-confirm) · done/spent receipt |
| Meter | `components/ui.tsx` | tones ink/ok/danger/gold, optional marker |
| ScenarioBar + useScenario | `lib/scenario.tsx` | per-surface state-machine switcher (mint/game/burn/admin) |
| UnrevealedPlate | `app/mint/page.tsx` | the sealed pre-reveal token |
| Sentence stage + ledger | `app/game/page.tsx` | the signature revealed-sentence screen |
| Unbind stepper | `app/unbind/[id]/page.tsx` | 4 steps + bounty-forfeit warning + receipt |
| Admin panels (×8) | `app/admin/page.tsx` | forbidden · mid-launch · live · post-renounce |
| Owner wallet pill | `components/WalletButton.tsx` | gold dot + "owner" tag |

### Milestone 1

| Component | File | States designed |
|---|---|---|
| Logo glyph + lockup | `components/Logo.tsx` | themeable ground/ink |
| Favicon | `app/icon.svg` | light + dark tab (media query) |
| Header / nav | `components/SiteHeader.tsx` | active link, responsive wrap |
| Wallet button | `components/WalletButton.tsx` | disconnected · connecting · connected · wrong-network |
| Footer | `components/SiteFooter.tsx` | — |
| Dev toolbar | `components/DevToolbar.tsx` | collapsed/expanded |
| Stat | `components/ui.tsx` | default, ok/danger tone |
| Tier/Honors badges | `components/ui.tsx` | 5 tiers + honors |
| Empty/Error states | `components/ui.tsx` | designed, with retry |
| MockAction button | `components/ui.tsx` | rest/disabled + wiring note |
| Word artwork | `lib/art.tsx` (`WordArt`) | regular (composed) + honors (bespoke file) |
| Token card | `app/gallery/page.tsx` | loaded/hover/skeleton |
| Due-diligence panel | `app/gallery/[id]/page.tsx` | ok/neutral/dead-token |
| ComingSoon placeholder | `components/ComingSoon.tsx` | per-surface scope list |
