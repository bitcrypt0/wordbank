"use client";

import type { PublicClient } from "viem";
import { wordBankAbi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import type { Category } from "@/lib/mocks/types";

const CATS: Category[] = ["NOUN", "VERB", "ADJ", "ADV"];
const CAT_INDEX: Record<Category, number> = { NOUN: 0, VERB: 1, ADJ: 2, ADV: 3 };

export interface GalleryItem {
  tokenId: number;
  word: string;
  category: Category;
  material: number;
  ink: number;
  background: number;
  honors: boolean;
}

export interface GalleryPage {
  items: GalleryItem[];
  total: number;
  loadedAll: boolean;
}

interface RawWordData {
  word: string;
  category: number;
  material: number;
  ink: number;
  background: number;
  honors: boolean;
}

/**
 * A page of the living collection. WordBank isn't enumerable, but it exposes
 * per-category alive arrays (aliveCount/aliveAt). We take a deterministic slice
 * across the selected scope, resolve tokenIds, then batch wordDataOf for the
 * trait/word data. Order is a per-load snapshot (the arrays use swap-and-pop).
 */
export function useGalleryPage(scope: Category | "ALL", limit: number, enabled = true) {
  return useChainData<GalleryPage>(
    async (client: PublicClient) => {
      if (!isDeployed("wordBank")) throw new NotDeployedError();
      const bank = requireAddress("wordBank");

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
      if (picks.length === 0) return { items: [], total, loadedAll: true };

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

      const items: GalleryItem[] = ids.map((id, i) => ({
        tokenId: Number(id),
        word: data[i].word,
        category: CATS[data[i].category] ?? "NOUN",
        material: data[i].material,
        ink: data[i].ink,
        background: data[i].background,
        honors: data[i].honors,
      }));

      return { items, total, loadedAll: items.length >= total };
    },
    [scope, limit],
    { refetchInterval: 0, enabled },
  );
}

function toItem(id: number, d: RawWordData): GalleryItem {
  return {
    tokenId: id,
    word: d.word,
    category: CATS[d.category] ?? "NOUN",
    material: d.material,
    ink: d.ink,
    background: d.background,
    honors: d.honors,
  };
}

/**
 * Look up a single token by id (powers the gallery's numeric search). Resolves
 * to the item, or null when the id isn't a minted/revealed word. Disabled (no
 * fetch) unless `idStr` is a non-negative integer.
 */
export function useGalleryById(idStr: string) {
  const trimmed = idStr.trim();
  const id = /^\d+$/.test(trimmed) ? Number(trimmed) : -1;
  return useChainData<GalleryItem | null>(
    async (client: PublicClient) => {
      if (!isDeployed("wordBank")) throw new NotDeployedError();
      if (id < 0) return null;
      const bank = requireAddress("wordBank");
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
 * Find every honors (1/1) word across the whole collection — the honors filter
 * can't work on a paginated subset (only ~25 of 10,000 are honors). Scans
 * wordDataOf in batches over the minted range; disabled until requested.
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
