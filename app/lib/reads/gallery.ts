"use client";

import type { PublicClient } from "viem";
import { wordBankAbi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import type { Category } from "@/lib/mocks/types";

const CATS: Category[] = ["NOUN", "VERB", "ADJ", "ADV"];
const CAT_INDEX: Record<Category, number> = { NOUN: 0, VERB: 1, ADJ: 2, ADV: 3 };

/** Multicall batch for the pre-reveal sequential enumeration (ownerOf sweep). */
const PRE_REVEAL_BATCH = 400;

/**
 * A gallery card.
 *
 * REVEAL-AWARE (bug fix 2026-06-16): before the provenance reveal (`offsetSet()
 * == false`), word/trait/category data does not exist yet — `wordDataOf` reverts
 * (`_requireOffset`) and the per-category alive registry isn't built. A pre-reveal
 * item carries ONLY `tokenId` + `revealed: false`; every minted token still has a
 * renderable on-chain placeholder (`tokenURI` → `unrevealedTokenURI`). Post-reveal
 * items carry the full record. The card component branches on `revealed`.
 */
export interface GalleryItem {
  tokenId: number;
  revealed: boolean;
  /** Present only when `revealed` (post-reveal). */
  word?: string;
  category?: Category;
  material?: number;
  ink?: number;
  background?: number;
  honors?: boolean;
}

export interface GalleryPage {
  items: GalleryItem[];
  total: number;
  loadedAll: boolean;
  /** Mirrors WordBank.offsetSet() — false until the sellout/reveal. */
  revealed: boolean;
}

interface RawWordData {
  word: string;
  category: number;
  material: number;
  ink: number;
  background: number;
  honors: boolean;
}

/** Read WordBank.offsetSet() — true once the provenance offset is committed (reveal). */
async function readRevealed(client: PublicClient, bank: `0x${string}`): Promise<boolean> {
  return (await client.readContract({
    address: bank,
    abi: wordBankAbi,
    functionName: "offsetSet",
  })) as boolean;
}

function toItem(id: number, d: RawWordData): GalleryItem {
  return {
    tokenId: id,
    revealed: true,
    word: d.word,
    category: CATS[d.category] ?? "NOUN",
    material: d.material,
    ink: d.ink,
    background: d.background,
    honors: d.honors,
  };
}

/** A pre-reveal placeholder card — id only; art comes from tokenURI (unrevealed). */
function placeholderItem(id: number): GalleryItem {
  return { tokenId: id, revealed: false };
}

/**
 * A page of the collection — reveal-aware.
 *
 * POST-REVEAL: WordBank isn't enumerable, but it exposes per-category alive arrays
 * (aliveCount/aliveAt, built by buildRegistry after reveal). We slice across the
 * selected scope, resolve tokenIds, then batch wordDataOf for trait/word data.
 *
 * PRE-REVEAL: the alive registry is empty and wordDataOf reverts, so we instead
 * enumerate minted ids sequentially over [1, totalMinted()] via ownerOf (burned/
 * unminted ids revert under allowFailure and are skipped) and return placeholder
 * cards. Scope/category can't be honored without revealed data, so pre-reveal
 * ignores scope and lists every minted id paginated by `limit`.
 */
export function useGalleryPage(scope: Category | "ALL", limit: number, enabled = true) {
  return useChainData<GalleryPage>(
    async (client: PublicClient) => {
      if (!isDeployed("wordBank")) throw new NotDeployedError();
      const bank = requireAddress("wordBank");

      const revealed = await readRevealed(client, bank);

      // ── PRE-REVEAL: sequential id enumeration → placeholder cards ──
      if (!revealed) {
        const totalMinted = Number(
          await client.readContract({ address: bank, abi: wordBankAbi, functionName: "totalMinted" }),
        );
        if (totalMinted === 0) return { items: [], total: 0, loadedAll: true, revealed: false };

        const items: GalleryItem[] = [];
        // Walk ids 1..totalMinted in multicall batches, keeping the first `limit`
        // ids that still resolve (ownerOf succeeds = minted & not burned).
        for (let start = 1; start <= totalMinted && items.length < limit; start += PRE_REVEAL_BATCH) {
          const ids: number[] = [];
          for (let id = start; id < start + PRE_REVEAL_BATCH && id <= totalMinted; id++) ids.push(id);
          const owners = await client.multicall({
            allowFailure: true,
            contracts: ids.map((id) => ({
              address: bank,
              abi: wordBankAbi,
              functionName: "ownerOf" as const,
              args: [BigInt(id)],
            })),
          });
          for (let j = 0; j < ids.length && items.length < limit; j++) {
            if (owners[j]?.status === "success") items.push(placeholderItem(ids[j]));
          }
        }
        // `total` is the high-water mark; some ids may be burned, so the live
        // count can be lower, but totalMinted bounds the "load more" affordance.
        return {
          items,
          total: totalMinted,
          loadedAll: items.length >= totalMinted,
          revealed: false,
        };
      }

      // ── POST-REVEAL: per-category alive registry + wordDataOf (unchanged) ──
      const scopes: Category[] = scope === "ALL" ? CATS : [scope];
      const counts = (await client.multicall({
        allowFailure: false,
        contracts: scopes.map((c) => ({
          address: bank,
          abi: wordBankAbi,
          functionName: "aliveCount" as const,
          args: [CAT_INDEX[c]],
        })),
      })) as bigint[];

      const total = counts.reduce((a, c) => a + Number(c), 0);

      // Build (category, index) pairs up to `limit`, walking scopes in order.
      const picks: { cat: Category; index: number }[] = [];
      for (let s = 0; s < scopes.length && picks.length < limit; s++) {
        const n = Number(counts[s]);
        for (let i = 0; i < n && picks.length < limit; i++) {
          picks.push({ cat: scopes[s], index: i });
        }
      }
      if (picks.length === 0) return { items: [], total, loadedAll: true, revealed: true };

      const ids = (await client.multicall({
        allowFailure: false,
        contracts: picks.map((p) => ({
          address: bank,
          abi: wordBankAbi,
          functionName: "aliveAt" as const,
          args: [CAT_INDEX[p.cat], BigInt(p.index)],
        })),
      })) as bigint[];

      const data = (await client.multicall({
        allowFailure: false,
        contracts: ids.map((id) => ({
          address: bank,
          abi: wordBankAbi,
          functionName: "wordDataOf" as const,
          args: [id],
        })),
      })) as RawWordData[];

      const items: GalleryItem[] = ids.map((id, i) => toItem(Number(id), data[i]));

      return { items, total, loadedAll: items.length >= total, revealed: true };
    },
    [scope, limit],
    { refetchInterval: 0, enabled },
  );
}

/**
 * Look up a single token by id (powers the gallery's numeric search) — reveal-aware.
 *
 * POST-REVEAL: the rich wordDataOf lookup; null when the id isn't a minted word.
 * PRE-REVEAL: wordDataOf reverts, so existence is confirmed by ownerOf(id) success
 * (minted & not burned, no offset needed) and a placeholder item is returned —
 * never null for a genuinely minted id (the owner's "due diligence" complaint).
 * Disabled (no fetch) unless `idStr` is a non-negative integer.
 */
export function useGalleryById(idStr: string) {
  const trimmed = idStr.trim();
  const id = /^\d+$/.test(trimmed) ? Number(trimmed) : -1;
  return useChainData<GalleryItem | null>(
    async (client: PublicClient) => {
      if (!isDeployed("wordBank")) throw new NotDeployedError();
      if (id < 0) return null;
      const bank = requireAddress("wordBank");

      const revealed = await readRevealed(client, bank);

      if (!revealed) {
        // No wordDataOf pre-reveal (it reverts). ownerOf success proves the id is
        // minted & not burned without needing the offset.
        const owner = await client
          .readContract({ address: bank, abi: wordBankAbi, functionName: "ownerOf", args: [BigInt(id)] })
          .catch(() => null);
        if (!owner) return null; // unminted / burned
        return placeholderItem(id);
      }

      const wd = await client
        .readContract({ address: bank, abi: wordBankAbi, functionName: "wordDataOf", args: [BigInt(id)] })
        .catch(() => null);
      const d = wd as RawWordData | null;
      if (!d || !d.word) return null; // unminted / unrevealed slot
      return toItem(id, d);
    },
    [id],
    { refetchInterval: 0, enabled: id >= 0 },
  );
}

/**
 * Find every honors (1/1) word across the whole collection — POST-REVEAL ONLY.
 * Honors is a revealed trait (wordDataOf), so this is inherently meaningless and
 * would revert pre-reveal; the page gates it behind the reveal. Scans wordDataOf
 * in batches over the minted range; disabled until requested.
 */
export function useHonorsScan(enabled: boolean) {
  return useChainData<GalleryItem[]>(
    async (client: PublicClient) => {
      if (!isDeployed("wordBank")) throw new NotDeployedError();
      const bank = requireAddress("wordBank");
      const total = Number(
        await client.readContract({ address: bank, abi: wordBankAbi, functionName: "totalMinted" }),
      );
      const items: GalleryItem[] = [];
      const BATCH = 200;
      for (let start = 1; start <= total; start += BATCH) {
        const ids: number[] = [];
        for (let i = start; i < start + BATCH && i <= total; i++) ids.push(i);
        const res = await client.multicall({
          allowFailure: true,
          contracts: ids.map((id) => ({
            address: bank,
            abi: wordBankAbi,
            functionName: "wordDataOf" as const,
            args: [BigInt(id)],
          })),
        });
        ids.forEach((id, j) => {
          const r = res[j];
          if (r?.status === "success") {
            const d = r.result as unknown as RawWordData;
            if (d.honors) items.push(toItem(id, d));
          }
        });
      }
      return items;
    },
    [],
    { refetchInterval: 0, enabled },
  );
}
