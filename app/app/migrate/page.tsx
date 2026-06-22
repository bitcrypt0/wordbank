"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { getAddress } from "viem";
import { useWallet } from "@/lib/wallet/WalletProvider";
import { useMigrationOnchain, type MigrationClaim, type MigrationProofs } from "@/lib/reads/migration";
import { requireAddress } from "@/lib/contracts/addresses";
import { wordMigratorAbi, wordTokenAbi } from "@/lib/contracts/abis";
import { Stat, TxButton, PendingState, ErrorState } from "@/components/ui";
import { formatWord } from "@/lib/format";
import styles from "./migrate.module.css";

export default function MigratePage() {
  const { account } = useWallet();
  const { data: chain, status, refetch } = useMigrationOnchain();
  const [proofs, setProofs] = useState<MigrationProofs | null>(null);
  const [proofState, setProofState] = useState<"loading" | "ready" | "missing">("loading");

  // The snapshot proofs file is published to public/migration-proofs.json after the snapshot run.
  useEffect(() => {
    let cancelled = false;
    fetch("/migration-proofs.json")
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error("not found"))))
      .then((j: MigrationProofs) => {
        if (!cancelled) {
          setProofs(j);
          setProofState("ready");
        }
      })
      .catch(() => {
        if (!cancelled) setProofState("missing");
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // The connected wallet's snapshot entry (case-insensitive address lookup).
  const entry: MigrationClaim | null = (() => {
    if (!proofs?.claims || !account) return null;
    const m = proofs.claims;
    const hit = m[account] ?? m[getAddress(account)];
    if (hit) return hit;
    const lc = account.toLowerCase();
    for (const k of Object.keys(m)) if (k.toLowerCase() === lc) return m[k];
    return null;
  })();

  return (
    <div className="container">
      <header className={styles.head}>
        <p className="eyebrow">For old WORD holders</p>
        <h1 className={styles.title}>Migrate to the new WORD</h1>
        <p className={styles.lede}>
          Holders captured in the snapshot can convert old WORD to the new token: you burn your
          snapshot balance and receive your pro-rata share of the migration reserve. Open in
          perpetuity — there is no deadline.
        </p>
      </header>

      {status === "pending" ? (
        <PendingState hint="Migration opens once the new contracts are live." />
      ) : status === "error" || !chain ? (
        <ErrorState hint="Couldn't read migration state — try again." onRetry={refetch} />
      ) : proofState === "loading" ? (
        <PendingState hint="Loading the snapshot…" />
      ) : proofState === "missing" ? (
        <div className={`plate ${styles.box}`}>
          <h2 className={styles.boxTitle}>Migration data isn&apos;t published yet</h2>
          <p className={styles.boxNote}>
            The eligibility snapshot will appear here once it&apos;s published. Check back shortly.
          </p>
        </div>
      ) : !account ? (
        <div className={`plate ${styles.box}`}>
          <h2 className={styles.boxTitle}>Connect to check eligibility</h2>
          <p className={styles.boxNote}>Connect the wallet that held old WORD at the snapshot.</p>
        </div>
      ) : !entry ? (
        <div className={`plate ${styles.box}`}>
          <h2 className={styles.boxTitle}>No allocation for this wallet</h2>
          <p className={styles.boxNote}>
            This wallet wasn&apos;t an eligible holder at the snapshot{proofs?.snapshotBlock ? ` (block ${proofs.snapshotBlock})` : ""},
            so it has nothing to migrate. If you hold old WORD in another wallet, connect that one.
          </p>
        </div>
      ) : (
        <MigratePanel entry={entry} chain={chain} refetch={refetch} />
      )}

      <p className={styles.footnote}>
        Migration is one-way and burns the old token. The new WORD earns by{" "}
        <Link href="/staking">staking</Link> (50% of the pool fee, in ETH). Eligibility and amounts
        are fixed by the snapshot — buying old WORD now grants nothing.
      </p>
    </div>
  );
}

function MigratePanel({
  entry,
  chain,
  refetch,
}: {
  entry: MigrationClaim;
  chain: { claimed: boolean; oldBalanceWei: bigint; allowanceWei: bigint };
  refetch: () => void;
}) {
  const oldAmount = BigInt(entry.oldAmount);
  const newAmount = BigInt(entry.newAmount);
  const proof = entry.proof as `0x${string}`[];
  const needsApproval = chain.allowanceWei < oldAmount;
  const insufficient = chain.oldBalanceWei < oldAmount;

  return (
    <>
      <div className={`plate plate--flat ${styles.totals}`}>
        <Stat label="You receive" value={`${formatWord(newAmount)} WORD`} detail="new token" tone="ok" />
        <Stat label="You burn" value={`${formatWord(oldAmount)} WORD`} detail="old token (snapshot balance)" />
      </div>

      <div className={`plate ${styles.box}`}>
        {chain.claimed ? (
          <>
            <p className={styles.done}>✓ Already migrated</p>
            <p className={styles.boxNote}>This wallet has claimed its new WORD. Head to <Link href="/staking">staking</Link> to put it to work.</p>
          </>
        ) : (
          <>
            <h2 className={styles.boxTitle}>Claim your migration</h2>
            <p className={styles.formula}>
              Burn <span className="mono">{formatWord(oldAmount)}</span> old WORD → receive{" "}
              <span className="mono">{formatWord(newAmount)}</span> new WORD
            </p>
            {insufficient ? (
              <p className={styles.warn}>
                This wallet now holds {formatWord(chain.oldBalanceWei)} old WORD — less than its
                snapshot balance, so it can&apos;t burn the full amount. Migration requires still
                holding your snapshot balance.
              </p>
            ) : null}
            <div className={styles.actions}>
              {needsApproval ? (
                <TxButton
                  build={() => ({
                    address: requireAddress("wordToken"),
                    abi: wordTokenAbi,
                    functionName: "approve",
                    args: [requireAddress("wordMigrator"), oldAmount],
                  })}
                  disabled={insufficient}
                  disabledHint={insufficient ? "Not enough old WORD held." : undefined}
                  onConfirmed={refetch}
                  confirmedLabel="Approved ✓"
                >
                  Approve old WORD
                </TxButton>
              ) : (
                <TxButton
                  build={() => ({
                    address: requireAddress("wordMigrator"),
                    abi: wordMigratorAbi,
                    functionName: "claim",
                    args: [oldAmount, newAmount, proof],
                  })}
                  disabled={insufficient}
                  disabledHint={insufficient ? "Not enough old WORD held." : undefined}
                  onConfirmed={refetch}
                  confirmedLabel="Migrated ✓"
                >
                  Burn &amp; claim {formatWord(newAmount)} WORD
                </TxButton>
              )}
            </div>
          </>
        )}
      </div>
    </>
  );
}
