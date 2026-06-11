"use client";

import { getAbiItem, type AbiEvent, type PublicClient } from "viem";
import { bountyEngineAbi } from "@/lib/contracts/abis";
import { requireAddress } from "@/lib/contracts/addresses";
import { getLogsChunked } from "@/lib/events/logs";

export const SENTENCE_EVENT = getAbiItem({
  abi: bountyEngineAbi,
  name: "SentenceGenerated",
}) as AbiEvent;

export interface SentenceEvent {
  eventId: number;
  tokenIds: number[];
  words: string[];
  templateId: number;
  amountWei: bigint;
  sharePerWordWei: bigint;
  deadline: number; // unix seconds
  blockNumber: bigint;
}

/** Recent sentences (newest first), from SentenceGenerated logs — no indexer.
 *  Bounded lookback: claimable shares expire after the 7-day window, so only
 *  recent sentences matter; this also keeps the scan fast on rate-limited RPCs. */
export async function getRecentSentences(
  client: PublicClient,
  limit = 40,
  lookback = 120_000n, // ~2 weeks on a 12s chain — covers the 7-day claim window
): Promise<SentenceEvent[]> {
  const address = requireAddress("bountyEngine");
  const logs = await getLogsChunked(client, { address, event: SENTENCE_EVENT, lookback });
  const parsed = logs.map((l) => {
    const a = (l as unknown as {
      args: {
        eventId: bigint;
        tokenIds: readonly bigint[];
        words: readonly string[];
        templateId: bigint;
        amount: bigint;
        sharePerWord: bigint;
        deadline: bigint;
      };
      blockNumber: bigint;
    });
    return {
      eventId: Number(a.args.eventId),
      tokenIds: a.args.tokenIds.map(Number),
      words: [...a.args.words],
      templateId: Number(a.args.templateId),
      amountWei: a.args.amount,
      sharePerWordWei: a.args.sharePerWord,
      deadline: Number(a.args.deadline),
      blockNumber: a.blockNumber,
    };
  });
  parsed.reverse(); // newest first
  return parsed.slice(0, limit);
}

export interface ClaimableShare {
  eventId: number;
  sharePerWordWei: bigint;
  deadline: number;
}

/**
 * Open, claimable bounty shares for a token across recent sentences — the
 * forfeiture set the unbind flow and the token due-diligence view both need.
 */
export async function claimableForToken(
  client: PublicClient,
  tokenId: number,
  recent?: SentenceEvent[],
): Promise<ClaimableShare[]> {
  const address = requireAddress("bountyEngine");
  const events = recent ?? (await getRecentSentences(client));
  // Only sentences that actually included this token can be claimable.
  const candidates = events.filter((e) => e.tokenIds.includes(tokenId));
  if (candidates.length === 0) return [];

  const checks = await client.multicall({
    allowFailure: true,
    contracts: candidates.map((e) => ({
      address,
      abi: bountyEngineAbi,
      functionName: "isClaimable" as const,
      args: [BigInt(e.eventId), BigInt(tokenId)],
    })),
  });

  const out: ClaimableShare[] = [];
  candidates.forEach((e, i) => {
    if (checks[i].status === "success" && checks[i].result === true) {
      out.push({ eventId: e.eventId, sharePerWordWei: e.sharePerWordWei, deadline: e.deadline });
    }
  });
  return out;
}

/** unix seconds → ISO string for the timeRemaining() formatter. */
export function isoFromUnix(unix: number): string {
  return new Date(unix * 1000).toISOString();
}
