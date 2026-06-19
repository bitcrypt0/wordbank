"use client";

import { getAbiItem, type AbiEvent, type PublicClient } from "viem";
import {
  wordTokenAbi,
  wordBankAbi,
  burnEngineAbi,
  feeHookAbi,
  royaltySplitterAbi,
} from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { getLogsChunked } from "@/lib/events/logs";

export interface BurnData {
  totalSupplyWei: bigint;
  burnedWei: bigint;
  currentFloorWei: bigint;
  burnableExcessWei: bigint;
  aliveCount: number;
  pendingEthWei: bigint;
  pendingFeesWei: bigint;
  pendingDistributionWei: bigint;
  pendingAdminWei: bigint;
  // Live fee split (bps) — three-way while excess exists, two-way while paused.
  rewardsBps: number;
  bountyBps: number;
  burnBps: number;
  // Buyback bounds + gating.
  minBuybackWei: bigint;
  maxBuybackWei: bigint;
  tipBps: number;
  maxSlippageBps: number;
  lastBuybackBlock: bigint;
  blockNumber: bigint;
}

function need(...keys: Parameters<typeof isDeployed>[0][]) {
  for (const k of keys) if (!isDeployed(k)) throw new NotDeployedError();
}

export function useBurnData() {
  return useChainData<BurnData>(async (client: PublicClient) => {
    need("wordToken", "wordBank", "burnEngine", "feeHook", "royaltySplitter");
    const token = { address: requireAddress("wordToken"), abi: wordTokenAbi } as const;
    const bank = { address: requireAddress("wordBank"), abi: wordBankAbi } as const;
    const burn = { address: requireAddress("burnEngine"), abi: burnEngineAbi } as const;
    const hook = { address: requireAddress("feeHook"), abi: feeHookAbi } as const;
    const splitter = { address: requireAddress("royaltySplitter"), abi: royaltySplitterAbi } as const;

    const [r, head] = await Promise.all([
      client.multicall({
        allowFailure: false,
        contracts: [
          { ...token, functionName: "totalSupply" },
          { ...token, functionName: "burnedTotal" },
          { ...token, functionName: "currentBurnFloor" },
          { ...token, functionName: "burnableExcess" },
          { ...bank, functionName: "totalAlive" },
          { ...burn, functionName: "pendingEth" },
          { ...burn, functionName: "MIN_BUYBACK_ETH" },
          { ...burn, functionName: "MAX_BUYBACK_ETH" },
          { ...burn, functionName: "TIP_BPS" },
          { ...burn, functionName: "maxSlippageBps" },
          { ...burn, functionName: "lastBuybackBlock" },
          { ...hook, functionName: "rewardsBps" },
          { ...hook, functionName: "bountyBps" },
          { ...hook, functionName: "burnBps" },
          { ...hook, functionName: "pendingFees" },
          { ...splitter, functionName: "pendingDistribution" },
          { ...splitter, functionName: "pendingAdmin" },
        ],
      }),
      client.getBlockNumber(),
    ]);

    return {
      totalSupplyWei: r[0] as bigint,
      burnedWei: r[1] as bigint,
      currentFloorWei: r[2] as bigint,
      burnableExcessWei: r[3] as bigint,
      aliveCount: Number(r[4]),
      pendingEthWei: r[5] as bigint,
      minBuybackWei: r[6] as bigint,
      maxBuybackWei: r[7] as bigint,
      tipBps: Number(r[8]),
      maxSlippageBps: Number(r[9]),
      lastBuybackBlock: r[10] as bigint,
      rewardsBps: Number(r[11]),
      bountyBps: Number(r[12]),
      burnBps: Number(r[13]),
      pendingFeesWei: r[14] as bigint,
      pendingDistributionWei: r[15] as bigint,
      pendingAdminWei: r[16] as bigint,
      blockNumber: head,
    };
  });
}

/**
 * Build a small descending set of candidate spend amounts for executeBuyback.
 *
 * Every candidate is a valid on-chain spend: ≤ `pendingEth` (can't spend more
 * than is accrued) and ≥ `min(pendingEth, minBuyback)` (the contract reverts
 * SpendBelowMinimum below its anti-dust minimum-spend, except when the whole
 * balance is itself below that minimum, in which case spending the entire
 * balance is allowed). The top candidate is `min(pendingEth, maxBuyback)` and
 * the rest step down to the floor. Kept deliberately small (≤5) so sizing is a
 * handful of cheap `eth_call` simulations, not a binary search.
 */
