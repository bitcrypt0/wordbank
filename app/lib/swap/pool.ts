/**
 * WORD/ETH V4 pool identity + pure swap math. The pool is the canonical
 * Uniswap V4 pool our FeeHook sits on: currency0 = ETH (native, address(0)),
 * currency1 = WORD, fee + tickSpacing from the deploy config, hooks = FeeHook.
 * (ETH is address(0), always < any token, so it is always currency0.)
 *
 * The math here is pure (no I/O) so it is unit-tested directly.
 */
import { OUR_ADDRESSES, POOL_PARAMS, type Address } from "@/lib/contracts/addresses";

export const ETH_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

export type Direction = "buy" | "sell"; // buy = ETH→WORD, sell = WORD→ETH

export interface PoolKey {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

/** Build the WORD/ETH PoolKey, or null if WORD/FeeHook aren't deployed yet. */
export function buildPoolKey(): PoolKey | null {
  const word = OUR_ADDRESSES.wordToken;
  const hook = OUR_ADDRESSES.feeHook;
  if (!word || !hook) return null;
  return {
    currency0: ETH_ADDRESS,
    currency1: word,
    fee: POOL_PARAMS.fee,
    tickSpacing: POOL_PARAMS.tickSpacing,
    hooks: hook,
  };
}

/** buy spends currency0 (ETH) for currency1 (WORD) → zeroForOne = true. */
export function isZeroForOne(direction: Direction): boolean {
  return direction === "buy";
}

/** Input / output currency addresses for a direction. */
export function currenciesFor(pool: PoolKey, direction: Direction): { input: Address; output: Address } {
  return direction === "buy"
    ? { input: pool.currency0, output: pool.currency1 }
    : { input: pool.currency1, output: pool.currency0 };
}

const BPS = 10_000n;

/** Slippage-protected minimum output for an exact-input swap. */
export function minOut(quotedOut: bigint, slippageBps: number): bigint {
  return (quotedOut * (BPS - BigInt(slippageBps))) / BPS;
}

/** Slippage-padded maximum input for an exact-output swap. */
export function maxIn(quotedIn: bigint, slippageBps: number): bigint {
  return (quotedIn * (BPS + BigInt(slippageBps))) / BPS;
}

/**
 * Price impact in bps, comparing the marginal (tiny-trade) rate to the
 * realized average rate of the quote. Both rates expressed as out-per-in.
 * Returns 0 when inputs are degenerate.
 */
export function priceImpactBps(
  amountIn: bigint,
  amountOut: bigint,
  marginalIn: bigint,
  marginalOut: bigint,
): number {
  if (amountIn === 0n || marginalIn === 0n || marginalOut === 0n) return 0;
  // realized = out/in ; marginal = mOut/mIn ; impact = 1 - realized/marginal
  // Scale to bps with integer math: impact = (marginal - realized)/marginal.
  const realized = (amountOut * 1_000_000n) / amountIn;
  const marginal = (marginalOut * 1_000_000n) / marginalIn;
  if (marginal === 0n || realized >= marginal) return 0;
  return Number(((marginal - realized) * BPS) / marginal);
}
