"use client";

import Link from "next/link";
import { useGameState, type GameState, type RevealedSentence, type HistoryRow } from "@/lib/reads/game";
import { useWallet } from "@/lib/wallet/WalletProvider";
import { requireAddress } from "@/lib/contracts/addresses";
import { bountyEngineAbi } from "@/lib/contracts/abis";
import { TokenArt } from "@/components/TokenArt";
import { Meter, TxButton, ErrorState, PendingState } from "@/components/ui";
import { formatEth, timeRemaining, shortAddress } from "@/lib/format";
import { isoFromUnix } from "@/lib/reads/bounties";
import styles from "./game.module.css";

const be = () => requireAddress("bountyEngine");

export default function GamePage() {
  const { account } = useWallet();
  const { data: g, status, refetch } = useGameState();

  return (
    <div className="container">
      <header className={styles.head}>
        <p className="eyebrow">The daily game</p>
        <h1 className={styles.title}>One sentence a day</h1>
        <p className={styles.lede}>
          Any word holder opens the draw with a small bond. Fifteen blocks
          later, anyone can reveal — and a sentence composes itself from
          living words. Every word drawn splits the bounty. Claim within
          seven days; what goes unclaimed returns to the treasury.
        </p>
      </header>

      {status === "pending" ? (
        <PendingState />
      ) : status === "error" || !g ? (
        status === "error" ? (
          <ErrorState
            hint="The game state couldn't be read — the cycle continues onchain regardless. Try again."
            onRetry={refetch}
          />
        ) : (
          <div className="skeleton" style={{ height: 260, borderRadius: 12 }} />
        )
      ) : g.phase === "pre-start" ? (
        <PreStart g={g} refetch={refetch} />
      ) : (
        <>
          {g.phase === "idle" ? (
            <Idle g={g} account={account} refetch={refetch} />
          ) : g.phase === "committed" ? (
            <Committed g={g} />
          ) : g.phase === "revealable" ? (
            <Revealable g={g} refetch={refetch} />
          ) : (
            <Expired g={g} refetch={refetch} />
          )}

          {g.revealed ? (
            <Revealed g={g} ev={g.revealed} connected={!!account} refetch={refetch} />
          ) : null}

          <History rows={g.history} now={g.blockTimestamp} refetch={refetch} />
        </>
      )}
    </div>
  );
}

/* ─────────────────────── pre-start (SPEC-3) ─────────────────────── */
function PreStart({ g }: { g: GameState; refetch: () => void }) {
  return (
    <section className={`plate ${styles.bigBox}`}>
      <span className={styles.bigGlyph} aria-hidden="true">🔒</span>
      <h2 className={styles.boxTitle}>The game hasn&apos;t begun</h2>
      <p className={styles.boxNote}>
        It unlocks by itself — no announcement, no switch — the moment the
        collection sells out, the provenance offset is fixed, and the word
        registry finishes indexing. Until then, nobody can start a draw, so
        nobody can game the early board.
      </p>
      <div className={styles.registryMeter}>
        <Meter
          label="Registry build"
          value={g.registryCursor}
          max={g.registryTarget || 1}
          detail={`${g.registryCursor.toLocaleString("en-US")} / ${g.registryTarget.toLocaleString("en-US")} words indexed`}
          tone="gold"
        />
      </div>
      <p className={styles.wiringNote}>
        anyone can push it along on the <Link href="/mint">mint page</Link> ·
        gate: <span className="mono">registrySynced()</span>
      </p>
    </section>
  );
}

