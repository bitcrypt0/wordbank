"use client";

import type { PublicClient } from "viem";
import { wordBankAbi, rewardsDistributorAbi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { claimableForToken, type ClaimableShare } from "./bounties";
import { useWallet } from "@/lib/wallet/WalletProvider";

export interface UnbindToken {
  tokenId: number;
  exists: boolean;
  alive: boolean;
  word: string;
  owner: string | null;
  isOwner: boolean;
  pendingRewardsWei: bigint;
  bondedBalanceWei: bigint;
  bounties: ClaimableShare[];
}

export function useUnbindToken(tokenId: number) {
  const { account } = useWallet();

  return useChainData<UnbindToken>(
    async (client: PublicClient) => {
      if (!isDeployed("wordBank") || !isDeployed("rewardsDistributor")) {
        throw new NotDeployedError();
      }
      const bank = requireAddress("wordBank");
      const rd = requireAddress("rewardsDistributor");
      const id = BigInt(tokenId);

      const [alive, word, bonded] = (await client.multicall({
        allowFailure: false,
        contracts: [
          { address: bank, abi: wordBankAbi, functionName: "isAlive", args: [id] },
          { address: bank, abi: wordBankAbi, functionName: "wordOf", args: [id] },
          { address: bank, abi: wordBankAbi, functionName: "bondedBalance", args: [id] },
        ],
      })) as [boolean, string, bigint];

      // ownerOf reverts on burned ids; pendingRewards only meaningful while alive.
      let owner: string | null = null;
      let pendingRewardsWei = 0n;
      let bounties: ClaimableShare[] = [];
      if (alive) {
        owner = (await client
          .readContract({ address: bank, abi: wordBankAbi, functionName: "ownerOf", args: [id] })
          .then((o) => String(o))
          .catch(() => null)) as string | null;
        pendingRewardsWei = (await client
          .readContract({ address: rd, abi: rewardsDistributorAbi, functionName: "pendingRewards", args: [id] })
          .catch(() => 0n)) as bigint;
        if (isDeployed("bountyEngine")) {
          bounties = await claimableForToken(client, tokenId);
        }
      }

      const exists = word.length > 0 || alive;
      return {
        tokenId,
        exists,
        alive,
        word,
        owner,
        isOwner: !!account && !!owner && owner.toLowerCase() === account.toLowerCase(),
        pendingRewardsWei,
        bondedBalanceWei: bonded,
        bounties,
      };
    },
    [tokenId, account],
  );
}
