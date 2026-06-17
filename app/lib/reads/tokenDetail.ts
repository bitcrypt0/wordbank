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
  /** Mirrors WordBank.offsetSet() — false until reveal; word/traits aren't set yet. */
  revealed: boolean;
  /**
   * Mirrors WordBank.registrySynced() (offsetSet && registryCursor ==
   * preRevealMinted). The precise "unbind is callable" signal — `_unbind`
   * reverts TokenNotInRegistry() until this is true (after reveal + buildRegistry).
   * More accurate than `revealed` alone: it also covers the brief post-reveal
   * window before sync-registry finishes.
   */
  unbindAvailable: boolean;
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

      const revealed = (await client.readContract({
        address: bank,
        abi: wordBankAbi,
        functionName: "offsetSet",
      })) as boolean;

      // wordDataOf reverts pre-reveal (_requireOffset), so request it with
      // allowFailure and only trust it once revealed. isAlive/bondedBalance are
      // always callable. ownerOf success proves the token is minted & not burned
      // (works pre-reveal — that's what backs the placeholder existence check).
      const [wdRes, aliveRes, bondedRes, ownerRes, syncedRes] = await client.multicall({
        allowFailure: true,
        contracts: [
          { address: bank, abi: wordBankAbi, functionName: "wordDataOf", args: [id] },
          { address: bank, abi: wordBankAbi, functionName: "isAlive", args: [id] },
          { address: bank, abi: wordBankAbi, functionName: "bondedBalance", args: [id] },
          { address: bank, abi: wordBankAbi, functionName: "ownerOf", args: [id] },
          { address: bank, abi: wordBankAbi, functionName: "registrySynced" },
        ],
      });

      const wd =
        revealed && wdRes.status === "success"
          ? (wdRes.result as unknown as RawWordData)
          : null;
      const alive = aliveRes.status === "success" ? (aliveRes.result as boolean) : false;
      const bonded = bondedRes.status === "success" ? (bondedRes.result as bigint) : 0n;
      const ownerFromCall =
        ownerRes.status === "success" ? String(ownerRes.result) : null;
      const unbindAvailable =
        syncedRes.status === "success" ? Boolean(syncedRes.result) : false;

      // A token "exists" if it has a word (post-reveal) OR ownerOf resolves
      // (pre-reveal minted & not burned). This keeps the № lookup honest pre-reveal.
      const exists = (wd ? wd.word.length > 0 : false) || ownerFromCall !== null;

      let owner: string | null = ownerFromCall;
      let pendingRewardsWei = 0n;
      let bounties: ClaimableShare[] = [];
      if (alive) {
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
        // Bounties are revealed-trait/word-keyed; only meaningful post-reveal.
        if (revealed && isDeployed("bountyEngine")) bounties = await claimableForToken(client, tokenId);
      }

      return {
        tokenId,
        exists,
        revealed,
        unbindAvailable,
        word: wd?.word ?? "",
        category: CATEGORY_BY_INDEX[wd?.category ?? 0] ?? "NOUN",
        material: wd?.material ?? 0,
        ink: wd?.ink ?? 0,
        background: wd?.background ?? 0,
        honors: wd?.honors ?? false,
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
