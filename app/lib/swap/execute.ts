import { maxUint160, type Hex } from "viem";
import { V4Planner, Actions } from "@uniswap/v4-sdk";
import { RoutePlanner, CommandType } from "@uniswap/universal-router-sdk";
import { UNISWAP, requireAddress } from "@/lib/contracts/addresses";
import { universalRouterAbi, permit2Abi } from "@/lib/contracts/uniswapAbis";
import { wordTokenAbi } from "@/lib/contracts/abis";
import type { WriteConfig } from "@/lib/hooks/useWrite";
import { buildPoolKey, currenciesFor, isZeroForOne, type Direction } from "./pool";

const DEADLINE_SECS = 1800n; // 30 minutes

function deadline(): bigint {
  return BigInt(Math.floor(Date.now() / 1000)) + DEADLINE_SECS;
}

/**
 * Build the UniversalRouter execute() call for an exact-input V4 swap.
 * Encodes one V4_SWAP command with SWAP_EXACT_IN_SINGLE → SETTLE_ALL → TAKE_ALL
 * via the canonical SDKs (no hand-rolled command bytes). Buys send native ETH
 * as msg.value; sells settle WORD via Permit2 (approved separately).
 */
export function buildSwapConfig(
  direction: Direction,
  amountInWei: bigint,
  minOutWei: bigint,
): WriteConfig {
  const pool = buildPoolKey();
  if (!pool) throw new Error("WORD/ETH pool is not configured yet.");
  const { input, output } = currenciesFor(pool, direction);

  const v4 = new V4Planner();
  v4.addAction(Actions.SWAP_EXACT_IN_SINGLE, [
    {
      poolKey: pool,
      zeroForOne: isZeroForOne(direction),
      amountIn: amountInWei.toString(),
      amountOutMinimum: minOutWei.toString(),
      hookData: "0x",
    },
  ]);
  v4.addAction(Actions.SETTLE_ALL, [input, amountInWei.toString()]);
  v4.addAction(Actions.TAKE_ALL, [output, minOutWei.toString()]);

  const route = new RoutePlanner();
  route.addCommand(CommandType.V4_SWAP, [v4.finalize()]);

  return {
    address: UNISWAP.universalRouter,
    abi: universalRouterAbi,
    functionName: "execute",
    args: [route.commands as Hex, route.inputs as Hex[], deadline()],
    // Native ETH only flows in on a buy; a sell pays WORD via Permit2.
    value: direction === "buy" ? amountInWei : 0n,
  };
}

/** One-time ERC-20 approval: let Permit2 move the caller's WORD. */
export function buildErc20ApproveConfig(): WriteConfig {
  return {
    address: requireAddress("wordToken"),
    abi: wordTokenAbi,
    functionName: "approve",
    args: [UNISWAP.permit2, maxUint160],
  };
}

/** Permit2 approval: let the UniversalRouter pull `amount` of WORD until `expiry`. */
export function buildPermit2ApproveConfig(amountWei: bigint): WriteConfig {
  const amount = amountWei > maxUint160 ? maxUint160 : amountWei;
  const expiration = Math.floor(Date.now() / 1000) + 30 * 24 * 3600; // 30 days
  return {
    address: UNISWAP.permit2,
    abi: permit2Abi,
    functionName: "approve",
    args: [requireAddress("wordToken"), UNISWAP.universalRouter, amount, expiration],
  };
}