/* ─────────────────────────── idle ─────────────────────────── */
function Idle({ g, account, refetch }: { g: GameState; account: string | null; refetch: () => void }) {
  const affordable = g.tiersWei.filter((t) => t <= g.freeTreasuryWei);
  const cycleReady = g.blockTimestamp >= g.lastEventTimestamp + g.cycleLength;
  const canCommit = g.holderBalance >= 1 && cycleReady;
  const hint = !account
    ? undefined
    : g.holderBalance < 1
      ? "You need to hold a word to start the draw."
      : !cycleReady
        ? "The daily draw has already run this cycle."
        : undefined;

  return (
    <div className={styles.twoCol}>
      <section className={`plate ${styles.col}`}>
        <p className="eyebrow">Today&apos;s commit</p>
        <h2 className={styles.boxTitle}>Start today&apos;s sentence</h2>
        <p className={styles.boxNote}>
          Hold at least one word and post a {formatEth(g.bondWei)} ETH
          bond — refunded the moment the sentence reveals. One draw per
          24 hours, for the whole collection.
        </p>
        <TxButton
          build={() => ({ address: be(), abi: bountyEngineAbi, functionName: "commit", value: g.bondWei })}
          disabled={!canCommit}
          disabledHint={hint}
          onConfirmed={refetch}
          confirmedLabel="Committed ✓"
        >
          Commit {formatEth(g.bondWei)} ETH &amp; start the draw
        </TxButton>
        <p className={styles.wiringNote}>
          Reveal lands ~{g.revealDelayBlocks} blocks later — and anyone may
          trigger it, so committing gives you no peek and no veto.
        </p>
      </section>

      <section className={`plate plate--flat ${styles.col}`}>
        <p className="eyebrow">The treasury</p>
        <p className={`mono ${styles.treasury}`}>{formatEth(g.freeTreasuryWei, 3)} ETH</p>
        <p className={styles.boxNote}>
          Fed by 25% of every swap fee. The draw picks a prize at random —
          but only among tiers the treasury can afford right now:
        </p>
        <ul className={styles.tierLadder}>
          {g.tiersWei.map((t, i) => {
            const ok = affordable.includes(t);
            return (
              <li key={i} className={ok ? styles.tierOk : styles.tierNo}>
                <span className="mono">{formatEth(t)} ETH</span>
                <span>{ok ? "in the draw" : "needs a richer treasury"}</span>
              </li>
            );
          })}
        </ul>
      </section>
    </div>
  );
}

/* ─────────────────────── committed ─────────────────────── */
function Committed({ g }: { g: GameState }) {
  const blocksLeft = Number(g.targetBlock - g.blockNumber);
  const secs = Math.max(0, blocksLeft * 12);
  return (
    <section className={`plate ${styles.bigBox}`}>
      <span className={styles.pulse} aria-hidden="true" />
      <h2 className={styles.boxTitle}>Sentence №{g.commitEventId} is committed</h2>
      <p className={styles.boxNote}>
        Committed by <span className="mono">{shortAddress(g.committer ?? "")}</span>.
        The entropy block hasn&apos;t been mined yet — no one alive knows what the
        sentence will say.
      </p>
      <div className={styles.countRow}>
        <div className={styles.countCell}>
          <span className="eyebrow">Blocks to reveal</span>
          <span className={`mono ${styles.countBig}`}>{Math.max(0, blocksLeft)}</span>
        </div>
        <div className={styles.countCell}>
          <span className="eyebrow">Roughly</span>
          <span className={`mono ${styles.countBig}`}>
            {Math.floor(secs / 60)}:{String(secs % 60).padStart(2, "0")}
          </span>
        </div>
        <div className={styles.countCell}>
          <span className="eyebrow">Target block</span>
          <span className={`mono ${styles.countBig}`}>{Number(g.targetBlock).toLocaleString("en-US")}</span>
        </div>
      </div>
      <p className={styles.wiringNote}>watching <span className="mono">currentCommit.targetBlock</span> vs the chain head</p>
    </section>
  );
}

