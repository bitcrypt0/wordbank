/**
 * Event history via chunked getLogs — no third-party indexer (charter). Public
 * RPCs (e.g. Alchemy Sepolia) reject windows that span too many blocks or
 * return too many logs, and rate-limit bursts of calls. So this pages backwards
 * from the head in windows that:
 *   - auto-SHRINK (split in half) when a window is rejected for range/result size,
 *   - RETRY with backoff on rate-limit errors,
 *   - record an unrecoverable single-block window as a GAP (via onGap) and keep
 *     going, so a partial result is surfaced instead of throwing the whole load away,
 *   - early-EXIT via stopWhen (e.g. once a holder's full balance is found).
 * Used by the dashboard, game history, burn history, and royalty totals.
 */
import type { AbiEvent, GetLogsReturnType, PublicClient } from "viem";

const DEFAULT_CHUNK = 9_000n; // under the common 10k-block provider cap
// Bounded so a rate-limited public RPC isn't paged through hundreds of windows.
// ~5 weeks on a 12s chain — comfortably covers a recent deploy's whole history;
// callers needing more pass `lookback`/`fromBlock`, and stopWhen short-circuits.
const DEFAULT_LOOKBACK = 250_000n;
const MAX_RATELIMIT_RETRIES = 4;
const SLEEP = (ms: number) => new Promise((r) => setTimeout(r, ms));

function isRateLimit(err: unknown): boolean {
  const msg = String((err as { message?: string })?.message ?? "").toLowerCase();
  const code = (err as { code?: unknown })?.code;
  return (
    msg.includes("rate limit") ||
    msg.includes("too many requests") ||
    msg.includes("429") ||
    code === 429 ||
    code === -32005
  );
}

export interface ChunkedLogsParams<TEvent extends AbiEvent> {
  address: `0x${string}`;
  event: TEvent;
  /** Indexed-arg filter, e.g. { tokenId: 5n }. */
  args?: Record<string, unknown>;
  /** First block to include. Defaults to head − lookback. Pass 0n for full history. */
  fromBlock?: bigint;
  /** Last block to include. Defaults to the chain head. */
  toBlock?: bigint;
  chunkSize?: bigint;
  lookback?: bigint;
  /** Stop once this many logs are collected (newest-first scan). */
  limit?: number;
  /** Stop early when this returns true (called after each window, newest→oldest). */
  stopWhen?: (collected: readonly unknown[]) => boolean;
  /** Called when a single-block window can't be fetched — the result is partial. */
  onGap?: (fromBlock: bigint, toBlock: bigint, err: unknown) => void;
}

/**
 * Returns logs ordered oldest → newest. Never throws on an individual window —
 * oversized windows split, rate-limited windows back off, and a window that
 * still fails at one block is reported via onGap and skipped.
 */
export async function getLogsChunked<TEvent extends AbiEvent>(
  client: PublicClient,
  params: ChunkedLogsParams<TEvent>,
): Promise<GetLogsReturnType<TEvent>> {
  const head = params.toBlock ?? (await client.getBlockNumber());
  const chunk = params.chunkSize ?? DEFAULT_CHUNK;
  const lookback = params.lookback ?? DEFAULT_LOOKBACK;
  const floor = params.fromBlock ?? (head > lookback ? head - lookback : 0n);

  // Fetch one window with rate-limit backoff + recursive shrink on size errors.
  const fetchWindow = async (lower: bigint, upper: bigint): Promise<unknown[]> => {
    let attempt = 0;
    let delay = 500;
    for (;;) {
      try {
        const logs = await client.getLogs({
          address: params.address,
          event: params.event,
          args: params.args,
          fromBlock: lower,
          toBlock: upper,
        } as Parameters<PublicClient["getLogs"]>[0]);
        return logs as unknown[];
      } catch (err) {
        if (isRateLimit(err) && attempt < MAX_RATELIMIT_RETRIES) {
          await SLEEP(delay);
          delay = Math.min(delay * 2, 8000);
          attempt += 1;
          continue;
        }
        // Too-large window (range/result cap) → split and recurse.
        if (upper > lower) {
          const mid = lower + (upper - lower) / 2n;
          const right = await fetchWindow(mid + 1n, upper);
          const left = await fetchWindow(lower, mid);
          return [...right, ...left];
        }
        // Single block still failing — record the gap, skip it.
        params.onGap?.(lower, upper, err);
        return [];
      }
    }
  };

  const collected: unknown[] = [];
  let upper = head;
  while (upper >= floor) {
    const lower = upper > floor + chunk ? upper - chunk : floor;
    const logs = await fetchWindow(lower, upper);
    collected.push(...logs);
    if (params.limit && collected.length >= params.limit) break;
    if (params.stopWhen && params.stopWhen(collected)) break;
    if (lower === floor) break;
    upper = lower - 1n;
  }

  collected.sort((a, b) => {
    const la = a as { blockNumber: bigint; logIndex: number };
    const lb = b as { blockNumber: bigint; logIndex: number };
    if (la.blockNumber !== lb.blockNumber) return la.blockNumber < lb.blockNumber ? -1 : 1;
    return la.logIndex - lb.logIndex;
  });
  return collected as GetLogsReturnType<TEvent>;
}
