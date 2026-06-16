"use client";

import type { PublicClient } from "viem";
import { wordBankAbi } from "@/lib/contracts/abis";

/**
 * Log-free owned-token discovery.
 *
 * WHY (bug fix 2026-06-16): owned NFTs were discovered by scanning `Transfer`
 * event logs (`eth_getLogs`). Free/keyless RPCs cripple `eth_getLogs` — drpc
 * rejects ranges >10k blocks, 1rpc limits to ~50 blocks, cloudflare is limited —
 * so depending on which RPC the read client landed on, discovery returned nothing
 * and the Dashboard/owned grids were empty even though the NFTs exist on-chain.
 *
 * THE FIX: WordBank tokenIds are sequential `1..totalMinted()` (mint-only
 * counter; never reused — see WordBank.sol). We enumerate the id space with
 * `ownerOf` in `multicall` batches (allowFailure — burned/unminted ids revert)
 * and keep the ids whose owner == the account. `ownerOf`/`balanceOf`/
 * `totalMinted` are plain `eth_call`/`multicall`, supported by EVERY RPC — NO
 * `eth_getLogs` — so this works on the wallet RPC and the public fallback alike.
 *
 * EARLY-STOP: a holder owns exactly `balanceOf(account)` alive tokens, so we
 * stop scanning as soon as that many matches are found — at today's scale the
 * scan usually ends in the first batch or two.
 *
 * SCALE: ceiling is `totalMinted()` (the high-water mark, NOT `totalSupply()`
 * which falls on unbind and would skip ids above a burned token). At the 10,000
 * cap that's ~20–50 batches of 250–500 — well within RPC limits, and early-stop
 * usually exits far sooner.
 */

/** Multicall batch size for the ownerOf sweep — keeps each aggregate eth_call small. */
export const OWNER_ENUM_BATCH = 400;

export interface OwnedEnumResult {
  /** Ascending tokenIds currently owned by the account. */
  owned: bigint[];
  /** balanceOf(account) — how many the wallet should own. */
  expectedCount: number;
  /** True when the sweep couldn't confirm every expected token (read failures). */
  partial: boolean;
}

/**
 * Enumerate the tokenIds currently owned by `account`, with zero dependence on
 * `eth_getLogs`. Returns ascending ids, the expected count (balanceOf), and a
 * `partial` flag set if a batch read failed before all expected ids were found.
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

  // High-water mark of minted ids. Ids run 1..totalMinted(); unbound ids stay
  // burned (ownerOf reverts) and are simply skipped by allowFailure.
  const totalMinted = Number(
    await client.readContract({
      address: bank,
      abi: wordBankAbi,
      functionName: "totalMinted",
    }),
  );

  const owned: bigint[] = [];
  let partial = false;

  for (let start = 1; start <= totalMinted && owned.length < expectedCount; start += OWNER_ENUM_BATCH) {
    const ids: bigint[] = [];
    for (let id = start; id < start + OWNER_ENUM_BATCH && id <= totalMinted; id++) {
      ids.push(BigInt(id));
    }
    const owners = await client.multicall({
      allowFailure: true,
      contracts: ids.map((tokenId) => ({
        address: bank,
        abi: wordBankAbi,
        functionName: "ownerOf" as const,
        args: [tokenId],
      })),
    });
    ids.forEach((tokenId, i) => {
      const r = owners[i];
      // A revert here is expected for burned/unminted ids (allowFailure) — NOT a
      // partial read. We only match successes whose owner == the account.
      if (r?.status === "success" && String(r.result).toLowerCase() === want) {
        owned.push(tokenId);
      }
    });
    // Early-stop handled by the loop condition once owned.length >= expectedCount.
  }

  // If we walked the whole minted range and still didn't find balanceOf tokens,
  // a multicall must have dropped some — surface it as partial rather than hide it.
  if (owned.length < expectedCount) partial = true;

  owned.sort((a, b) => (a < b ? -1 : 1));
  return { owned, expectedCount, partial };
}
