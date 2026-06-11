"use client";

import { useState } from "react";
import Link from "next/link";
import { requireAddress } from "@/lib/contracts/addresses";
import { wordBankAbi } from "@/lib/contracts/abis";
import { useWrite } from "@/lib/hooks/useWrite";
import { useWallet } from "@/lib/wallet/WalletProvider";
import { formatEth, formatWord } from "@/lib/format";
import type { RewardRow } from "@/lib/reads/rewards";
import styles from "./rewards.module.css";

/**
 * Batch unbind — the irreversibility-parity gate.
 *
 * Single-token unbind is a deliberate 4-gate flow (read → acknowledge each →
 * type the word → act) because it burns the NFT forever, force-settles rewards,
 * and FORFEITS any unclaimed bounty share. A batch can't ask the holder to type
 * N words, so this carries comparable friction:
 *   1. A danger-styled trigger (never auto-armed; visually separated from Claim).
 *   2. A confirm panel that lists EXACTLY which words/№ids burn, the total WORD
 *      released, and the total pending rewards force-settled — so nothing reads
 *      as stranded.
 *   3. A PROMINENT bounty-forfeit warning naming the specific words that hold an
 *      unclaimed share (or a strong generic warning + /game link when the scan
 *      couldn't confirm), with a link to claim first.
 *   4. An explicit acknowledgement checkbox.
 *   5. A type-to-confirm keystroke gate: the holder must type `UNBIND <N>`.
 * Only then does the final button arm and call `unbindMany(selectedIds)`.
 */
