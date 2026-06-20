"use client";

import { type PublicClient } from "viem";
import {
  wordBankAbi,
  rewardsDistributorAbi,
  feeHookAbi,
  bountyEngineAbi,
} from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { getRecentSentencesByIndex } from "@/lib/reads/bounties";
import { enumerateOwnedTokens } from "@/lib/reads/ownerEnum";
import { useWallet } from "@/lib/wallet/WalletProvider";

/** Multicall batch size — keeps each aggregate eth_call well within RPC limits. */
const MULTICALL_BATCH = 200;

export interface RewardRow {
  tokenId: number;
  word: string;
  pendingWei: bigint;
  /** Backing WORD that releases to the wallet if this word is unbound (bondedBalance). */
  backingWei: bigint;
  /** Total unclaimed bounty share(s) this word would forfeit on unbind. */
  bountyShareWei: bigint;
  /** True when this word holds at least one unclaimed, still-claimable bounty share. */
  hasBounty: boolean;
}

export interface RewardsData {
  tokens: RewardRow[];
  pendingTotalWei: bigint;
  rewardsBps: number;
  /** balanceOf(account) — the number the wallet should own. */
  expectedCount: number;
  /** True when the RPC couldn't return everything (rate limits / gaps / read failures). */
  partial: boolean;
  /**
   * True when the bounty scan completed and the per-word `hasBounty` flags are
   * trustworthy. False if BountyEngine isn't deployed or the scan failed — the
   * unbind confirm then falls back to a strong generic forfeiture warning.
   */
  bountyScanComplete: boolean;
  /**
   * Mirrors WordBank.registrySynced() (offsetSet && registryCursor ==
   * preRevealMinted). Unbinding reverts `TokenNotInRegistry()` until this is
   * true — i.e. unbinding is only callable AFTER the reveal AND the category
   * registry has been built (post public sell-out). The Dashboard gates the
   * batch "Unbind selected" action on this; claiming is unaffected.
   */
  unbindAvailable: boolean;
}

/** Run `fn` over `items` in fixed-size batches, sequentially, and flatten. */
async function inBatches<I, O>(items: I[], size: number, fn: (batch: I[]) => Promise<O[]>): Promise<O[]> {
  const out: O[] = [];
  for (let i = 0; i < items.length; i += size) {
    out.push(...(await fn(items.slice(i, i + size))));
  }
  return out;
}

