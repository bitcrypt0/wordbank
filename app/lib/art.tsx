import materialsJson from "./materials.json";

/**
 * Client-side twin of Renderer.sol's tokenURI assembly, for the design mock.
 *
 * `materials.json` is a verbatim copy of assets/traits/materials.json — the
 * Renderer's own material fragments and ink/background constraint tables —
 * so the art shown in this mock is composed by the same rules as the chain:
 * solid <rect> ground → material fragment → the word, set in Fraunces.
 *
 * Agent 9: replace callers of <WordArt> with the real `tokenURI` image
 * (data:application/json;base64 → image). Nothing else changes — the
 * layout treats art as a square plate either way.
 */

export interface MaterialInfo {
  name: string;
  tier: number;
  fragment: string;
  surface: string;
  inks: { name: string; color: string }[];
  backgrounds: { name: string; color: string; bias?: string }[];
  safeWidth: number;
}

export const TIERS = materialsJson.tiers as string[];
export const MATERIALS = materialsJson.materials as MaterialInfo[];

export const TIER_COLOR_VAR: Record<string, string> = {
  Common: "var(--tier-common)",
  Uncommon: "var(--tier-uncommon)",
  Rare: "var(--tier-rare)",
  Epic: "var(--tier-epic)",
  Legendary: "var(--tier-legendary)",
};

function escapeXml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/** SVG filter/gradient ids must be unique per inline instance on a page. */
function suffixIds(fragment: string, uid: string): string {
  return fragment
    .replace(/id='([^']+)'/g, `id='$1-${uid}'`)
    .replace(/url\(#([^)]+)\)/g, `url(#$1-${uid})`);
}

/** Mirrors the Renderer's fit rule: scale type to the material's safe width. */
function fitFontSize(word: string, safeWidth: number): number {
  return Math.min(190, Math.round((safeWidth * 1.9) / Math.max(word.length, 1)));
}

export function buildWordSvg(opts: {
  word: string;
  material: number;
  ink: number;
  background: number;
  uid: string;
}): string {
  const m = MATERIALS[opts.material];
  const bg = m.backgrounds[opts.background].color;
  const ink = m.inks[opts.ink].color;
  const fragment = suffixIds(m.fragment, opts.uid);
  const word = escapeXml(opts.word);
  const fontSize = fitFontSize(opts.word, m.safeWidth);
  return (
    `<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1000 1000' role='img' aria-label='${word} — ${m.name}'>` +
    `<rect width='1000' height='1000' fill='${bg}'/>` +
    fragment +
    `<text x='500' y='528' text-anchor='middle' font-size='${fontSize}' fill='${ink}' style='font-family:var(--font-serif);font-weight:500'>${word}</text>` +
    `</svg>`
  );
}

/**
 * One token's artwork as a square plate.
 * Regular words: composed inline from the Renderer's fragment tables.
 * Honors one-of-ones: agent 2's actual bespoke SVG files (path art, no text).
 */
export function WordArt({
  word,
  material,
  ink,
  background,
  honors,
  honorsArtSrc,
  uid,
  className,
}: {
  word: string;
  material: number;
  ink: number;
  background: number;
  honors?: boolean;
  honorsArtSrc?: string;
  uid: string;
  className?: string;
}) {
  if (honors && honorsArtSrc) {
    return (
      <img
        src={honorsArtSrc}
        alt={`${word} — honors one-of-one`}
        className={className}
        style={{ aspectRatio: "1 / 1", width: "100%" }}
      />
    );
  }
  return (
    <div
      className={className}
      style={{ aspectRatio: "1 / 1" }}
      dangerouslySetInnerHTML={{
        __html: buildWordSvg({ word, material, ink, background, uid }),
      }}
    />
  );
}
