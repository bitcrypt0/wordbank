"use client";

import { getAbiItem, type AbiEvent, type PublicClient } from "viem";
import { bountyEngineAbi, wordBankAbi } from "@/lib/contracts/abis";
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

/**
 * Recent sentences (newest first) via INDEX/MAPPING reads — the fast path used by
 * the /game page. Replaces the old wide `SentenceGenerated` getLogs lookback.
 *
 * How it avoids the catastrophic scan:
 *   - `nextEventId` (public, starts at 1) → latest eventId = nextEventId − 1.
 *   - `eventInfo(id)` (multicall, newest-first) returns [tokenIds, sharePerWord,
 *     deadline, swept] for each revealed event. Aborted/never-revealed ids have
 *     deadline == 0 and are skipped (eventInfo returns empty — micro-decision b).
 *   - `wordOf(tokenId)` (multicall, post-reveal) reconstructs the words.
 *   - pot (amountWei) = sharePerWord × tokenIds.length.
 *
 * The ONE field with no on-chain getter is `templateId` → the literal sentence
 * fragments (BountyEvent doesn't store templateId; eventInfo doesn't return it).
 * So fragments are fetched separately via a TIGHTLY-BOUNDED SentenceGenerated
 * scan (see `attachFragments`) covering only the few displayed events — never a
 * blanket 120k/250k lookback.
 */
export async function getRecentSentencesByIndex(
  client: PublicClient,
  limit = 12,
): Promise<SentenceEvent[]> {
  const be = requireAddress("bountyEngine");
  const bank = requireAddress("wordBank");

  const next = (await client.readContract({
    address: be,
    abi: bountyEngineAbi,
    functionName: "nextEventId",
  })) as bigint;
  const latest = Number(next) - 1;
  if (latest < 1) return [];

  // The last `limit` event ids, newest-first.
  const ids: number[] = [];
  for (let id = latest; id >= 1 && ids.length < limit; id--) ids.push(id);

  // eventInfo for each id → [tokenIds, sharePerWord, deadline, swept].
  const infos = await client.multicall({
    allowFailure: true,
    contracts: ids.map((id) => ({
      address: be,
      abi: bountyEngineAbi,
      functionName: "eventInfo" as const,
      args: [BigInt(id)],
    })),
  });

  // Keep only events that actually revealed (deadline > 0); collect their tokenIds.
  type Partial = { eventId: number; tokenIds: number[]; sharePerWordWei: bigint; deadline: number };
  const partials: Partial[] = [];
  ids.forEach((id, i) => {
    const r = infos[i];
    if (r.status !== "success") return;
    const tuple = r.result as readonly [readonly bigint[], bigint, bigint, boolean];
    const deadline = Number(tuple[2]);
    if (deadline === 0) return; // aborted / never revealed
    partials.push({
      eventId: id,
      tokenIds: tuple[0].map(Number),
      sharePerWordWei: tuple[1],
      deadline,
    });
  });
  if (partials.length === 0) return [];

  // wordOf(tokenId) for every token across all displayed events (one multicall).
  const flatTokens = partials.flatMap((p) => p.tokenIds);
  const wordReads = await client.multicall({
    allowFailure: true,
    contracts: flatTokens.map((id) => ({
      address: bank,
      abi: wordBankAbi,
      functionName: "wordOf" as const,
      args: [BigInt(id)],
    })),
  });
  const wordByToken = new Map<number, string>();
  flatTokens.forEach((id, i) => {
    const w = wordReads[i];
    wordByToken.set(id, w.status === "success" ? String(w.result) : "");
  });

  return partials.map((p) => ({
    eventId: p.eventId,
    tokenIds: p.tokenIds,
    words: p.tokenIds.map((id) => wordByToken.get(id) ?? ""),
    templateId: -1, // not recoverable on-chain; fragments come from attachFragments
    amountWei: p.sharePerWordWei * BigInt(p.tokenIds.length),
    sharePerWordWei: p.sharePerWordWei,
    deadline: p.deadline,
    blockNumber: 0n, // unknown from the index path; only used to bound the fragment scan
  }));
}

/**
 * Fetch the literal sentence `fragments` for the given events — the ONE field the
 * index path can't read (templateId isn't stored/exposed on-chain). This does a
 * TIGHTLY-BOUNDED `SentenceGenerated` scan: it estimates the oldest displayed
 * event's block from its claim deadline (deadline = revealBlock.timestamp +
 * 7 days, ~12s/block) and scans only from a little before that to the head —
 * NOT a blanket 120k/250k lookback. Returns a map eventId → fragments.
 *
 * Bounded because all displayed events are recent: the live one is inside its
 * 7-day claim window and the short history just behind it, so the window is at
 * most ~the claim window plus a small margin (a few thousand blocks), and is
 * filtered to the exact eventIds requested.
 */
export async function fetchFragmentsFor(
  client: PublicClient,
  events: { eventId: number; deadline: number }[],
  block?: { number: bigint; timestamp: number },
): Promise<Map<number, string[]>> {
  const out = new Map<number, string[]>();
  if (events.length === 0) return out;

  const head = block ?? {
    number: await client.getBlockNumber(),
    timestamp: Math.floor(Date.now() / 1000),
  };

  // Oldest displayed event's reveal time ≈ its deadline − 7 days. Convert the
  // age (now − revealTime) into a block span at ~12s/block, clamp to a sane band.
  const CLAIM_WINDOW = 7 * 24 * 3600;
  const oldestDeadline = Math.min(...events.map((e) => e.deadline));
  const oldestRevealTs = oldestDeadline - CLAIM_WINDOW;
  const ageSecs = Math.max(0, head.timestamp - oldestRevealTs);
  const ageBlocks = BigInt(Math.ceil(ageSecs / 12)) + 2_000n; // +margin for drift
  // Hard ceiling so a clock skew can't reintroduce a huge scan; ~5 weeks max.
  const span = ageBlocks > 250_000n ? 250_000n : ageBlocks;
  const fromBlock = head.number > span ? head.number - span : 0n;

  const wanted = new Set(events.map((e) => e.eventId));
  const logs = await getLogsChunked(client, {
    address: requireAddress("bountyEngine"),
    event: SENTENCE_EVENT,
    fromBlock,
    toBlock: head.number,
  });
  // Each SentenceGenerated log carries templateId; resolve fragments via getTemplate.
  const matched = logs
    .map((l) => (l as unknown as { args: { eventId: bigint; templateId: bigint } }).args)
    .filter((a) => wanted.has(Number(a.eventId)));
  const byEvent = new Map<number, number>();
  for (const a of matched) byEvent.set(Number(a.eventId), Number(a.templateId));

  const uniqTemplates = [...new Set([...byEvent.values()])];
  const tmpls = await client.multicall({
    allowFailure: true,
    contracts: uniqTemplates.map((t) => ({
      address: requireAddress("bountyEngine"),
      abi: bountyEngineAbi,
      functionName: "getTemplate" as const,
      args: [BigInt(t)],
    })),
  });
  const fragsByTemplate = new Map<number, string[]>();
  uniqTemplates.forEach((t, i) => {
    const r = tmpls[i];
    if (r.status === "success") {
      const tuple = r.result as readonly [readonly number[], readonly string[]];
      fragsByTemplate.set(t, [...tuple[1]]);
    }
  });

  for (const [eventId, templateId] of byEvent) {
    out.set(eventId, fragsByTemplate.get(templateId) ?? []);
  }
  return out;
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
