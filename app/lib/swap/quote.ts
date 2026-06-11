import type { PublicClient } from "viem";
import { UNISWAP } from "@/lib/contracts/addresses";
import { v4QuoterAbi } from "@/lib/contracts/uniswapAbis";
import { buildPoolKey, isZeroForOne, priceImpactBps, type Direction } from "./pool";

export interface SwapQuote {
  amountOutWei: bigint;
  priceImpactBps: number;
}

/** Small probe used to derive the marginal (near-spot) rate for price impact. */
function probeFor(amountIn: bigint): bigint {
  // ~0.1% of the trade, floored to something non-trivial but ≪ the trade.
  const tenth = amountIn / 1000n;
  return tenth > 0n ? tenth : amountIn;
}

async function quoteOnce(
  client: PublicClient,
  direction: Direction,
  amountIn: bigint,
): Promise<bigint> {
  const pool = buildPoolKey();
  if (!pool) throw new Error("pool not configured");
  const { result } = await client.simulateContract({
    address: UNISWAP.v4Quoter,
    abi: v4QuoterAbi,
    functionName: "quoteExactInputSingle",
    args: [
      {
        poolKey: pool,
        zeroForOne: isZeroForOne(direction),
        exactAmount: amountIn,
        hookData: "0x",
      },
    ],
  });
  return (result as readonly [bigint, bigint])[0];
}

/**
 * Exact-input quote off the canonical V4 Quoter. The quote already nets the
 * FeeHook's 1% skim and the pool curve. Price impact is derived by comparing
 * the realized rate to a small marginal probe — no StateView round-trip needed.
 */
export async function quoteExactIn(
  client: PublicClient,
  direction: Direction,
  amountIn: bigint,
): Promise<SwapQuote> {
  if (amountIn <= 0n) return { amountOutWei: 0n, priceImpactBps: 0 };

  const amountOutWei = await quoteOnce(client, direction, amountIn);

  let impact = 0;
  const probe = probeFor(amountIn);
  if (probe > 0n && probe < amountIn) {
    try {
      const marginalOut = await quoteOnce(client, direction, probe);
      impact = priceImpactBps(amountIn, amountOutWei, probe, marginalOut);
    } catch {
      /* marginal probe failed — leave impact at 0 rather than block the quote */
    }
  }
  return { amountOutWei, priceImpactBps: impact };
}
