"use client";

import { useEffect, type ReactNode } from "react";
import { TIERS, TIER_COLOR_VAR, MATERIALS } from "@/lib/art";
import { useWallet } from "@/lib/wallet/WalletProvider";
import { useWrite, type WriteConfig } from "@/lib/hooks/useWrite";
import { etherscanTxUrl } from "@/lib/contracts/explorer";
import styles from "./ui.module.css";

/** Rarity tier chip — aesthetic flex only; the copy never implies gameplay. */
export function TierBadge({ material }: { material: number }) {
  const tier = TIERS[MATERIALS[material].tier];
  return (
    <span className="badge" style={{ color: TIER_COLOR_VAR[tier] }}>
      {tier}
    </span>
  );
}

export function HonorsBadge() {
  return (
    <span
      className="badge"
      style={{ color: "var(--gold)", background: "rgba(201,162,39,0.12)" }}
    >
      ✦ Honors 1/1
    </span>
  );
}

/** Labeled figure for stat strips. Values set in mono so digits align. */
export function Stat({
  label,
  value,
  detail,
  tone,
}: {
  label: string;
  value: ReactNode;
  detail?: string;
  tone?: "ok" | "danger";
}) {
  return (
    <div className={styles.stat}>
      <div className="eyebrow">{label}</div>
      <div
        className={`${styles.statValue} mono`}
        style={
          tone ? { color: `var(--${tone === "ok" ? "ok" : "danger"})` } : undefined
        }
      >
        {value}
      </div>
      {detail ? <div className={styles.statDetail}>{detail}</div> : null}
    </div>
  );
}

/** Designed empty state — a quiet specimen plate, never a blank div. */
export function EmptyState({
  title,
  hint,
}: {
  title: string;
  hint?: string;
}) {
  return (
    <div className={`well ${styles.stateBox}`} role="status">
      <span className={styles.stateGlyph} aria-hidden="true">
        ∅
      </span>
      <p className={styles.stateTitle}>{title}</p>
      {hint ? <p className={styles.stateHint}>{hint}</p> : null}
    </div>
  );
}

/** Pre-deployment state: contracts not yet published on this network. */
export function PendingState({
  title = "Not live on-chain yet",
  hint = "The WORDBANK contracts publish at deployment. This page goes live the moment they're on-chain.",
}: {
  title?: string;
  hint?: string;
}) {
  return (
    <div className={`well ${styles.stateBox}`} role="status">
      <span className={styles.stateGlyph} aria-hidden="true">
        ◷
      </span>
      <p className={styles.stateTitle}>{title}</p>
      <p className={styles.stateHint}>{hint}</p>
    </div>
  );
}

/** Designed error state with a retry affordance (wired by agent 9). */
export function ErrorState({
  title = "Couldn't reach the chain",
  hint = "The read failed or timed out. Nothing is wrong with your tokens — try again.",
  onRetry,
}: {
  title?: string;
  hint?: string;
  onRetry?: () => void;
}) {
  return (
    <div className={`well ${styles.stateBox} ${styles.stateError}`} role="alert">
      <span className={styles.stateGlyph} aria-hidden="true">
        ⚠
      </span>
      <p className={styles.stateTitle}>{title}</p>
      <p className={styles.stateHint}>{hint}</p>
      <button type="button" className="btn btn--ghost" onClick={onRetry}>
        Retry
      </button>
    </div>
  );
}

/**
 * Progress meter — supply, caps, registry build. Optional marker (e.g. the
 * burn floor or the 9,800 provenance trigger) rendered as a tick + label.
 */
export function Meter({
  value,
  max,
  label,
  detail,
  marker,
  tone = "ink",
}: {
  value: number;
  max: number;
  label: string;
  detail?: string;
  marker?: { at: number; label: string };
  tone?: "ink" | "ok" | "danger" | "gold";
}) {
  const pct = Math.max(0, Math.min(100, (value / max) * 100));
  const toneVar =
    tone === "ok"
      ? "var(--teal)"
      : tone === "danger"
        ? "var(--crimson)"
        : tone === "gold"
          ? "var(--gold-leaf)"
          : "var(--ink)";
  return (
    <div className={styles.meter}>
      <div className={styles.meterHead}>
        <span className="eyebrow">{label}</span>
        {detail ? <span className={styles.meterDetail}>{detail}</span> : null}
      </div>
      <div
        className={styles.meterTrack}
        role="progressbar"
        aria-valuenow={value}
        aria-valuemin={0}
        aria-valuemax={max}
        aria-label={label}
      >
        <div className={styles.meterFill} style={{ width: `${pct}%`, background: toneVar }} />
        {marker ? (
          <span
            className={styles.meterMark}
            style={{ left: `${(marker.at / max) * 100}%` }}
            title={marker.label}
          />
        ) : null}
      </div>
      {marker ? <p className={styles.meterMarkLabel}>▲ {marker.label}</p> : null}
    </div>
  );
}

