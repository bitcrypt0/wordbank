"use client";

import { useState } from "react";
import Link from "next/link";
import { useMintData, PHASE } from "@/lib/reads/mint";
import { requireAddress } from "@/lib/contracts/addresses";
import { wordBankAbi } from "@/lib/contracts/abis";
import {
  Meter,
  TxButton,
  ErrorState,
  PendingState,
} from "@/components/ui";
import { LaunchStatus } from "@/components/LaunchStatus";
import { WordbankGlyph } from "@/components/Logo";
import { formatEth, formatInt } from "@/lib/format";
import styles from "./mint.module.css";

/** Per-transaction UI limit for the public phase (not a contract bound). */
const PUBLIC_TX_LIMIT = 20;

export default function MintPage() {
  const { data: s, status, refetch } = useMintData();
  const [qty, setQty] = useState(1);

  if (status === "pending") {
    return (
      <Shell>
        <PendingState />
      </Shell>
    );
  }
  if (status === "error" || (status === "loaded" && !s)) {
    return (
      <Shell>
        <ErrorState
          hint="The sale state couldn't be read. Nothing is wrong with the sale itself — try again."
          onRetry={refetch}
        />
      </Shell>
    );
  }

  const loading = status === "loading" || !s;

  // Derive the displayed state from the live phase + sellout (HANDOFF §3).
  const isEarly = s?.phase === PHASE.EarlyBird;
  const isPublic = s?.phase === PHASE.PublicSale;
  const publicSold = s ? s.earlyBirdMinted + s.publicMinted : 0;
  const soldOut = s ? publicSold >= s.publicSupply : false;
  const notOpen = !isEarly && !isPublic && !soldOut;

  const priceWei = s ? (isEarly ? s.earlyBirdPriceWei : s.publicPriceWei) : 0n;
  const capLeft = s ? s.earlyBirdWalletCap - s.yourEarlyBirdMinted : 0;
  const maxQty = isEarly ? Math.max(capLeft, 0) : PUBLIC_TX_LIMIT;
  const clampedQty = Math.min(Math.max(qty, 1), Math.max(maxQty, 1));
  const totalWei = priceWei * BigInt(clampedQty);
  const totalMinted = s ? publicSold + s.adminMinted : 0;

  return (
    <Shell>
      <div className={styles.layout}>
        {/* ── The mint card ── */}
        <section
          className={`plate ${styles.card} ${loading ? "skeleton" : ""}`}
          aria-busy={loading}
        >
          {notOpen ? (
            <div className={styles.closedBox}>
              <WordbankGlyph size={40} />
              <h2 className={styles.cardTitle}>The sale hasn&apos;t opened yet</h2>
              <p className={styles.cardNote}>
                Early bird opens first: {s ? formatEth(s.earlyBirdPriceWei) : "—"} ETH
                per word, at most {s?.earlyBirdWalletCap ?? "—"} per wallet. The
                public phase follows at {s ? formatEth(s.publicPriceWei) : "—"} ETH
                with no cap.
              </p>
            </div>
          ) : soldOut ? (
            <div className={styles.closedBox}>
              <span className={styles.soldMark} aria-hidden="true">
                ✓
              </span>
              <h2 className={styles.cardTitle}>
                Sold out — all {s ? formatInt(s.publicSupply) : "9,800"} public words minted
              </h2>
              <p className={styles.cardNote}>
                The provenance offset is fixed: every word now knows its
                tokenId, and reveals are live. The remaining 200 are the
                admin reserve, backed identically.
              </p>
              <Link href="/gallery" className="btn">
                See the revealed collection
              </Link>
            </div>
          ) : (
            <>
              <div className={styles.phaseRow}>
                <span
                  className="badge"
                  style={{ color: isEarly ? "var(--teal)" : "var(--indigo)" }}
                >
                  {isEarly ? "Early bird — phase 1 of 2" : "Public sale — phase 2 of 2"}
                </span>
                <span className={`mono ${styles.price}`}>
                  {formatEth(priceWei)} ETH <span className={styles.per}>/ word</span>
                </span>
              </div>

              {/* quantity picker */}
              <div className={styles.qtyRow}>
                <span className="eyebrow">Quantity</span>
                <div className={styles.qty}>
                  <button
                    type="button"
                    className={styles.qtyBtn}
                    aria-label="Fewer"
                    disabled={clampedQty <= 1}
                    onClick={() => setQty(clampedQty - 1)}
                  >
                    −
                  </button>
                  <output className={`mono ${styles.qtyValue}`}>{clampedQty}</output>
                  <button
                    type="button"
                    className={styles.qtyBtn}
                    aria-label="More"
                    disabled={clampedQty >= maxQty}
                    onClick={() => setQty(clampedQty + 1)}
                  >
                    +
                  </button>
                </div>
                {isPublic ? (
                  <span className={styles.qtyNote}>up to {PUBLIC_TX_LIMIT} per transaction</span>
                ) : null}
              </div>

              {/* early-bird wallet cap meter */}
              {isEarly && s ? (
                <div className={styles.capBox}>
                  <Meter
                    label="Your early-bird cap"
                    value={s.yourEarlyBirdMinted}
                    max={s.earlyBirdWalletCap}
                    detail={`${s.yourEarlyBirdMinted} of ${s.earlyBirdWalletCap} used`}
                    tone={capLeft === 0 ? "danger" : "ok"}
                  />
                  <p className={styles.capNote}>
                    {capLeft > 0
                      ? `You can mint ${capLeft} more in this phase. The cap resets for no one — it ends with the phase.`
                      : "Cap reached — your wallet sits out the rest of early bird. The public phase has no cap."}
                  </p>
                </div>
              ) : null}

              <div className={styles.totalRow}>
                <span>Total</span>
                <span className="mono">{formatEth(totalWei)} ETH</span>
              </div>

              <TxButton
                build={() => ({
                  address: requireAddress("wordBank"),
                  abi: wordBankAbi,
                  functionName: isEarly ? "earlyBirdMint" : "publicMint",
                  args: [BigInt(clampedQty)],
                  value: totalWei,
                })}
                disabled={isEarly && capLeft === 0}
                disabledHint={
                  isEarly && capLeft === 0 ? "Early-bird cap reached." : undefined
                }
                onConfirmed={refetch}
                confirmedLabel="Minted ✓"
              >
                Mint {clampedQty} word{clampedQty > 1 ? "s" : ""}
              </TxButton>

              <p className={styles.mintFootnote}>
                Each mint: NFT + 1,000 WORD bound to it + registration for
                rewards and the daily game. No reveal gambling — traits fix
                for everyone at once when the collection sells out.
              </p>
            </>
          )}
        </section>

        {/* ── Supply & provenance ── */}
        <aside className={styles.side}>
          <div className={`plate plate--flat ${styles.sideBox}`}>
            <Meter
              label="Early bird"
              value={s?.earlyBirdMinted ?? 0}
              max={s?.earlyBirdAllocation || 1}
              detail={`${formatInt(s?.earlyBirdMinted ?? 0)} / ${formatInt(s?.earlyBirdAllocation ?? 0)}`}
              tone={s && s.earlyBirdMinted >= s.earlyBirdAllocation ? "ok" : "ink"}
            />
            <Meter
              label="Public sale"
              value={s?.publicMinted ?? 0}
              max={s?.publicAllocation || 1}
              detail={`${formatInt(s?.publicMinted ?? 0)} / ${formatInt(s?.publicAllocation ?? 0)}`}
              tone={s && s.publicMinted >= s.publicAllocation ? "ok" : "ink"}
            />
            <Meter
              label="Toward the provenance reveal"
              value={publicSold}
              max={s?.publicSupply || 1}
              detail={`${formatInt(publicSold)} / ${formatInt(s?.publicSupply ?? 0)}`}
              tone="gold"
            />
            <p className={styles.sideNote}>
              When the 9,800 public words sell out, a commit-reveal fixes the
              global offset and every token learns its word and traits — all
              at once, snipe-proof. The 200-word admin reserve can mint any
              time but never moves this trigger.
            </p>
            <p className={`mono ${styles.sideTotal}`}>
              {formatInt(totalMinted)} / {formatInt(s?.maxSupply ?? 0)} minted in total
            </p>
          </div>

          {/* unrevealed token state — shown while offset is not yet set */}
          {!s?.offsetSet ? (
            <div className={`plate plate--flat ${styles.sideBox}`}>
              <p className="eyebrow">Before the reveal</p>
              <div className={styles.unrevealedRow}>
                <UnrevealedPlate />
                <p className={styles.sideNote}>
                  Until the offset is fixed, every minted token looks like
                  this: sealed. No one — including the team — can know which
                  word or traits any tokenId holds. What&apos;s already yours is
                  the backing: 1,000 WORD, bound from the first block.
                </p>
              </div>
            </div>
          ) : null}
        </aside>
      </div>

      <hr className="rule" />

      {/* Public, permissionless launch liveness — reveal / re-arm / build registry */}
      <LaunchStatus />
    </Shell>
  );
}

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <div className="container">
      <header className={styles.head}>
        <p className="eyebrow">The sale</p>
        <h1 className={styles.title}>Mint</h1>
        <p className={styles.lede}>
          10,000 words, two phases. Every mint binds 1,000 WORD to the new
          token before it reaches your wallet — the backing is part of the
          mint, not a promise after it.
        </p>
      </header>
      {children}
    </div>
  );
}

/** The pre-reveal token: a sealed specimen plate. */
function UnrevealedPlate() {
  return (
    <svg
      viewBox="0 0 200 200"
      className={styles.unrevealed}
      role="img"
      aria-label="Unrevealed token"
    >
      <rect width="200" height="200" rx="4" fill="var(--ink)" />
      <rect
        x="10"
        y="10"
        width="180"
        height="180"
        rx="3"
        fill="none"
        stroke="var(--paper)"
        strokeWidth="1"
        opacity="0.3"
      />
      <text
        x="100"
        y="96"
        textAnchor="middle"
        fill="var(--paper)"
        style={{ font: "500 34px var(--font-serif)", letterSpacing: "0.4em" }}
      >
        · · ·
      </text>
      <text
        x="100"
        y="132"
        textAnchor="middle"
        fill="var(--paper-fleck)"
        style={{
          font: "600 11px var(--font-serif)",
          letterSpacing: "0.22em",
          textTransform: "uppercase",
        }}
      >
        UNREVEALED
      </text>
    </svg>
  );
}
