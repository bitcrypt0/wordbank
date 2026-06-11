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
