/**
 * Bounty sentence-template parsing for the admin "Add template" + bulk import.
 *
 * The on-chain encoding (BountyEngine + assets/templates.json) is verbatim:
 *   sentence = fragments[0] + word(slots[0]) + fragments[1] + … + fragments[n]
 * There is NO auto-spacing — the spaces live INSIDE the fragments. So fragments
 * must be parsed WITHOUT trimming: "The | | will |." → ["The "," "," will ","."].
 * Pure functions only, so the round-trip spacing is unit-tested directly.
 */

export const CATEGORY_NAMES = ["NOUN", "VERB", "ADJ", "ADV"] as const;
export type CategoryName = (typeof CATEGORY_NAMES)[number];

/** Sample words per category — used to render a readable preview sentence. */
export const SAMPLE_WORD: Record<CategoryName, string> = {
  NOUN: "ember",
  VERB: "wander",
  ADJ: "luminous",
  ADV: "softly",
};

/** Parse comma-separated category names → enum indices. Unknown → -1. */
export function parseSlots(input: string): number[] {
  return input
    .split(",")
    .map((s) => s.trim().toUpperCase())
    .filter((s) => s.length > 0)
    .map((s) => (CATEGORY_NAMES as readonly string[]).indexOf(s));
}

/**
 * Parse fragments VERBATIM — split on "|" and DO NOT trim. The exact text
 * between pipes (spaces included) is the fragment.
 */
export function parseFragments(input: string): string[] {
  return input.split("|");
}

/** A readable preview: fragments interleaved with sample words per slot. */
export function renderTemplate(slotIdx: number[], fragments: string[]): string {
  let out = fragments[0] ?? "";
  for (let i = 0; i < slotIdx.length; i++) {
    const cat = CATEGORY_NAMES[slotIdx[i]];
    out += cat ? SAMPLE_WORD[cat] : "‹?›";
    out += fragments[i + 1] ?? "";
  }
  return out;
}

export interface TemplateValidation {
  ok: boolean;
  error?: string;
}

/** Enforce the on-chain invariants client-side before sending. */
export function validateTemplate(
  slotIdx: number[],
  fragments: string[],
  maxSlots: number,
): TemplateValidation {
  if (slotIdx.length === 0) return { ok: false, error: "at least one slot" };
  if (slotIdx.some((i) => i < 0)) return { ok: false, error: "categories must be NOUN/VERB/ADJ/ADV" };
  if (slotIdx.length > maxSlots) return { ok: false, error: `≤ ${maxSlots} slots` };
  if (fragments.length !== slotIdx.length + 1)
    return { ok: false, error: `fragments must be slots + 1 (${slotIdx.length + 1})` };
  return { ok: true };
}

export interface ParsedTemplate {
  slotIdx: number[];
  fragments: string[];
  slotNames: string[];
  preview: string;
  validation: TemplateValidation;
}

export interface BulkParseResult {
  templates: ParsedTemplate[];
  error?: string; // top-level parse error (bad JSON / wrong shape)
}

/**
 * Parse the bulk-import JSON. Accepts either a bare array `[{slots,fragments}]`
 * or the canonical `assets/templates.json` object `{templates:[…]}`. Each entry's
 * slots are category NAMES (Types.sol enum), fragments are verbatim strings.
 */
export function parseTemplatesJson(text: string, maxSlots: number): BulkParseResult {
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    return { templates: [], error: "Not valid JSON." };
  }
  const arr: unknown = Array.isArray(data)
    ? data
    : (data as { templates?: unknown })?.templates;
  if (!Array.isArray(arr)) {
    return { templates: [], error: "Expected an array of templates, or { templates: [...] }." };
  }

  const templates: ParsedTemplate[] = arr.map((raw) => {
    const r = raw as { slots?: unknown; fragments?: unknown };
    const slotNames = Array.isArray(r.slots) ? r.slots.map((s) => String(s)) : [];
    const fragments = Array.isArray(r.fragments) ? r.fragments.map((f) => String(f)) : [];
    const slotIdx = slotNames.map((s) => (CATEGORY_NAMES as readonly string[]).indexOf(s.trim().toUpperCase()));
    const validation =
      !Array.isArray(r.slots) || !Array.isArray(r.fragments)
        ? { ok: false, error: "entry needs slots[] and fragments[]" }
        : validateTemplate(slotIdx, fragments, maxSlots);
    return { slotIdx, fragments, slotNames, preview: renderTemplate(slotIdx, fragments), validation };
  });

  return { templates };
}
