import { describe, it, expect } from "vitest";
import {
  parseFragments,
  parseSlots,
  renderTemplate,
  validateTemplate,
  parseTemplatesJson,
} from "@/lib/admin/templates";

describe("fragment parsing keeps spaces verbatim", () => {
  it("does NOT trim leading/trailing spaces", () => {
    expect(parseFragments("The | quietly | .")).toEqual(["The ", " quietly ", " ."]);
    expect(parseFragments("The | | will |.")).toEqual(["The ", " ", " will ", "."]);
  });

  it("round-trips with correct spacing (the bug being fixed)", () => {
    // slots ADJ, NOUN, VERB → "The luminous ember will wander."
    const slots = parseSlots("ADJ, NOUN, VERB");
    const frags = parseFragments("The | | will |.");
    expect(renderTemplate(slots, frags)).toBe("The luminous ember will wander.");
    // The old trimming parser would have produced "Theluminousemberwillwander." — no gaps.
    expect(renderTemplate(slots, frags)).not.toContain("luminousember");
  });

  it("renders a single-slot template with its surrounding spaces", () => {
    expect(renderTemplate(parseSlots("NOUN"), parseFragments("A bright | shines."))).toBe(
      "A bright ember shines.",
    );
  });
});

describe("validation", () => {
  it("requires fragments = slots + 1", () => {
    expect(validateTemplate(parseSlots("NOUN, VERB"), parseFragments("a|b"), 7).ok).toBe(false);
    expect(validateTemplate(parseSlots("NOUN, VERB"), parseFragments("a|b|c"), 7).ok).toBe(true);
  });
  it("rejects unknown categories and over-cap slot counts", () => {
    expect(validateTemplate(parseSlots("NOUN, GERUND"), parseFragments("a|b|c"), 7).ok).toBe(false);
    expect(validateTemplate(parseSlots("NOUN,NOUN,NOUN"), parseFragments("a|b|c|d"), 2).ok).toBe(false);
  });
});

describe("bulk JSON import", () => {
  const canonical = JSON.stringify({
    templates: [
      { id: 0, slots: ["ADJ", "NOUN", "VERB"], fragments: ["The ", " ", " will ", "."] },
      { id: 1, slots: ["NOUN", "VERB", "ADV"], fragments: ["Each ", " must ", " ", "."] },
    ],
  });

  it("accepts the canonical {templates:[…]} shape", () => {
    const r = parseTemplatesJson(canonical, 7);
    expect(r.error).toBeUndefined();
    expect(r.templates).toHaveLength(2);
    expect(r.templates.every((t) => t.validation.ok)).toBe(true);
    expect(r.templates[0].slotIdx).toEqual([2, 0, 1]); // ADJ,NOUN,VERB
    expect(r.templates[0].preview).toBe("The luminous ember will wander.");
  });

  it("accepts a bare array too", () => {
    const r = parseTemplatesJson('[{"slots":["NOUN"],"fragments":["A "," shines."]}]', 7);
    expect(r.error).toBeUndefined();
    expect(r.templates[0].validation.ok).toBe(true);
  });

  it("reports bad JSON / wrong shape and flags bad entries", () => {
    expect(parseTemplatesJson("{ not json", 7).error).toBeTruthy();
    expect(parseTemplatesJson('{"x":1}', 7).error).toBeTruthy();
    const r = parseTemplatesJson('[{"slots":["NOUN","VERB"],"fragments":["only","two"]}]', 7);
    expect(r.error).toBeUndefined();
    expect(r.templates[0].validation.ok).toBe(false);
  });
});