export function BatchUnbindConfirm({
  rows,
  bountyScanComplete,
  onConfirmed,
}: {
  rows: RewardRow[];
  /** False → the bounty scan couldn't confirm; show a generic forfeiture warning. */
  bountyScanComplete: boolean;
  onConfirmed: () => void;
}) {
  const { account } = useWallet();
  const [open, setOpen] = useState(false);
  const [understood, setUnderstood] = useState(false);
  const [typed, setTyped] = useState("");
  const { state, error, execute, reset } = useWrite(() => {
    onConfirmed();
    close();
  });

  const count = rows.length;
  const ids = rows.map((r) => r.tokenId);
  const totalPending = rows.reduce((acc, r) => acc + r.pendingWei, 0n);
  const totalBacking = rows.reduce((acc, r) => acc + r.backingWei, 0n);
  const bountyRows = rows.filter((r) => r.hasBounty);
  const totalBountyForfeit = bountyRows.reduce((acc, r) => acc + r.bountyShareWei, 0n);

  const confirmPhrase = `UNBIND ${count}`;
  const phraseMatches = typed.trim().toUpperCase() === confirmPhrase;
  const armed = understood && phraseMatches && count > 0;
  const busy = state === "simulating" || state === "pending" || state === "confirming";

  function close() {
    setOpen(false);
    setUnderstood(false);
    setTyped("");
    reset();
  }

  // Disabled trigger (with a hint) when nothing is selected or no wallet.
  if (!open) {
    const disabled = count === 0;
    return (
      <span className={styles.unbindTriggerWrap}>
        <button
          type="button"
          className="btn btn--danger"
          disabled={disabled}
          onClick={() => setOpen(true)}
        >
          Unbind selected
        </button>
        {disabled ? (
          <span className={styles.txHintInline}>Select at least one word to unbind.</span>
        ) : null}
      </span>
    );
  }

  return (
    <div
      className={styles.unbindPanel}
      role="group"
      aria-label={`Confirm batch unbind of ${count} ${count === 1 ? "word" : "words"}`}
    >
      <p className={styles.unbindWarnTitle}>
        🔒 Unbind {count} {count === 1 ? "word" : "words"} — this can never be undone.
      </p>
      <p className={styles.unbindIntro}>
        In one transaction, each selected word&apos;s NFT is{" "}
        <strong>burned forever</strong>, its pending rewards settle to you, and
        its 1,000 WORD backing releases to your wallet. The collection shrinks by{" "}
        {count}.
      </p>

      {/* Exactly which words/ids burn. */}
      <ul className={styles.unbindList}>
        {rows.map((r) => (
          <li key={r.tokenId} className={styles.unbindItem}>
            <span className={styles.unbindItemWord}>{r.word}</span>
            <span className={`mono ${styles.unbindItemId}`}>№{r.tokenId}</span>
            {r.hasBounty ? (
              <span className={styles.unbindItemBounty} title="Unclaimed bounty share — forfeited on unbind">
                ◆ forfeits {formatEth(r.bountyShareWei)} ETH bounty
              </span>
            ) : null}
          </li>
        ))}
      </ul>

      {/* Totals — so nothing reads as stranded. */}
      <dl className={styles.unbindTotals}>
        <div>
          <dt>NFTs burned</dt>
          <dd className="mono">{count}</dd>
        </div>
        <div>
          <dt>Backing released to you</dt>
          <dd className="mono">{formatWord(totalBacking)} WORD</dd>
        </div>
        <div>
          <dt>Pending rewards force-settled to you</dt>
          <dd className="mono">{formatEth(totalPending)} ETH</dd>
        </div>
      </dl>

      {/* Bounty-forfeit warning — the part that must never be silent. */}
      {bountyRows.length > 0 ? (
        <div className={styles.unbindBountyWarn} role="alert">
          <p className={styles.unbindBountyTitle}>
            ⚠ {bountyRows.length} of these selected{" "}
            {bountyRows.length === 1 ? "words holds" : "words hold"} an unclaimed
            bounty share
          </p>
          <p className={styles.unbindBountyNote}>
            Unbinding forfeits {formatEth(totalBountyForfeit)} ETH of bounty
            permanently — it returns to the treasury, never to you:{" "}
            <strong>{bountyRows.map((r) => `${r.word} (№${r.tokenId})`).join(", ")}</strong>.{" "}
            <Link href="/game">Claim those bounties first</Link> unless you mean to
            abandon them.
          </p>
        </div>
      ) : !bountyScanComplete ? (
        <div className={styles.unbindBountyWarn} role="alert">
          <p className={styles.unbindBountyTitle}>
            ⚠ Bounty shares couldn&apos;t be verified for this selection
          </p>
          <p className={styles.unbindBountyNote}>
            The network couldn&apos;t confirm whether any selected word holds an
            unclaimed bounty share. Unbinding a word with one{" "}
            <strong>forfeits it to the treasury, permanently.</strong> Review each
            word and{" "}
            <Link href="/game">claim any open bounties first on the game console</Link>{" "}
            before continuing.
          </p>
        </div>
      ) : null}

      <label className={styles.unbindAck}>
        <input
          type="checkbox"
          checked={understood}
          onChange={(e) => setUnderstood(e.target.checked)}
        />
        <span>
          I understand these {count} {count === 1 ? "NFT is" : "NFTs are"} burned
          permanently and any unclaimed bounty shares are forfeited forever.
        </span>
      </label>

      <label className={styles.unbindTypeLabel} htmlFor="batch-unbind-confirm">
        Type <span className="mono">{confirmPhrase}</span> to arm the action
      </label>
      <input
        id="batch-unbind-confirm"
        className={`mono ${styles.unbindTypeInput}`}
        value={typed}
        onChange={(e) => setTyped(e.target.value)}
        autoComplete="off"
        spellCheck={false}
        placeholder={confirmPhrase}
      />

      <div className={styles.unbindRow}>
        <button
          type="button"
          className="btn btn--danger"
          disabled={!armed || busy || !account}
          aria-busy={busy}
          onClick={() => {
            void execute({
              address: requireAddress("wordBank"),
              abi: wordBankAbi,
              functionName: "unbindMany",
              args: [ids.map((id) => BigInt(id))],
            });
          }}
        >
          {busy
            ? state === "pending"
              ? "Confirm in wallet…"
              : state === "confirming"
                ? "Confirming…"
                : "Checking…"
            : `Unbind ${count} — forever`}
        </button>
        <button type="button" className="btn btn--ghost" disabled={busy} onClick={close}>
          Cancel
        </button>
      </div>

      {!account ? (
        <p className={styles.unbindWiring} role="alert">
          Connect your wallet to unbind.
        </p>
      ) : state === "error" && error ? (
        <p className={styles.unbindWiring} role="alert" style={{ color: "var(--danger)" }}>
          {error}
        </p>
      ) : (
        <p className={styles.unbindWiring}>
          calls <span className="mono">unbindMany([{ids.join(", ")}])</span> — reverts
          atomically if any word isn&apos;t in this wallet.
        </p>
      )}
    </div>
  );
}
