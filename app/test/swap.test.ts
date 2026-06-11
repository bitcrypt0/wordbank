import { describe, it, expect } from "vitest";
import { minOut, maxIn, priceImpactBps } from "@/lib/swap/pool";
import { decodeError } from "@/lib/contracts/errors";

describe("swap slippage math", () => {
  it("minOut applies slippage downward", () => {
    expect(minOut(1000n, 50)).toBe(995n); // 0.5%
    expect(minOut(10_000n, 100)).toBe(9_900n); // 1%
    expect(minOut(1234n, 0)).toBe(1234n); // no slippage
  });

  it("maxIn pads slippage upward", () => {
    expect(maxIn(1000n, 50)).toBe(1005n);
    expect(maxIn(10_000n, 100)).toBe(10_100n);
    expect(maxIn(1234n, 0)).toBe(1234n);
  });

  it("minOut floors via integer division", () => {
    // 999 * 9950 / 10000 = 994.005 → 994
    expect(minOut(999n, 50)).toBe(994n);
  });
});

describe("price impact", () => {
  it("is zero for degenerate inputs", () => {
    expect(priceImpactBps(0n, 0n, 1n, 1n)).toBe(0);
    expect(priceImpactBps(100n, 90n, 0n, 0n)).toBe(0);
  });

  it("computes impact from marginal vs realized rate", () => {
    // realized 0.9 out/in, marginal 1.0 out/in → 10% = 1000 bps
    expect(priceImpactBps(100n, 90n, 1n, 1n)).toBe(1000);
  });

  it("is zero when realized ≥ marginal (no adverse impact)", () => {
    expect(priceImpactBps(100n, 110n, 1n, 1n)).toBe(0);
  });
});

describe("error decoding fallbacks", () => {
  it("returns a message for plain errors", () => {
    const d = decodeError(new Error("boom"));
    expect(d.rejected).toBe(false);
    expect(d.message).toContain("boom");
  });

  it("handles unknown shapes gracefully", () => {
    expect(decodeError(undefined).message).toBe("Something went wrong.");
    expect(decodeError({ message: "weird" }).message).toBe("weird");
  });
});