/* ─────────────────────── revealable ─────────────────────── */
function Revealable({ g, refetch }: { g: GameState; refetch: () => void }) {
  const windowLeft = Number(g.targetBlock + BigInt(g.blockhashWindow) - g.blockNumber);
  const mins = Math.floor((windowLeft * 12) / 60);
  return (
    <section className={`plate ${styles.bigBox} ${styles.revealableBox}`}>
      <h2 className={styles.boxTitle}>Sentence №{g.commitEventId} is ready to reveal</h2>
      <p className={styles.boxNote}>
        The entropy block is sealed. <strong>Anyone</strong> can reveal — not
        just the committer — and the caller earns {g.revealRewardBps / 100}% of
        whatever bounty is drawn. That&apos;s the design: a sentence no one can suppress.
      </p>
      <TxButton
        build={() => ({ address: be(), abi: bountyEngineAbi, functionName: "reveal" })}
        onConfirmed={refetch}
        confirmedLabel="Revealed ✓"
      >
        Reveal the sentence
      </TxButton>
      <p className={styles.wiringNote}>
        window closes in ~{mins} min ({windowLeft} blocks) — after that the
        commit lapses and the bond forfeits
      </p>
    </section>
  );
}

/* ─────────────────────── expired ─────────────────────── */
function Expired({ refetch }: { g: GameState; refetch: () => void }) {
  return (
    <section className={`plate ${styles.bigBox} ${styles.expiredBox}`}>
      <h2 className={styles.boxTitle}>The commit lapsed unrevealed</h2>
      <p className={styles.boxNote}>
        Nobody revealed within the window, so the entropy block aged out. The
        committer&apos;s bond forfeits to the treasury — sulking is unprofitable by
        construction — and the next commit can begin as soon as the board is cleared.
      </p>
      <TxButton
        variant="btn--ghost"
        build={() => ({ address: be(), abi: bountyEngineAbi, functionName: "expireCommit" })}
        onConfirmed={refetch}
        confirmedLabel="Cleared ✓"
      >
        Clear the lapsed commit
      </TxButton>
    </section>
  );
}

/* ─────────────── revealed — the signature screen ─────────────── */
function Revealed({
  g,
  ev,
  connected,
  refetch,
}: {
  g: GameState;
  ev: RevealedSentence;
  connected: boolean;
  refetch: () => void;
}) {
  const yourIds = ev.words.filter((w) => w.claimable && w.yours).map((w) => w.tokenId);

  return (
    <section aria-labelledby="sentence-title">
      <div className={styles.stage}>
        <p className={styles.stageEyebrow}>Sentence №{ev.eventId}</p>
        <h2 id="sentence-title" className="visually-hidden">Today&apos;s sentence</h2>
        <div className={styles.sentence}>
          {ev.words.map((w, i) => (
            <span key={w.tokenId} className={styles.sentencePart}>
              {ev.fragments[i] ? <span className={styles.fragment}>{ev.fragments[i]}</span> : null}
              <Link href={`/gallery/${w.tokenId}`} className={styles.wordTile} title={`${w.word} — №${w.tokenId}`}>
                <TokenArt tokenId={w.tokenId} alt={w.word} />
              </Link>
            </span>
          ))}
          <span className={styles.fragment}>{ev.fragments[ev.fragments.length - 1]}</span>
        </div>
        <p className={styles.stageCaption}>
          drawn from {g.totalAlive.toLocaleString("en-US")} living words ·
          entropy from block hash · nobody chose this
        </p>
      </div>

      <div className={`plate ${styles.ledger}`}>
        <div className={styles.ledgerStats}>
          <div>
            <span className="eyebrow">Bounty drawn</span>
            <p className={`mono ${styles.ledgerBig}`}>{formatEth(ev.amountWei)} ETH</p>
          </div>
          <div>
            <span className="eyebrow">Per word</span>
            <p className={`mono ${styles.ledgerBig}`}>{formatEth(ev.sharePerWordWei)} ETH</p>
          </div>
          <div>
            <span className="eyebrow">Claims close</span>
            <p className={`mono ${styles.ledgerBig}`}>{timeRemaining(isoFromUnix(ev.deadline))}</p>
          </div>
        </div>

        <ul className={styles.claimList}>
          {ev.words.map((w) => (
            <li key={w.tokenId} className={styles.claimRow}>
              <span className={styles.claimWord}>
                {w.word}
                <span className={`mono ${styles.claimId}`}>№{w.tokenId}</span>
              </span>
              <span className={styles.claimStatus}>
                {w.claimed ? (
                  <span className={styles.claimedTag}>claimed ✓</span>
                ) : !w.alive ? (
                  <span className={styles.forfeitTag}>word unbound — share forfeits</span>
                ) : w.yours && w.claimable && connected ? (
                  <TxButton
                    build={() => ({
                      address: be(),
                      abi: bountyEngineAbi,
                      functionName: "claim",
                      args: [BigInt(ev.eventId), BigInt(w.tokenId)],
                    })}
                    onConfirmed={refetch}
                    confirmedLabel="Claimed ✓"
                  >
                    Claim {formatEth(ev.sharePerWordWei)} ETH
                  </TxButton>
                ) : (
                  <span className={styles.othersTag}>
                    {w.yours ? "yours — connect to claim" : `held by ${shortAddress(w.owner ?? "")}`}
                  </span>
                )}
              </span>
            </li>
          ))}
        </ul>

        {connected && yourIds.length > 1 ? (
          <div className={styles.claimAll}>
            <TxButton
              build={() => ({
                address: be(),
                abi: bountyEngineAbi,
                functionName: "claimMany",
                args: [BigInt(ev.eventId), yourIds.map((id) => BigInt(id))],
              })}
              onConfirmed={refetch}
              confirmedLabel="Claimed ✓"
            >
              Claim all your shares — {formatEth(ev.sharePerWordWei * BigInt(yourIds.length))} ETH
            </TxButton>
          </div>
        ) : null}

        <p className={styles.wiringNote}>
          ownership checked at claim time — buy a drawn word before the
          deadline and its share is yours · unclaimed remainders return to
          the treasury via <span className="mono">sweep(eventId)</span>
        </p>
      </div>
    </section>
  );
}

