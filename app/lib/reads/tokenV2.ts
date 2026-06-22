"use client";

import { type PublicClient } from "viem";
import { wordTokenV2Abi, wordStakingAbi, feeHookV2Abi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";

export interface TokenV2Data {
  /** Fixed total supply (1,000,000). */
  totalSupplyWei: bigint;
  /** WORD currently staked. */
  totalStakedWei: bigint;
  /** ETH fees skimmed by the hook, awaiting a permissionless flush. */
  pendingFeesWei: bigint;
  /** The fixed fee split (bps): NFT rewards / bounty / stakers. */
  rewardsBps: number;
  bountyBps: number;
  stakingBps: number;
  /** True once trading has been enabled on the hook. */
  tradingEnabled: boolean;
}

/** Live state for the (relaunch) WORD token page. */
export function useTokenV2Data() {
  return useChainData<TokenV2Data>(
    async (client: PublicClient) => {
      if (!isDeployed("wordTokenV2") || !isDeployed("feeHookV2") || !isDeployed("wordStaking")) {
        throw new NotDeployedError();
      }
      const token = requireAddress("wordTokenV2");
      const hook = requireAddress("feeHookV2");
      const staking = requireAddress("wordStaking");

      const r = (await client.multicall({
        allowFailure: false,
        contracts: [
          { address: token, abi: wordTokenV2Abi, functionName: "totalSupply" },
          { address: staking, abi: wordStakingAbi, functionName: "totalStaked" },
          { address: hook, abi: feeHookV2Abi, functionName: "pendingFees" },
          { address: hook, abi: feeHookV2Abi, functionName: "REWARDS_BPS" },
          { address: hook, abi: feeHookV2Abi, functionName: "BOUNTY_BPS" },
          { address: hook, abi: feeHookV2Abi, functionName: "STAKING_BPS" },
          { address: hook, abi: feeHookV2Abi, functionName: "tradingEnabledAt" },
        ],
      })) as [bigint, bigint, bigint, number, number, number, bigint];

      return {
        totalSupplyWei: r[0],
        totalStakedWei: r[1],
        pendingFeesWei: r[2],
        rewardsBps: Number(r[3]),
        bountyBps: Number(r[4]),
        stakingBps: Number(r[5]),
        tradingEnabled: r[6] > 0n,
      };
    },
    [],
    { refetchInterval: 20_000 },
  );
}
