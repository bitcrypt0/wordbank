"use client";

import { getAbiItem, type AbiEvent, type PublicClient } from "viem";
import { bountyEngineAbi, wordBankAbi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { getLogsChunked } from "@/lib/events/logs";
import { getRecentSentences, type SentenceEvent } from "./bounties";
import { useWallet } from "@/lib/wallet/WalletProvider";

const CLAIMED_EVENT = getAbiItem({ abi: bountyEngineAbi, name: "BountyClaimed" }) as AbiEvent;

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
  account: `0x${string}` | null,
): Promise<RevealedSentence> {
  const be = requireAddress("bountyEngine");
  const bank = requireAddress("wordBank");

  // getTemplate returns a positional tuple [slots, fragments].
  const tmpl = (await client.readContract({
    address: be,
    abi: bountyEngineAbi,
    functionName: "getTemplate",
    args: [BigInt(ev.templateId)],
  })) as readonly [readonly number[], readonly string[]];
  const templateFragments = tmpl[1];

  // Per-token status: isClaimable + isAlive + ownerOf.
  const perToken = await client.multicall({
    allowFailure: true,
    contracts: ev.tokenIds.flatMap((id) => [
      { address: be, abi: bountyEngineAbi, functionName: "isClaimable" as const, args: [BigInt(ev.eventId), BigInt(id)] },
      { address: bank, abi: wordBankAbi, functionName: "isAlive" as const, args: [BigInt(id)] },
      { address: bank, abi: wordBankAbi, functionName: "ownerOf" as const, args: [BigInt(id)] },
    ]),
  });

  // Claimed set from BountyClaimed(eventId) logs.
  const claimedLogs = await getLogsChunked(client, {
    address: be,
    event: CLAIMED_EVENT,
    args: { eventId: BigInt(ev.eventId) },
  });
  const claimedIds = new Set(
    claimedLogs.map((l) => Number((l as unknown as { args: { tokenId: bigint } }).args.tokenId)),
  );

  const words: WordStatus[] = ev.tokenIds.map((id, i) => {
    const claimableRes = perToken[i * 3];
    const aliveRes = perToken[i * 3 + 1];
    const ownerRes = perToken[i * 3 + 2];
    const claimable = claimableRes.status === "success" && claimableRes.result === true;
    const alive = aliveRes.status === "success" && aliveRes.result === true;
    const owner = ownerRes.status === "success" ? String(ownerRes.result) : null;
    return {
      tokenId: id,
      word: ev.words[i] ?? "",
      alive,
      owner,
      claimable,
      claimed: claimedIds.has(id),
      yours: !!account && !!owner && owner.toLowerCase() === account.toLowerCase(),
    };
  });

  return {
    eventId: ev.eventId,
    fragments: [...templateFragments],
    words,
    amountWei: ev.amountWei,
    sharePerWordWei: ev.sharePerWordWei,
    deadline: ev.deadline,
    revealedBlock: ev.blockNumber,
  };
}

export function useGameState() {
  const { account } = useWallet();

  return useChainData<GameState>(
    async (client: PublicClient) => {
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

      // Live revealed sentence: newest SentenceGenerated still inside its window.
      let revealed: RevealedSentence | null = null;
      let history: HistoryRow[] = [];
      if (registrySynced) {
        const recent = await getRecentSentences(client, 12);
        const nowSec = Number(block.timestamp);
        const newest = recent[0];
        if (newest && newest.deadline > nowSec) {
          revealed = await buildSentence(client, newest, account);
        }
        // History: swept flag per event from eventInfo.
        if (recent.length > 0) {
          const infos = await client.multicall({
            allowFailure: true,
            contracts: recent.map((e) => ({
              address: be,
              abi: bountyEngineAbi,
              functionName: "eventInfo" as const,
              args: [BigInt(e.eventId)],
            })),
          });
          history = await Promise.all(
            recent.map(async (e, i) => {
              const info = infos[i];
              // eventInfo returns [tokenIds, sharePerWord, deadline, swept].
              const swept =
                info.status === "success"
                  ? Boolean((info.result as readonly unknown[])[3])
                  : false;
              const tmpl = (await client
                .readContract({ address: be, abi: bountyEngineAbi, functionName: "getTemplate", args: [BigInt(e.templateId)] })
                .catch(() => [[], []] as readonly [readonly number[], readonly string[]])) as readonly [readonly number[], readonly string[]];
              return {
                eventId: e.eventId,
                words: e.tokenIds.map((id, j) => ({ tokenId: id, word: e.words[j] ?? "" })),
                fragments: [...tmpl[1]],
                amountWei: e.amountWei,
                deadline: e.deadline,
                swept,
              };
            }),
          );
        }
      }

      return {
        phase,
        registryCursor: Number(bankReads[1]),
        registryTarget: Number(bankReads[2]) || 10000,
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
        revealed,
        history,
      };
    },
    [account],
    { refetchInterval: 12_000 },
  );
}