export function buybackCandidates(
  pendingEth: bigint,
  minBuyback: bigint,
  maxBuyback: bigint,
): bigint[] {
  if (pendingEth <= 0n) return [];
  const top = pendingEth > maxBuyback ? maxBuyback : pendingEth; // largest sendable
  const floor = pendingEth < minBuyback ? pendingEth : minBuyback; // smallest valid spend
  if (top < floor) return [];
  if (top === floor) return [top];
  const span = top - floor;
  const out: bigint[] = [top];
  for (const num of [3n, 2n, 1n]) {
    // 75% / 50% / 25% of the span between floor and top
    const v = floor + (span * num) / 4n;
    if (v > floor && v < top) out.push(v);
  }
  out.push(floor);
  // dedupe, keep descending order (largest first)
  const seen = new Set<string>();
  return out
    .filter((v) => {
      const k = v.toString();
      if (seen.has(k)) return false;
      seen.add(k);
      return true;
    })
    .sort((a, b) => (a < b ? 1 : a > b ? -1 : 0));
}

export interface BuybackSizing {
  /** The largest candidate that simulated successfully, usable as the tx arg. */
  spendWei: bigint | null;
  /** True once sizing has run (so the UI can distinguish "checking" from "none fits"). */
  checked: boolean;
}

/**
 * Pre-simulate executeBuyback across the descending candidate set and resolve
 * the LARGEST amount that simulates successfully. This is what makes the button
 * self-sizing: instead of blindly sending the whole accrued balance (which can
 * exceed the pool's depth at the current slippage guard and revert), we send an
 * amount we've already validated will go through. If NO candidate simulates
 * (thin pool at the current slippage), `spendWei` is null → the button is
 * disabled with a friendly "pool too shallow" message instead of a raw revert.
 *
 * Gated on `enabled` so we don't burn RPC simulating when the button is already
 * disabled for another reason (no excess / same-block / below the UI floor).
 */
export function useBuybackSizing(
  pendingEth: bigint,
  minBuyback: bigint,
  maxBuyback: bigint,
  enabled: boolean,
) {
  return useChainData<BuybackSizing>(
    async (client: PublicClient) => {
      need("burnEngine");
      const engine = requireAddress("burnEngine");
      const candidates = buybackCandidates(pendingEth, minBuyback, maxBuyback);
      for (const amount of candidates) {
        try {
          await client.simulateContract({
            address: engine,
            abi: burnEngineAbi,
            functionName: "executeBuyback",
            args: [amount],
          });
          return { spendWei: amount, checked: true }; // largest passing — stop
        } catch {
          // This candidate reverts (e.g. SlippageExceeded on a thin pool) — try
          // the next, smaller one.
        }
      }
      return { spendWei: null, checked: true };
    },
    [pendingEth.toString(), minBuyback.toString(), maxBuyback.toString()],
    { enabled, refetchInterval: 30_000 },
  );
}

export interface RoyaltyTotals {
  burnWei: bigint;
  bountyWei: bigint;
  adminWei: bigint;
}

const DISTRIBUTED_EVENT = getAbiItem({
  abi: royaltySplitterAbi,
  name: "Distributed",
}) as AbiEvent;

/** Lifetime royalty totals — summed from Distributed events (no on-chain counter). */
export function useRoyaltyTotals() {
  return useChainData<RoyaltyTotals>(
    async (client: PublicClient) => {
      need("royaltySplitter");
      const logs = await getLogsChunked(client, {
        address: requireAddress("royaltySplitter"),
        event: DISTRIBUTED_EVENT,
      });
      let burnWei = 0n;
      let bountyWei = 0n;
      let adminWei = 0n;
      for (const log of logs) {
        const a = (log as unknown as { args: { toBurn: bigint; toBounty: bigint; toAdmin: bigint } }).args;
        burnWei += a.toBurn;
        bountyWei += a.toBounty;
        adminWei += a.toAdmin;
      }
      return { burnWei, bountyWei, adminWei };
    },
    [],
    { refetchInterval: 60_000 },
  );
}