/**
 * Real transaction button. Builds its WriteConfig lazily on click, runs the
 * full simulate → sign → confirm lifecycle (useWrite), and shows explicit
 * pending/confirmed/failed states with decoded custom-error copy. Gated on a
 * connected, right-network wallet.
 */
export function TxButton({
  children,
  build,
  variant = "",
  disabled = false,
  disabledHint,
  onConfirmed,
  confirmedLabel = "Done ✓",
}: {
  children: ReactNode;
  /** Returns the call to make, or null to no-op (e.g. validation failed). */
  build: () => WriteConfig | null;
  variant?: "" | "btn--ghost" | "btn--danger";
  disabled?: boolean;
  /** Why the button is disabled (shown as a quiet hint). */
  disabledHint?: string;
  onConfirmed?: () => void;
  confirmedLabel?: string;
}) {
  const { account, wrongNetwork, switchToMainnet } = useWallet();
  const { state, error, txHash, execute, reset } = useWrite(onConfirmed);

  // After a confirmed tx, briefly show "Confirmed" then auto-reset so the button
  // is clickable again (e.g. claim more, mint again) without a page refresh.
  useEffect(() => {
    if (state !== "confirmed") return;
    const t = setTimeout(reset, 3500);
    return () => clearTimeout(t);
  }, [state, reset]);

  const busy = state === "simulating" || state === "pending" || state === "confirming";
  const label =
    state === "simulating"
      ? "Checking…"
      : state === "pending"
        ? "Confirm in wallet…"
        : state === "confirming"
          ? "Confirming…"
          : state === "confirmed"
            ? confirmedLabel
            : children;

  // Not connected → quiet guidance, never a dead button.
  if (!account) {
    return (
      <span className={styles.mockAction}>
        <button type="button" className={`btn ${variant}`} disabled>
          {children}
        </button>
        <span className={styles.txHint}>Connect your wallet (top right) to continue.</span>
      </span>
    );
  }

  // Connected but wrong chain → offer the switch inline.
  if (wrongNetwork) {
    return (
      <span className={styles.mockAction}>
        <button
          type="button"
          className={`btn ${variant}`}
          onClick={() => void switchToMainnet()}
        >
          Switch to Ethereum
        </button>
        <span className={styles.txHint}>This action needs Ethereum mainnet.</span>
      </span>
    );
  }

  const txUrl = txHash ? etherscanTxUrl(txHash) : null;

  return (
    <span className={styles.mockAction}>
      <button
        type="button"
        className={`btn ${variant}`}
        disabled={disabled || busy || state === "confirmed"}
        aria-busy={busy}
        onClick={() => {
          const cfg = build();
          if (cfg) void execute(cfg);
        }}
      >
        {busy ? <span className={styles.txSpinner} aria-hidden="true" /> : null}
        {label}
      </button>

      {disabled && disabledHint ? (
        <span className={styles.txHint}>{disabledHint}</span>
      ) : null}

      {state === "confirmed" ? (
        <span className={`${styles.txNote} ${styles.txOk}`} role="status">
          Confirmed
          {txUrl ? (
            <>
              {" — "}
              <a className={styles.txLink} href={txUrl} target="_blank" rel="noreferrer">
                view on Etherscan
              </a>
            </>
          ) : null}
        </span>
      ) : null}

      {state === "error" && error ? (
        <span className={`${styles.txNote} ${styles.txError}`} role="alert">
          {error}
        </span>
      ) : null}

      {state === "confirming" && txUrl ? (
        <span className={`${styles.txNote} ${styles.txInfo}`} role="status">
          Submitted —{" "}
          <a className={styles.txLink} href={txUrl} target="_blank" rel="noreferrer">
            track on Etherscan
          </a>
        </span>
      ) : null}
    </span>
  );
}
