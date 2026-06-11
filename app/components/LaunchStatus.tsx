"use client";

import Link from "next/link";
import { useLaunchData, REGISTRY_BATCH } from "@/lib/reads/launch";
import { requireAddress } from "@/lib/contracts/addresses";
import { wordBankAbi } from "@/lib/contracts/abis";
import { Meter, TxButton, PendingState, ErrorState } from "@/components/ui";
import { formatInt } from "@/lib/format";
import styles from "./LaunchStatus.module.css";

/**
 * Public launch / provenance liveness panel.
 *
 * Surfaces the three PERMISSIONLESS launch steps — revealOffset(),
 * rearmOffset(), buildRegistry() — on a surface any non-owner can see, each
 * phase-gated to when it's actually callable (read live from the on-chain
 * flags). The "the launch can't stall on the team" guarantee made visible.
 */
export function LaunchStatus() {
  const { data: s, status, refetch } = useLaunchData();

  if (status === "pending") return null; // pre-deployment: nothing to surface
  if (status === "error") {
    return (
      <section className={`plate ${styles.panel}`}>
        <ErrorState
          title="Couldn't read launch status"
          hint="The provenance/registry state couldn't be read — try again."
          onRetry={refetch}
        />
      </section>
    );
  }
  if (!s) {
    return (
      <section className={`plate ${styles.panel} skeleton`} aria-busy>
        <PendingState title="Loading launch status…" hint="" />
      </section>
    );
  }

  const canReveal = s.offsetArmed && !s.offsetSet && s.revealWindowOpen;
  const canRearm = s.offsetArmed && !s.offsetSet && s.revealWindowLapsed;
  const canBuild = s.offsetSet && !s.registrySynced;
  const remaining = Math.max(s.registryTarget - s.registryCursor, 0);
  const batch = BigInt(Math.min(remaining, Number(REGISTRY_BATCH)) || 1);

  return (
    <section className={`plate ${styles.panel}`} aria-label="Launch and provenance status">
      <header className={styles.head}>
        <p className="eyebrow">Launch liveness — permissionless</p>
        <h2 className={styles.title}>Provenance &amp; game start</h2>
        <p className={styles.note}>
          These steps are open to <strong>anyone</strong> — no team key
          required. The launch advances even if the team disappears: any holder
          or keeper can push the next step the moment it&apos;s callable.
        </p>
      </header>

      {/* 1 · provenance reveal */}
      <div className={styles.step}>
        <div className={styles.stepHead}>
          <span className={styles.stepNum}>1</span>
          <div>
            <p className={styles.stepTitle}>Reveal the provenance offset</p>
            <p className={styles.stepNote}>
              Arms automatically when the public allocation (9,800) sells out,
              then fixes every token&apos;s word &amp; traits from a future block
              hash nobody controls.
            </p>
          </div>
        </div>

        {!s.offsetArmed ? (
          <div className={styles.gatedNote}>
            <Meter
              label="Toward the provenance trigger"
              value={s.publicMinted}
              max={s.publicSupply || 1}
              detail={`${formatInt(s.publicMinted)} / ${formatInt(s.publicSupply)} public mints`}
              tone="gold"
            />
            <p className={styles.stepBlocked}>
              Not armed yet — opens at sellout. Nothing to push.
            </p>
          </div>
        ) : s.offsetSet ? (
          <p className={styles.stepDone}>✓ Offset fixed — provenance is locked in.</p>
        ) : canReveal ? (
          <div className={styles.stepAction}>
            <TxButton
              build={() => ({
                address: requireAddress("wordBank"),
                abi: wordBankAbi,
                functionName: "revealOffset",
              })}
              onConfirmed={refetch}
              confirmedLabel="Offset revealed ✓"
            >
              Reveal offset
            </TxButton>
            <p className={styles.stepReady}>
              Armed and inside the reveal window — anyone can finalize it now.
            </p>
          </div>
        ) : canRearm ? (
          <div className={styles.stepAction}>
            <div className={styles.warnNote} role="alert">
              The reveal window lapsed before anyone called it. No harm —{" "}
              <strong>anyone can re-arm it</strong> for a fresh future-block
              target, then reveal again.
            </div>
            <TxButton
              build={() => ({
                address: requireAddress("wordBank"),
                abi: wordBankAbi,
                functionName: "rearmOffset",
              })}
              onConfirmed={refetch}
              confirmedLabel="Re-armed ✓"
            >
              Re-arm the reveal
            </TxButton>
          </div>
        ) : (
          <p className={styles.stepBlocked}>
            Armed — waiting for the target block to mature before the reveal can
            be called.
          </p>
        )}
      </div>

      {/* 2 · registry build */}
      <div className={styles.step}>
        <div className={styles.stepHead}>
          <span className={styles.stepNum}>2</span>
          <div>
            <p className={styles.stepTitle}>Build the alive registry</p>
            <p className={styles.stepNote}>
              Indexes every word by category so the daily game can draw. The
              game stays locked until this finishes (SPEC-3).
            </p>
          </div>
        </div>

        {!s.offsetSet ? (
          <p className={styles.stepBlocked}>Waiting on the offset reveal above.</p>
        ) : s.registrySynced ? (
          <p className={styles.stepDone}>
            ✓ <span className="mono">registrySynced()</span> — the{" "}
            <Link href="/game">daily game</Link> is live.
          </p>
        ) : canBuild ? (
          <div className={styles.stepAction}>
            <Meter
              label="Registry build"
              value={s.registryCursor}
              max={s.registryTarget || 1}
              detail={`${formatInt(s.registryCursor)} / ${formatInt(s.registryTarget)} indexed`}
              tone="ok"
            />
            <TxButton
              build={() => ({
                address: requireAddress("wordBank"),
                abi: wordBankAbi,
                functionName: "buildRegistry",
                args: [batch],
              })}
              onConfirmed={refetch}
              confirmedLabel="Batch built ✓"
            >
              Build the next batch
            </TxButton>
            <p className={styles.stepReady}>
              Anyone can push batches — the game unlocks the moment it&apos;s done.
            </p>
          </div>
        ) : null}
      </div>
    </section>
  );
}
