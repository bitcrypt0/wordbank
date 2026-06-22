"use client";

import { type PublicClient } from "viem";
import { wordStakingAbi, wordTokenV2Abi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { useWallet } from "@/lib/wallet/WalletProvider";

export interface StakingData {
  /** Total WORD staked across everyone. */
  totalStakedWei: bigint;
  /** WORD this wallet has staked. */
  stakedWei: bigint;
  /** This wallet's claimable ETH rewards. */
  pendingWei: bigint;
  /** This wallet's free (un-staked) WORD balance. */
  walletWei: bigint;
  /** This wallet's WORD approval to the staking contract. */
  allowanceWei: bigint;
}

/** Live staking state. The per-wallet figures are 0 until a wallet connects. */
export function useStakingData() {
  const { account } = useWallet();

  return useChainData<StakingData>(
    async (client: PublicClient) => {
      if (!isDeployed("wordStaking") || !isDeployed("wordTokenV2")) throw new NotDeployedError();
      const staking = requireAddress("wordStaking");
      const token = requireAddress("wordTokenV2");

      const totalStakedWei = (await client.readContract({
        address: staking,
        abi: wordStakingAbi,
        functionName: "totalStaked",
      })) as bigint;

      if (!account) {
        return { totalStakedWei, stakedWei: 0n, pendingWei: 0n, walletWei: 0n, allowanceWei: 0n };
      }

      const [staked, pending, wallet, allowance] = (await client.multicall({
        allowFailure: false,
        contracts: [
          { address: staking, abi: wordStakingAbi, functionName: "stakedOf", args: [account] },
          { address: staking, abi: wordStakingAbi, functionName: "pendingRewards", args: [account] },
          { address: token, abi: wordTokenV2Abi, functionName: "balanceOf", args: [account] },
          { address: token, abi: wordTokenV2Abi, functionName: "allowance", args: [account, staking] },
        ],
      })) as [bigint, bigint, bigint, bigint];

      return { totalStakedWei, stakedWei: staked, pendingWei: pending, walletWei: wallet, allowanceWei: allowance };
    },
    [account],
    { refetchInterval: 20_000, preferWalletRpc: true },
  );
}
