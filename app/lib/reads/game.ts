"use client";

import { type PublicClient } from "viem";
import { bountyEngineAbi, wordBankAbi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { getRecentSentencesByIndex, fetchFragmentsFor, type SentenceEvent } from "./bounties";
import { useWallet } from "@/lib/wallet/WalletProvider";

export type GamePhase =
  | "pre-start"
  | "idle"
  | "committed"
  | "revealable"
  | "expired";

export interface WordStatus {
  tokenId: number;
  word: string;
  alive: boolean;
  owner: string | null;
  claimable: boolean;
  claimed: boolean;
  yours: boolean;
}

export interface RevealedSentence {
  eventId: number;
  fragments: string[];
  words: WordStatus[];
  amountWei: bigint;
  sharePerWordWei: bigint;
  deadline: number;
  revealedBlock: bigint;
}

export interface HistoryRow {
  eventId: number;
  words: { tokenId: number; word: string }[];
  fragments: string[];
  amountWei: bigint;
  deadline: number;
  swept: boolean;
}

export interface GameState {
  phase: GamePhase;
  registryCursor: number;
  registryTarget: number;
  // treasury + tiers
  freeTreasuryWei: bigint;
  tiersWei: bigint[];
  // current commit
  commitEventId: number;
  committer: string | null;
  targetBlock: bigint;
  blockNumber: bigint;
  blockTimestamp: number;
  // constants
  bondWei: bigint;
  revealDelayBlocks: number;
  blockhashWindow: number;
  revealRewardBps: number;
  cycleLength: number;
  lastEventTimestamp: number;
  // gating
  holderBalance: number;
  totalAlive: number;
  // the live revealed sentence (in claim window), if any
  revealed: RevealedSentence | null;
  history: HistoryRow[];
}

/** currentCommit returns the positional tuple [committer, targetBlock, eventId]. */
type RawCommit = readonly [string, bigint, bigint];

async function buildSentence(
  client: PublicClient,
  ev: SentenceEvent,
  fragments: string[],
  account: `0x${string}` | null,
): Promise<RevealedSentence> {
  const be = requireAddress("bountyEngine");
  const bank = requireAddress("wordBank");

  // Per-token status in ONE multicall — no log scans:
  //   isClaimable + isAlive + ownerOf + claimed (the BountyEngine.claimed mapping
  //   getter). The `claimed` flag replaces the old BountyClaimed getLogs scan that
  //   ran a 250k-block lookback per revealed sentence.
  const perToken = await client.multicall({
    allowFailure: true,
    contracts: ev.tokenIds.flatMap((id) => [
      { address: be, abi: bountyEngineAbi, functionName: "isClaimable" as const, args: [BigInt(ev.eventId), BigInt(id)] },
      { address: bank, abi: wordBankAbi, functionName: "isAlive" as const, args: [BigInt(id)] },
      { address: bank, abi: wordBankAbi, functionName: "ownerOf" as const, args: [BigInt(id)] },
      { address: be, abi: bountyEngineAbi, functionName: "claimed" as const, args: [BigInt(ev.eventId), BigInt(id)] },
    ]),
  });

  const words: WordStatus[] = ev.tokenIds.map((id, i) => {
    const claimableRes = perToken[i * 4];
    const aliveRes = perToken[i * 4 + 1];
    const ownerRes = perToken[i * 4 + 2];
    const claimedRes = perToken[i * 4 + 3];
    const claimable = claimableRes.status === "success" && claimableRes.result === true;
    const alive = aliveRes.status === "success" && aliveRes.result === true;
    const owner = ownerRes.status === "success" ? String(ownerRes.result) : null;
    const claimed = claimedRes.status === "success" && claimedRes.result === true;
    return {
      tokenId: id,
      word: ev.words[i] ?? "",
      alive,
      owner,
      claimable,
      claimed,
      yours: !!account && !!owner && owner.toLowerCase() === account.toLowerCase(),
    };
  });

  return {
    eventId: ev.eventId,
    fragments: [...fragments],
    words,
    amountWei: ev.amountWei,
    sharePerWordWei: ev.sharePerWordWei,
    deadline: ev.deadline,
    revealedBlock: ev.blockNumber,
  };
}

/** Cheap, always-fresh live state — polled on the SHORT interval. No sentence
 *  reconstruction, no logs: just the commit/phase/treasury/block multicalls. */
interface LiveState {
  phase: GamePhase;
  registryCursor: number;
  registryTarget: number;
  registrySynced: boolean;
  freeTreasuryWei: bigint;
  tiersWei: bigint[];
  commitEventId: number;
  committer: string | null;
  targetBlock: bigint;
  blockNumber: bigint;
  blockTimestamp: number;
  bondWei: bigint;
  revealDelayBlocks: number;
  blockhashWindow: number;
  revealRewardBps: number;
  cycleLength: number;
  lastEventTimestamp: number;
  holderBalance: number;
  totalAlive: number;
}

/** The heavy part — recent sentences + history — fetched MUCH less often. */
interface SentenceState {
  revealed: RevealedSentence | null;
  history: HistoryRow[];
}

async function fetchLiveState(client: PublicClient, account: `0x${string}` | null): Promise<LiveState> {
  if (!isDeployed("bountyEngine") || !isDeployed("wordBank")) throw new NotDeployedError();
  const be = requireAddress("bountyEngine");
  const bank = requireAddress("wordBank");
  const viewer = (account ?? "0x0000000000000000000000000000000000000000") as `0x${string}`;

  const [bountyReads, bankReads, block] = await Promise.all([
    client.multicall({
      allowFailure: false,
      contracts: [
        { address: be, abi: bountyEngineAbi, functionName: "currentCommit" },
        { address: be, abi: bountyEngineAbi, functionName: "freeTreasury" },
        { address: be, abi: bountyEngineAbi, functionName: "tiers" },
        { address: be, abi: bountyEngineAbi, functionName: "lastEventTimestamp" },
        { address: be, abi: bountyEngineAbi, functionName: "BOND" },
        { address: be, abi: bountyEngineAbi, functionName: "REVEAL_DELAY" },
        { address: be, abi: bountyEngineAbi, functionName: "BLOCKHASH_WINDOW" },
        { address: be, abi: bountyEngineAbi, functionName: "REVEAL_REWARD_BPS" },
        { address: be, abi: bountyEngineAbi, functionName: "CYCLE_LENGTH" },
      ],
    }),
    client.multicall({
      allowFailure: false,
      contracts: [
        { address: bank, abi: wordBankAbi, functionName: "registrySynced" },
        { address: bank, abi: wordBankAbi, functionName: "registryCursor" },
        { address: bank, abi: wordBankAbi, functionName: "preRevealMinted" },
        { address: bank, abi: wordBankAbi, functionName: "balanceOf", args: [viewer] },
        { address: bank, abi: wordBankAbi, functionName: "totalAlive" },
      ],
    }),
    client.getBlock(),
  ]);

  const commit = bountyReads[0] as unknown as RawCommit;
  const committerAddr = commit[0];
  const commitEventId = commit[2];
  const registrySynced = Boolean(bankReads[0]);
  const head = block.number;
  const targetBlock = commit[1];
  const blockhashWindow = Number(bountyReads[6]);

  // Phase resolution (HANDOFF §4).
  let phase: GamePhase;
  if (!registrySynced) phase = "pre-start";
  else if (targetBlock === 0n) phase = "idle";
  else if (head <= targetBlock) phase = "committed";
  else if (head <= targetBlock + BigInt(blockhashWindow)) phase = "revealable";
  else phase = "expired";

  return {
    phase,
    registryCursor: Number(bankReads[1]),
    registryTarget: Number(bankReads[2]) || 10000,
    registrySynced,
    freeTreasuryWei: bountyReads[1] as bigint,
    tiersWei: [...(bountyReads[2] as bigint[])],
    commitEventId: Number(commitEventId),
    committer: targetBlock === 0n ? null : committerAddr,
    targetBlock,
    blockNumber: head,
    blockTimestamp: Number(block.timestamp),
    bondWei: bountyReads[4] as bigint,
    revealDelayBlocks: Number(bountyReads[5]),
    blockhashWindow,
    revealRewardBps: Number(bountyReads[7]),
    cycleLength: Number(bountyReads[8]),
    lastEventTimestamp: Number(bountyReads[3]),
    holderBalance: Number(bankReads[3]),
    totalAlive: Number(bankReads[4]),
  };
}

async function fetchSentenceState(
  client: PublicClient,
  account: `0x${string}` | null,
): Promise<SentenceState> {
  if (!isDeployed("bountyEngine") || !isDeployed("wordBank")) throw new NotDeployedError();
  const bank = requireAddress("wordBank");

  // Only meaningful once the game has started (registry synced) — otherwise no
  // sentences exist and we skip all of this entirely.
  const registrySynced = (await client.readContract({
    address: bank,
    abi: wordBankAbi,
    functionName: "registrySynced",
  })) as boolean;
  if (!registrySynced) return { revealed: null, history: [] };

  // Index/mapping discovery (no wide log scan): nextEventId → eventInfo → wordOf.
  const recent = await getRecentSentencesByIndex(client, 12);
  if (recent.length === 0) return { revealed: null, history: [] };

  const block = await client.getBlock();
  const nowSec = Number(block.timestamp);

  // Fragments (the one off-chain-only field) for ALL displayed events in ONE
  // tightly-bounded SentenceGenerated scan, bounded by the oldest event's block.
  const fragMap = await fetchFragmentsFor(
    client,
    recent.map((e) => ({ eventId: e.eventId, deadline: e.deadline })),
    { number: block.number, timestamp: nowSec },
  );

  // Live revealed sentence: newest event still inside its claim window.
  let revealed: RevealedSentence | null = null;
  const newest = recent[0];
  if (newest && newest.deadline > nowSec) {
    revealed = await buildSentence(client, newest, fragMap.get(newest.eventId) ?? [], account);
  }

  // History: swept comes straight from eventInfo (already in `recent`'s source);
  // re-derive via a single eventInfo multicall for the swept flag.
  const be = requireAddress("bountyEngine");
  const infos = await client.multicall({
    allowFailure: true,
    contracts: recent.map((e) => ({
      address: be,
      abi: bountyEngineAbi,
      functionName: "eventInfo" as const,
      args: [BigInt(e.eventId)],
    })),
  });
  const history: HistoryRow[] = recent.map((e, i) => {
    const info = infos[i];
    const swept =
      info.status === "success" ? Boolean((info.result as readonly unknown[])[3]) : false;
    return {
      eventId: e.eventId,
      words: e.tokenIds.map((id, j) => ({ tokenId: id, word: e.words[j] ?? "" })),
      fragments: fragMap.get(e.eventId) ?? [],
      amountWei: e.amountWei,
      deadline: e.deadline,
      swept,
    };
  });

  return { revealed, history };
}

/**
 * Game state, split across two refetch cadences so the heavy sentence/history
 * read is NOT on the 12s loop:
 *   - LIVE state (phase/commit/block/treasury/holder) — cheap multicalls, polled
 *     every 12s for countdown/phase freshness.
 *   - SENTENCE state (revealed + history) — index/mapping reads + one tightly-
 *     bounded fragment scan, polled every 60s (and via the shared manual refetch
 *     after a tx, so claims/reveals reflect immediately).
 * Merged into the same `GameState` the page already consumes.
 */
export function useGameState() {
  const { account } = useWallet();

  const live = useChainData<LiveState>(
    (client) => fetchLiveState(client, account),
    [account],
    { refetchInterval: 12_000 },
  );

  const sentences = useChainData<SentenceState>(
    (client) => fetchSentenceState(client, account),
    [account],
    // Stagger the heavier sentence/history read ~250ms behind the live read so
    // the two don't fire their request bursts simultaneously and trip a public
    // RPC's rate limiter on mount.
    { refetchInterval: 60_000, initialDelayMs: 250 },
  );

  const refetch = () => {
    live.refetch();
    sentences.refetch();
  };

  // Status/data follow the LIVE read (it drives phase + the whole page shell);
  // the sentence read layers on top once it resolves. While sentences are still
  // loading we show the live state with no revealed/history (the page already
  // renders an empty history gracefully).
  const data: GameState | null = live.data
    ? {
        ...live.data,
        revealed: sentences.data?.revealed ?? null,
        history: sentences.data?.history ?? [],
      }
    : null;

  return { data, status: live.status, error: live.error, refetch };
}