export function useRewardsData() {
  const { account } = useWallet();

  return useChainData<RewardsData>(
    async (client: PublicClient) => {
      if (!isDeployed("wordBank") || !isDeployed("rewardsDistributor") || !isDeployed("feeHook")) {
        throw new NotDeployedError();
      }
      const bank = requireAddress("wordBank");
      const rd = requireAddress("rewardsDistributor");
      const hook = requireAddress("feeHook");

      const rewardsBps = Number(
        await client.readContract({ address: hook, abi: feeHookAbi, functionName: "rewardsBps" }),
      );

      // Is unbinding callable at all? `_unbind` reverts TokenNotInRegistry()
      // until registrySynced() (offsetSet && registryCursor == preRevealMinted),
      // which only becomes true after the reveal + buildRegistry. Pre-reveal this
      // is false on mainnet, so the Dashboard must not let users fire a doomed
      // batch unbind. Cheap single eth_call; default false on read failure.
      const unbindAvailable = await client
        .readContract({ address: bank, abi: wordBankAbi, functionName: "registrySynced" })
        .then((v) => Boolean(v))
        .catch(() => false);

      if (!account) {
        return { tokens: [], pendingTotalWei: 0n, rewardsBps, expectedCount: 0, partial: false, bountyScanComplete: true, unbindAvailable };
      }

      // 1-2) Discover owned tokenIds WITHOUT eth_getLogs (restricted public RPCs
      //       cripple getLogs). WordBank ids are sequential 1..totalMinted(); we
      //       enumerate ownerOf in multicall batches and early-stop at balanceOf.
      //       ownerOf/balanceOf/totalMinted are plain eth_call/multicall, supported
      //       by every RPC. See lib/reads/ownerEnum.ts.
      const { owned, expectedCount, partial: enumPartial } = await enumerateOwnedTokens(client, bank, account);
      if (expectedCount === 0) {
        return { tokens: [], pendingTotalWei: 0n, rewardsBps, expectedCount: 0, partial: false, bountyScanComplete: true, unbindAvailable };
      }
      let partial = enumPartial;

      // 3) Per-token pending + word, in batches (homogeneous multicalls, allowFailure).
      const pendings = await inBatches(owned, MULTICALL_BATCH, (batch) =>
        client.multicall({
          allowFailure: true,
          contracts: batch.map((tokenId) => ({ address: rd, abi: rewardsDistributorAbi, functionName: "pendingRewards" as const, args: [tokenId] })),
        }),
      );
      const words = await inBatches(owned, MULTICALL_BATCH, (batch) =>
        client.multicall({
          allowFailure: true,
          contracts: batch.map((tokenId) => ({ address: bank, abi: wordBankAbi, functionName: "wordOf" as const, args: [tokenId] })),
        }),
      );
      // bondedBalance = the WORD that releases to the wallet on unbind — needed
      // so the batch-unbind confirm can total the backing about to be freed.
      const bondeds = await inBatches(owned, MULTICALL_BATCH, (batch) =>
        client.multicall({
          allowFailure: true,
          contracts: batch.map((tokenId) => ({ address: bank, abi: wordBankAbi, functionName: "bondedBalance" as const, args: [tokenId] })),
        }),
      );

      // Bounty scan: discover which owned words hold an unclaimed, still-claimable
      // bounty share — these would be FORFEITED on unbind, so the confirm must
      // name them. Recent sentences come from the LOG-FREE index path
      // (getRecentSentencesByIndex: nextEventId + eventInfo reads), NOT a wide
      // SentenceGenerated getLogs lookback — perf fix 2026-06-20: that lookback was
      // ~14 sequential getLogs windows blocking the whole Dashboard render. Then
      // per-token isClaimable checks restricted to tokens that appeared in a
      // sentence. If BountyEngine isn't deployed or the scan throws, fall back to a
      // generic warning (bountyScanComplete=false) rather than hide the risk.
      const bountyShareByToken = new Map<number, bigint>();
      let bountyScanComplete = true;
      if (isDeployed("bountyEngine")) {
        try {
          const bountyEngine = requireAddress("bountyEngine");
          const recent = await getRecentSentencesByIndex(client, 12);
          // Flatten EVERY (event, owned-token) claimable check into ONE multicall
          // rather than a sequential `claimableForToken` per token (perf fix
          // 2026-06-20: the per-token loop was N serial RPC round-trips on the
          // Dashboard — through the proxy that meant N slow hops; now one
          // aggregate call). A token can hold a claimable share in more than one
          // recent sentence, so we sum across all of its hits.
          const ownedSet = new Set(owned.map(Number));
          const pairs: { eventId: number; tokenId: number; shareWei: bigint }[] = [];
          for (const e of recent) {
            for (const id of e.tokenIds) {
              if (ownedSet.has(id)) pairs.push({ eventId: e.eventId, tokenId: id, shareWei: e.sharePerWordWei });
            }
          }
          if (pairs.length > 0) {
            const checks = await client.multicall({
              allowFailure: true,
              contracts: pairs.map((p) => ({
                address: bountyEngine,
                abi: bountyEngineAbi,
                functionName: "isClaimable" as const,
                args: [BigInt(p.eventId), BigInt(p.tokenId)],
              })),
            });
            pairs.forEach((p, i) => {
              if (checks[i]?.status === "success" && checks[i].result === true) {
                bountyShareByToken.set(p.tokenId, (bountyShareByToken.get(p.tokenId) ?? 0n) + p.shareWei);
              }
            });
          }
        } catch {
          bountyScanComplete = false;
        }
      } else {
        // No bounty game live yet → nothing can be forfeited; flags are trustworthy.
        bountyScanComplete = true;
      }

      const tokens: RewardRow[] = [];
      let pendingTotalWei = 0n;
      owned.forEach((tokenId, i) => {
        const p = pendings[i];
        const w = words[i];
        const b = bondeds[i];
        if (p?.status !== "success") {
          partial = true; // couldn't read this token's pending — still list it
        }
        const pendingWei = p?.status === "success" ? (p.result as bigint) : 0n;
        const word = w?.status === "success" ? (w.result as string) : `#${tokenId}`;
        const backingWei = b?.status === "success" ? (b.result as bigint) : 0n;
        const bountyShareWei = bountyShareByToken.get(Number(tokenId)) ?? 0n;
        pendingTotalWei += pendingWei;
        tokens.push({
          tokenId: Number(tokenId),
          word,
          pendingWei,
          backingWei,
          bountyShareWei,
          hasBounty: bountyShareWei > 0n,
        });
      });

      return { tokens, pendingTotalWei, rewardsBps, expectedCount, partial, bountyScanComplete, unbindAvailable };
    },
    [account],
    // preferWalletRpc: the Dashboard is connected-only, so read through the
    // wallet's own RPC directly (no /api/rpc proxy hop = no Vercel serverless
    // latency). Falls back to the public/proxy client if the wallet is on the
    // wrong network. This is the only page that opts in.
    { refetchInterval: 30_000, preferWalletRpc: true },
  );
}
