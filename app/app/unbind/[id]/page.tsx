"use client";

import { useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useUnbindToken } from "@/lib/reads/unbind";
import { useWallet } from "@/lib/wallet/WalletProvider";
import { requireAddress } from "@/lib/contracts/addresses";
import { wordBankAbi } from "@/lib/contracts/abis";
import { TokenArt } from "@/components/TokenArt";
import { EmptyState, ErrorState, PendingState, TxButton } from "@/components/ui";
import { formatEth, formatWord, timeRemaining } from "@/lib/format";
import { isoFromUnix } from "@/lib/reads/bounties";
import styles from "./unbind.module.css";

/**
 * The unbind flow — deliberately the slowest path in the product.
 * Four gates: read → acknowledge each consequence → type the word → act.
 * This is the only way backing ever leaves the vault, and it is forever.
 */
export default function UnbindPage() {
  const params = useParams<{ id: string }>();
  const tokenId = Number(params.id);
  const { account } = useWallet();
  const { data: token, status, refetch } = useUnbindToken(tokenId);

  const [step, setStep] = useState(0);
  const [acks, setAcks] = useState([false, false, false, false]);
  const [typed, setTyped] = useState("");
  // Snapshot of the settled amounts, captured the moment the tx confirms.
  const [receipt, setReceipt] = useState<{
    rewardsWei: bigint;
    backingWei: bigint;
    bountyEventIds: number[];
  } | null>(null);

  if (status === "pending") {
    return (
      <div className="container" style={{ paddingBlock: "var(--space-8)" }}>
        <PendingState />
      </div>
    );
  }
  if (status === "loading" || !token) {
    return (
      <div className="container" style={{ paddingBlock: "var(--space-8)" }}>
        {status === "error" ? (
          <ErrorState hint="Couldn't read this token — try again." onRetry={refetch} />
        ) : (
          <div className="skeleton" style={{ height: 240, borderRadius: 12 }} />
        )}
      </div>
    );
  }

  if (!token.exists) {
    return (
      <div className="container" style={{ paddingBlock: "var(--space-8)" }}>
        <EmptyState
          title={`No word at №${params.id}`}
          hint="Nothing to unbind — that tokenId doesn't exist."
        />
      </div>
    );
  }

  if (!token.alive && step !== 3) {
    return (
      <div className="container" style={{ paddingBlock: "var(--space-8)" }}>
        <EmptyState
          title={`№${token.tokenId} is already unbound`}
          hint="This word was burned and its backing released. Unbinding happens once."
        />
        <p style={{ marginTop: "var(--space-4)" }}>
          <Link href="/gallery">← Back to the gallery</Link>
        </p>
      </div>
    );
  }

  const hasBounty = token.bounties.length > 0;
  const firstBounty = token.bounties[0];
  const requiredAcks = hasBounty ? 4 : 3;
  const allAcked = acks.slice(0, requiredAcks).every(Boolean);
  const wordMatches = typed.trim().toLowerCase() === token.word.toLowerCase();
  const notOwner = !!account && !token.isOwner;

  const stepLabels = ["What this does", "Acknowledge", "Confirm", "Done"];

  return (
    <div className={`container ${styles.page}`}>
      <nav className={styles.crumbs} aria-label="Breadcrumb">
        <Link href={`/gallery/${token.tokenId}`}>№{token.tokenId}</Link>
        <span aria-hidden="true"> / </span>
        <span>Unbind</span>
      </nav>

      <ol className={styles.stepper} aria-label="Unbind progress">
        {stepLabels.map((label, i) => (
          <li
            key={label}
            className={`${styles.step} ${i === step ? styles.stepActive : ""} ${
              i < step ? styles.stepDone : ""
            }`}
            aria-current={i === step ? "step" : undefined}
          >
            <span className={styles.stepNum}>{i < step ? "✓" : i + 1}</span>
            {label}
          </li>
        ))}
      </ol>

      <div className={styles.layout}>
        <figure className={styles.art}>
          <TokenArt tokenId={token.tokenId} alt={token.word} />
          {step < 3 ? (
            <figcaption className={styles.artCaption}>
              {token.word} — №{token.tokenId}. Still alive, still yours.
            </figcaption>
          ) : (
            <figcaption className={`${styles.artCaption} ${styles.artGone}`}>
              {token.word} — №{token.tokenId}. Burned. The word leaves the
              collection forever.
            </figcaption>
          )}
        </figure>

        <div className={styles.flow}>
          {step === 0 ? (
            <section className={styles.panel}>
              <h1 className={styles.title}>Unbind &ldquo;{token.word}&rdquo;</h1>
              <p className={styles.note}>
                Unbinding trades the artwork for its backing. In one
                transaction, in this order:
              </p>
              <ol className={styles.sequence}>
                <li>
                  <strong>Your pending rewards settle now.</strong>{" "}
                  {formatEth(token.pendingRewardsWei)} ETH pays out to you in
                  the same transaction — nothing is stranded.
                </li>
                <li>
                  <strong>The NFT burns, forever.</strong> №{token.tokenId} is
                  removed from the living registry. It can never be re-minted
                  by anyone. The collection shrinks by one.
                </li>
                <li>
                  <strong>1,000 WORD release to your wallet.</strong> The
                  backing becomes ordinary, liquid tokens.
                </li>
              </ol>
              {notOwner ? (
                <p className={styles.wiring} role="alert">
                  This token isn&apos;t in the connected wallet — only its owner can
                  unbind it.
                </p>
              ) : null}
              <div className={styles.row}>
                <button
                  type="button"
                  className="btn btn--danger"
                  disabled={notOwner}
                  onClick={() => setStep(1)}
                >
                  I want to continue
                </button>
                <Link href={`/gallery/${token.tokenId}`} className="btn btn--ghost">
                  Keep the word
                </Link>
              </div>
            </section>
          ) : step === 1 ? (
            <section className={styles.panel}>
              <h1 className={styles.title}>Acknowledge each consequence</h1>
              {hasBounty && firstBounty ? (
                <div className={styles.bountyWarn} role="alert">
                  <p className={styles.bountyWarnTitle}>
                    ⚠ This word holds an unclaimed bounty share
                  </p>
                  <p className={styles.bountyWarnNote}>
                    &ldquo;{token.word}&rdquo; appeared in sentence №{firstBounty.eventId} and
                    its {formatEth(firstBounty.sharePerWordWei)} ETH share is
                    still unclaimed ({timeRemaining(isoFromUnix(firstBounty.deadline))}).
                    Unbinding forfeits it permanently — it returns to the
                    treasury, never to you.{" "}
                    <Link href="/game">Claim it first</Link> unless you mean to
                    abandon it.
                  </p>
                </div>
              ) : null}
              <div className={styles.acks}>
                {[
                  `The NFT “${token.word}” (№${token.tokenId}) is burned permanently. No one can ever bring it back.`,
                  "All future bounty chances and fee rewards for this word end. Survivors split future fees among fewer words.",
                  "The 1,000 WORD I receive are ordinary tokens — they carry no art, no game odds, no fee share.",
                  ...(hasBounty && firstBounty
                    ? [
                        `I forfeit the unclaimed ${formatEth(firstBounty.sharePerWordWei)} ETH bounty share from sentence №${firstBounty.eventId}.`,
                      ]
                    : []),
                ].map((text, i) => (
                  <label key={i} className={styles.ack}>
                    <input
                      type="checkbox"
                      checked={acks[i]}
                      onChange={(e) =>
                        setAcks((a) => a.map((v, j) => (j === i ? e.target.checked : v)))
                      }
                    />
                    <span>{text}</span>
                  </label>
                ))}
              </div>
              <div className={styles.row}>
                <button
                  type="button"
                  className="btn btn--danger"
                  disabled={!allAcked}
                  onClick={() => setStep(2)}
                >
                  Continue
                </button>
                <button type="button" className="btn btn--ghost" onClick={() => setStep(0)}>
                  Back
                </button>
              </div>
            </section>
          ) : step === 2 ? (
            <section className={styles.panel}>
              <h1 className={styles.title}>Final confirmation</h1>
              <p className={styles.note}>
                Type the word itself to arm the transaction. This is the
                point of no return.
              </p>
              <label className={styles.typeLabel} htmlFor="unbind-word">
                Type <span className="mono">{token.word}</span>
              </label>
              <input
                id="unbind-word"
                className={`mono ${styles.typeInput}`}
                value={typed}
                onChange={(e) => setTyped(e.target.value)}
                autoComplete="off"
                spellCheck={false}
              />
              <div className={styles.row}>
                <TxButton
                  variant="btn--danger"
                  build={() => ({
                    address: requireAddress("wordBank"),
                    abi: wordBankAbi,
                    functionName: "unbind",
                    args: [BigInt(token.tokenId)],
                  })}
                  disabled={!wordMatches}
                  disabledHint={!wordMatches ? "Type the word exactly to arm it." : undefined}
                  onConfirmed={() => {
                    setReceipt({
                      rewardsWei: token.pendingRewardsWei,
                      backingWei: token.bondedBalanceWei,
                      bountyEventIds: token.bounties.map((b) => b.eventId),
                    });
                    setStep(3);
                    refetch();
                  }}
                  confirmedLabel="Unbound ✓"
                >
                  Unbind №{token.tokenId} — forever
                </TxButton>
                <button type="button" className="btn btn--ghost" onClick={() => setStep(1)}>
                  Back
                </button>
              </div>
            </section>
          ) : (
            <section className={styles.panel} aria-live="polite">
              <h1 className={styles.title}>Unbound.</h1>
              <p className={styles.note}>
                The transaction settled everything at once — the receipt:
              </p>
              <dl className={styles.receipt}>
                <div>
                  <dt>Rewards force-settled to you</dt>
                  <dd className="mono">{formatEth(receipt?.rewardsWei ?? 0n)} ETH</dd>
                </div>
                <div>
                  <dt>Backing released to you</dt>
                  <dd className="mono">{formatWord(receipt?.backingWei ?? 0n)} WORD</dd>
                </div>
                <div>
                  <dt>
                    NFT №{token.tokenId} &ldquo;{token.word}&rdquo;
                  </dt>
                  <dd className={styles.burned}>burned — permanent</dd>
                </div>
                {receipt && receipt.bountyEventIds.length > 0 ? (
                  <div>
                    <dt>Bounty share №{receipt.bountyEventIds[0]}</dt>
                    <dd className={styles.burned}>forfeited to the treasury</dd>
                  </div>
                ) : null}
              </dl>
              <p className={styles.note}>
                Every surviving word&apos;s share of future fees just grew. That&apos;s
                the design — leaving concentrates the game for those who stay.
              </p>
              <div className={styles.row}>
                <Link href="/gallery" className="btn">
                  Back to the gallery
                </Link>
              </div>
            </section>
          )}
        </div>
      </div>
    </div>
  );
}
