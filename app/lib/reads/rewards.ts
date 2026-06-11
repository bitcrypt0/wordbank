"use client";

import { getAbiItem, type AbiEvent, type PublicClient } from "viem";
import {
  wordBankAbi,
  rewardsDistributorAbi,
  feeHookAbi,
} from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { getLogsChunked } from "@/lib/events/logs";
import { claimableForToken, getRecentSentences } from "@/lib/reads/bounties";
import { useWallet } from "@/lib/wallet/WalletProvider";

const TRANSFER_EVENT = getAbiItem({ abi: wordBankAbi, name: "Transfer" }) as AbiEvent;
const CLAIMED_EVENT = getAbiItem({ abi: rewardsDistributorAbi, name: "Claimed" }) as AbiEvent;

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
  lifetimeClaimedWei: bigint;
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

      if (!account) {
        return { tokens: [], pendingTotalWei: 0n, lifetimeClaimedWei: 0n, rewardsBps, expectedCount: 0, partial: false, bountyScanComplete: true };
      }

      const expectedCount = Number(
        await client.readContract({ address: bank, abi: wordBankAbi, functionName: "balanceOf", args: [account] }),
      );
      if (expectedCount === 0) {
        return { tokens: [], pendingTotalWei: 0n, lifetimeClaimedWei: 0n, rewardsBps, expectedCount: 0, partial: false, bountyScanComplete: true };
      }

      let partial = false;

      // 1) Discover received tokenIds (resilient, full history, early-stop once we
      //    have at least `expectedCount` distinct ids — a holder must have received
      //    each token it now owns).
      const seen = new Set<bigint>();
      const xfer = await getLogsChunked(client, {
        address: bank,
        event: TRANSFER_EVENT,
        args: { to: account },
        // Default lookback (bounded) + early-stop once the full balance is found;
        // a recent deploy's mints are well within it. If the floor is reached
        // before finding them all, owned<expected below flags partial.
        stopWhen: (logs) => {
          for (const l of logs) seen.add((l as unknown as { args: { tokenId: bigint } }).args.tokenId);
          return seen.size >= expectedCount;
        },
        onGap: () => {
          partial = true;
        },
      });
      const candidates = [
        ...new Set(xfer.map((l) => (l as unknown as { args: { tokenId: bigint } }).args.tokenId)),
      ];

      // 2) Confirm current ownership in batches (allowFailure — burned ids revert).
      const ownerChecks = await inBatches(candidates, MULTICALL_BATCH, (batch) =>
        client.multicall({
          allowFailure: true,
          contracts: batch.map((tokenId) => ({ address: bank, abi: wordBankAbi, functionName: "ownerOf" as const, args: [tokenId] })),
        }),
      );
      const owned: bigint[] = [];
      candidates.forEach((tokenId, i) => {
        const r = ownerChecks[i];
        if (r?.status === "success" && String(r.result).toLowerCase() === account.toLowerCase()) owned.push(tokenId);
      });
      owned.sort((a, b) => (a < b ? -1 : 1));
      if (owned.length < expectedCount) partial = true; // discovery couldn't find all

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
      // name them. One log scan of recent sentences (shared), then per-token
      // isClaimable checks restricted to tokens that appeared in a sentence.
      // If BountyEngine isn't deployed or the scan throws, fall back to a generic
      // warning (bountyScanComplete=false) rather than hide the risk.
      const bountyShareByToken = new Map<number, bigint>();
      let bountyScanComplete = true;
      if (isDeployed("bountyEngine")) {
        try {
          const recent = await getRecentSentences(client);
          // Only tokens that appeared in a recent sentence can be claimable.
          const inASentence = new Set<number>();
          for (const e of recent) for (const id of e.tokenIds) inASentence.add(id);
          const toCheck = owned.map(Number).filter((id) => inASentence.has(id));
          for (const id of toCheck) {
            const shares = await claimableForToken(client, id, recent);
            const total = shares.reduce((acc, s) => acc + s.sharePerWordWei, 0n);
            if (total > 0n) bountyShareByToken.set(id, total);
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

      // 4) Lifetime claimed (resilient; partial-tolerant).
      let lifetimeClaimedWei = 0n;
      const claimedLogs = await getLogsChunked(client, {
        address: rd,
        event: CLAIMED_EVENT,
        args: { to: account },
        onGap: () => {
          partial = true;
        },
      });
      for (const log of claimedLogs) {
        lifetimeClaimedWei += (log as unknown as { args: { amount: bigint } }).args.amount;
      }

      return { tokens, pendingTotalWei, lifetimeClaimedWei, rewardsBps, expectedCount, partial, bountyScanComplete };
    },
    [account],
    { refetchInterval: 30_000 },
  );
}
