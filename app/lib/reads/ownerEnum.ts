"use client";

import type { PublicClient } from "viem";
import { wordBankAbi } from "@/lib/contracts/abis";

/**
 * Owned-token discovery — log-free, parallel `ownerOf` scan.
 *
 * The contract is NOT ERC721Enumerable: there is no `tokenOfOwnerByIndex` /
 * `tokensOfOwner`, only `balanceOf` + `ownerOf`. And event-log discovery is out:
 * EVERY keyless public RPC archive-gates `eth_getLogs` (only a keyed Alchemy/
 * Infura endpoint serves historical logs), and a log scan's cost grows with chain
 * age. So we scan the id space directly.
 *
 * WHY PARALLEL (perf fix 2026-06-20): the supply is FIXED at 10,000 and fully
 * minted, so the id space is a constant 1..totalMinted(). The previous version
 * scanned it in 400-id `ownerOf` multicall batches SEQUENTIALLY with an early-stop
 * at balanceOf — fast for low-id holders, but a high-id holder (ids ~9,800) forced
 * ~25 serial round-trips before their tokens were even reached. We now fire the
 * batches in bounded-concurrency WAVES: each wave's round-trip time is paid once,
 * and a wave-level early-stop still exits as soon as the full balance is found.
 * Worst case collapses from ~25 serial calls to ~4 waves; a low-id holder still
 * finishes in the first wave. Constant work regardless of where the ids sit, on
 * ANY RPC (ownerOf/multicall are plain eth_call, supported everywhere).
 *
 * SCALE: ceiling is `totalMinted()` (mint high-water mark, never `totalSupply()`
 * which falls on unbind and would skip ids above a burned token). 10,000 / 400 =
 * 25 batches → at most ceil(25 / SCAN_CONCURRENCY) waves.
 */

/** Token ids per `ownerOf` multicall — keeps each aggregate eth_call small. */
export const OWNER_ENUM_BATCH = 400;
/** Multicall batches kept in flight per wave (bounded so a wave can't 429 an RPC). */
export const SCAN_CONCURRENCY = 8;

export interface OwnedEnumResult {
  /** Ascending tokenIds currently owned by the account. */
  owned: bigint[];
  /** balanceOf(account) — how many the wallet should own. */
  expectedCount: number;
  /** True when the sweep couldn't confirm every expected token (read failures). */
  partial: boolean;
}

/**
 * Enumerate the tokenIds currently owned by `account`. Returns ascending ids, the
 * expected count (balanceOf), and a `partial` flag set if a batch read failed
 * before all expected ids were found.
 */
export async function enumerateOwnedTokens(
  client: PublicClient,
  bank: `0x${string}`,
  account: `0x${string}`,
): Promise<OwnedEnumResult> {
  const want = account.toLowerCase();

  const expectedCount = Number(
    await client.readContract({
      address: bank,
      abi: wordBankAbi,
      functionName: "balanceOf",
      args: [account],
    }),
  );
  if (expectedCount === 0) {
    return { owned: [], expectedCount: 0, partial: false };
  }

  const totalMinted = Number(
    await client.readContract({
      address: bank,
      abi: wordBankAbi,
      functionName: "totalMinted",
    }),
  );

  // Precompute the id batches (1..totalMinted in OWNER_ENUM_BATCH-sized chunks).
  const batches: bigint[][] = [];
  for (let start = 1; start <= totalMinted; start += OWNER_ENUM_BATCH) {
    const ids: bigint[] = [];
    for (let id = start; id < start + OWNER_ENUM_BATCH && id <= totalMinted; id++) {
      ids.push(BigInt(id));
    }
    batches.push(ids);
  }

  // Resolve one batch → the ids in it currently owned by `account`. A revert is
  // expected for burned/unminted ids (allowFailure) and is NOT a partial read; a
  // thrown multicall (transport failure) is flagged so the caller can show it.
  const resolveBatch = async (ids: bigint[]): Promise<{ hits: bigint[]; failed: boolean }> => {
    try {
      const owners = await client.multicall({
        allowFailure: true,
        contracts: ids.map((tokenId) => ({
          address: bank,
          abi: wordBankAbi,
          functionName: "ownerOf" as const,
          args: [tokenId],
        })),
      });
      const hits = ids.filter(
        (_, i) =>
          owners[i]?.status === "success" &&
          String(owners[i].result).toLowerCase() === want,
      );
      return { hits, failed: false };
    } catch {
      return { hits: [], failed: true };
    }
  };

  const owned: bigint[] = [];
  let partial = false;

  // Fire batches in bounded-concurrency waves; stop launching waves once the full
  // balance is accounted for (a low-id holder exits after the first wave).
  for (let i = 0; i < batches.length && owned.length < expectedCount; i += SCAN_CONCURRENCY) {
    const wave = batches.slice(i, i + SCAN_CONCURRENCY);
    const results = await Promise.all(wave.map(resolveBatch));
    for (const r of results) {
      owned.push(...r.hits);
      if (r.failed) partial = true;
    }
  }

  // If we walked the whole minted range and still didn't find balanceOf tokens, a
  // multicall dropped some — surface it as partial rather than hide it.
  if (owned.length < expectedCount) partial = true;

  owned.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  return { owned, expectedCount, partial };
}
