"use client";

import type { PublicClient } from "viem";
import { wordBankAbi, rewardsDistributorAbi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import type { Category } from "@/lib/mocks/types";
import { claimableForToken, type ClaimableShare } from "./bounties";

/** Category enum order (Types.sol — never reordered). */
const CATEGORY_BY_INDEX: Category[] = ["NOUN", "VERB", "ADJ", "ADV"];

export interface TokenDetail {
  tokenId: number;
  exists: boolean;
  word: string;
  category: Category;
  material: number;
  ink: number;
  background: number;
  honors: boolean;
  alive: boolean;
  owner: string | null;
  bondedBalanceWei: bigint;
  pendingRewardsWei: bigint;
  bounties: ClaimableShare[];
}

interface RawWordData {
  word: string;
  category: number;
  material: number;
  ink: number;
  background: number;
  honors: boolean;
}

export function useTokenDetail(tokenId: number) {
  return useChainData<TokenDetail>(
    async (client: PublicClient) => {
      if (!isDeployed("wordBank")) throw new NotDeployedError();
      const bank = requireAddress("wordBank");
      const id = BigInt(tokenId);

      const [wd, alive, bonded] = (await client.multicall({
        allowFailure: false,
        contracts: [
          { address: bank, abi: wordBankAbi, functionName: "wordDataOf", args: [id] },
          { address: bank, abi: wordBankAbi, functionName: "isAlive", args: [id] },
          { address: bank, abi: wordBankAbi, functionName: "bondedBalance", args: [id] },
        ],
      })) as [RawWordData, boolean, bigint];

      let owner: string | null = null;
      let pendingRewardsWei = 0n;
      let bounties: ClaimableShare[] = [];
      if (alive) {
        owner = (await client
          .readContract({ address: bank, abi: wordBankAbi, functionName: "ownerOf", args: [id] })
          .then((o) => String(o))
          .catch(() => null)) as string | null;
        if (isDeployed("rewardsDistributor")) {
          pendingRewardsWei = (await client
            .readContract({
              address: requireAddress("rewardsDistributor"),
              abi: rewardsDistributorAbi,
              functionName: "pendingRewards",
              args: [id],
            })
            .catch(() => 0n)) as bigint;
        }
        if (isDeployed("bountyEngine")) bounties = await claimableForToken(client, tokenId);
      }

      return {
        tokenId,
        exists: wd.word.length > 0,
        word: wd.word,
        category: CATEGORY_BY_INDEX[wd.category] ?? "NOUN",
        material: wd.material,
        ink: wd.ink,
        background: wd.background,
        honors: wd.honors,
        alive,
        owner,
        bondedBalanceWei: bonded,
        pendingRewardsWei,
        bounties,
      };
    },
    [tokenId],
  );
}
