"use client";

import { useId, useState } from "react";
import { useWrite, type WriteConfig } from "@/lib/hooks/useWrite";
import styles from "./Irreversible.module.css";

/**
 * The strongest confirmation pattern in the product — used for every 🔒
 * action (lock slots, seal minting, renounce ownership, enable trading,
 * sunset guard, make-permanent) and modeled on the unbind flow:
 * a sealed control → an explicit statement of consequence → an "I
 * understand" check → type-to-confirm → the final act.
 *
 * States: available (armed), blocked (preconditions unmet), done (spent —
 * one-time actions read as receipts, never as buttons).
 *
 * Agent 9: the final button fires `wiring`; everything else is pure UI.
 */
export function IrreversibleAction({
  label,
  consequence,
  confirmWord,
  wiring,
  state,
  blockedNote,
  doneNote,
  build,
  onConfirmed,
}: {
  /** The action, imperative: "Seal minting". */
  label: string;
  /** Plain-language statement of what can never be undone. */
  consequence: string;
  /** The word the owner must type, e.g. "SEAL". */
  confirmWord: string;
  /** Exact call, for the caption. */
  wiring: string;
  state: "available" | "blocked" | "done";
  blockedNote?: string;
  doneNote?: string;
  /** The live call to make once armed (simulate → sign → confirm). */
  build?: () => WriteConfig | null;
  onConfirmed?: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [understood, setUnderstood] = useState(false);
  const [typed, setTyped] = useState("");
  const [spent, setSpent] = useState(false);
  const { state: txState, error, execute } = useWrite(() => {
    setSpent(true);
    onConfirmed?.();
  });
  const busy = txState === "simulating" || txState === "pending" || txState === "confirming";
  const inputId = useId();

  if (state === "done" || spent) {
    return (
      <div className={styles.done}>
        <span className={styles.doneMark} aria-hidden="true">
          ✓
        </span>
        <div>
          <p className={styles.doneTitle}>{label} — done</p>
          <p className={styles.doneNote}>
            {spent ? "Completed in this mock session." : doneNote}
            {" · "}This was a one-time action; it cannot be repeated or undone.
          </p>
        </div>
      </div>
    );
  }

  if (state === "blocked") {
    return (
      <div className={styles.blocked}>
        <span className={styles.lockMark} aria-hidden="true">
          🔒
        </span>
        <div>
          <p className={styles.blockedTitle}>{label}</p>
          <p className={styles.blockedNote}>{blockedNote ?? "Preconditions not yet met."}</p>
        </div>
      </div>
    );
  }

  const armed = understood && typed.trim().toUpperCase() === confirmWord.toUpperCase();

  return (
    <div className={`${styles.shell} ${open ? styles.shellOpen : ""}`}>
      {!open ? (
        <button type="button" className={styles.trigger} onClick={() => setOpen(true)}>
          <span className={styles.lockMark} aria-hidden="true">
            🔒
          </span>
          {label}…
        </button>
      ) : (
        <div className={styles.panel} role="group" aria-label={`Confirm: ${label}`}>
          <p className={styles.warnTitle}>This can never be undone.</p>
          <p className={styles.consequence}>{consequence}</p>
          <label className={styles.check}>
            <input
              type="checkbox"
              checked={understood}
              onChange={(e) => setUnderstood(e.target.checked)}
            />
            I understand the consequence above is permanent.
          </label>
          <label className={styles.typeLabel} htmlFor={inputId}>
            Type <span className="mono">{confirmWord}</span> to arm the action
          </label>
          <input
            id={inputId}
            className={`mono ${styles.typeInput}`}
            value={typed}
            onChange={(e) => setTyped(e.target.value)}
            autoComplete="off"
            spellCheck={false}
          />
          <div className={styles.row}>
            <button
              type="button"
              className="btn btn--danger"
              disabled={!armed || busy}
              aria-busy={busy}
              onClick={() => {
                if (!build) {
                  setSpent(true);
                  return;
                }
                const cfg = build();
                if (cfg) void execute(cfg);
              }}
            >
              {busy
                ? txState === "pending"
                  ? "Confirm in wallet…"
                  : txState === "confirming"
                    ? "Confirming…"
                    : "Checking…"
                : `${label} — forever`}
            </button>
            <button
              type="button"
              className="btn btn--ghost"
              disabled={busy}
              onClick={() => {
                setOpen(false);
                setUnderstood(false);
                setTyped("");
              }}
            >
              Cancel
            </button>
          </div>
          {txState === "error" && error ? (
            <p className={styles.wiring} role="alert" style={{ color: "var(--danger)" }}>
              {error}
            </p>
          ) : (
            <p className={styles.wiring}>
              calls <span className="mono">{wiring}</span>
            </p>
          )}
        </div>
      )}
    </div>
  );
}