/* ─────────────────────── history ─────────────────────── */
function History({ rows, now, refetch }: { rows: HistoryRow[]; now: number; refetch: () => void }) {
  if (rows.length === 0) {
    return (
      <section className={styles.history}>
        <h2 className={styles.historyTitle}>Past sentences</h2>
        <p className={styles.boxNote}>
          None yet — the first sentence writes itself the day the game opens.
        </p>
      </section>
    );
  }
  return (
    <section className={styles.history}>
      <h2 className={styles.historyTitle}>Past sentences</h2>
      <ol className={styles.historyList}>
        {rows.map((ev) => (
          <HistoryRowView key={ev.eventId} ev={ev} now={now} refetch={refetch} />
        ))}
      </ol>
    </section>
  );
}

function HistoryRowView({ ev, now, refetch }: { ev: HistoryRow; now: number; refetch: () => void }) {
  const deadlinePassed = now >= ev.deadline;
  const status = ev.swept
    ? { label: "swept", tone: styles.statusSwept }
    : deadlinePassed
      ? { label: "claims closed", tone: styles.statusDone }
      : { label: "open", tone: styles.statusOpen };
  return (
    <li className={styles.historyRow}>
      <div className={styles.historyMain}>
        <span className={`mono ${styles.historyId}`}>№{ev.eventId}</span>
        <p className={styles.historySentence}>
          {ev.words.map((w, i) => (
            <span key={w.tokenId}>
              {ev.fragments[i]}
              <Link href={`/gallery/${w.tokenId}`} className={styles.historyWord}>
                {w.word}
              </Link>
            </span>
          ))}
          {ev.fragments[ev.fragments.length - 1]}
        </p>
      </div>
      <div className={styles.historyMeta}>
        <span className="mono">{formatEth(ev.amountWei)} ETH</span>
        <span className={`${styles.statusChip} ${status.tone}`}>{status.label}</span>
        {deadlinePassed && !ev.swept ? (
          <TxButton
            variant="btn--ghost"
            build={() => ({ address: be(), abi: bountyEngineAbi, functionName: "sweep", args: [BigInt(ev.eventId)] })}
            onConfirmed={refetch}
            confirmedLabel="Swept ✓"
          >
            Sweep
          </TxButton>
        ) : null}
      </div>
    </li>
  );
}
