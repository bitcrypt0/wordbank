"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useWallet } from "@/lib/wallet/WalletProvider";
import { useRewardsData, type RewardRow } from "@/lib/reads/rewards";
import { requireAddress } from "@/lib/contracts/addresses";
import { rewardsDistributorAbi } from "@/lib/contracts/abis";
import { TokenArt } from "@/components/TokenArt";
import { Stat, EmptyState, ErrorState, PendingState, TxButton } from "@/components/ui";
import { BatchUnbindConfirm } from "./BatchUnbindConfirm";
import { formatEth } from "@/lib/format";
import styles from "./rewards.module.css";

export default function DashboardPage() {
  const { account } = useWallet();
  const router = useRouter();
  const { data, status, refetch } = useRewardsData();
  const [selected, setSelected] = useState<number[]>([]);

  const owned = data?.tokens ?? [];
  const toggle = (id: number) =>
    setSelected((s) => (s.includes(id) ? s.filter((x) => x !== id) : [...s, id]));
  const allIds = owned.map((t) => t.tokenId);
  const allSelected = selected.length === owned.length && owned.length > 0;
  const claimable = owned.filter((t) => t.pendingWei > 0n).map((t) => t.tokenId);
  const selectedRows = owned.filter((t) => selected.includes(t.tokenId));
  const selectedTotal = selectedRows.reduce((acc, t) => acc + t.pendingWei, 0n);

  // Owns words but none could be loaded → a read problem, not an empty wallet.
  const couldNotLoad =
    status === "loaded" && owned.length === 0 && (data?.expectedCount ?? 0) > 0;

  return (
    <div className="container">
      <header className={styles.head}>
        <p className="eyebrow">Your words</p>
        <h1 className={styles.title}>Dashboard</h1>
        <p className={styles.lede}>
          Every word this wallet holds, in one place — open any to view it, claim
          its rewards, or unbind. Half of every swap fee streams to living words
          continuously, so pending rewards grow on their own; claiming is just
          collecting what has accrued.
        </p>
      </header>

      {status === "pending" ? (
        <PendingState />
      ) : !account ? (
        <div className={`plate ${styles.gate}`}>
          <h2 className={styles.gateTitle}>Connect to see your words</h2>
          <p className={styles.gateNote}>
            Your words and their rewards live onchain either way — connecting
            just lets this page list them and batch the claim.
          </p>
        </div>
      ) : status === "error" || couldNotLoad ? (
        <ErrorState
          hint={
            couldNotLoad
              ? `This wallet owns ${data?.expectedCount} words, but the network couldn't return them just now. Try again.`
              : "Your words couldn't be read. They keep accruing onchain regardless — try again."
          }
          onRetry={refetch}
        />
      ) : status === "loaded" && owned.length === 0 ? (
        <EmptyState
          title="No words in this wallet"
          hint="Words and their rewards accrue only to holders. Browse the gallery or mint to start."
        />
      ) : (
        <>
          {data?.partial ? (
            <div className={styles.partial} role="status">
              Showing <strong>{owned.length}</strong> of{" "}
              <strong>{data.expectedCount}</strong> words — the network rate-limited
              before everything loaded.{" "}
              <button type="button" className={styles.partialRetry} onClick={refetch}>
                Load the rest
              </button>
            </div>
          ) : null}

          <div className={`plate plate--flat ${styles.totals}`}>
            <Stat
              label="Words held"
              value={`${owned.length}`}
              detail={data && data.expectedCount !== owned.length ? `of ${data.expectedCount} owned` : "in this wallet"}
            />
            <Stat
              label="Pending across your words"
              value={`${formatEth(data?.pendingTotalWei ?? 0n)} ETH`}
              detail={`${claimable.length} with rewards to claim`}
              tone={(data?.pendingTotalWei ?? 0n) > 0n ? "ok" : undefined}
            />
            <Stat
              label="Lifetime claimed"
              value={`${formatEth(data?.lifetimeClaimedWei ?? 0n)} ETH`}
              detail="all-time, this wallet's words"
            />
            <Stat
              label="Stream"
              value={`${(data?.rewardsBps ?? 0) / 100}%`}
              detail="of every swap fee (live split)"
            />
          </div>

          {/* Action bar at the TOP so holders of many words don't scroll to act.
              Two clearly-separated batch actions over the same selection:
              a non-destructive Claim, and a danger-styled Unbind behind a
              type-to-confirm gate. */}
          <div className={`${styles.actionBar} ${styles.actionBarTop}`}>
            <div className={styles.selectLine}>
              <label className={styles.selectAll}>
                <input
                  type="checkbox"
                  aria-label="Select all words"
                  checked={allSelected}
                  ref={(el) => {
                    if (el)
                      el.indeterminate =
                        selected.length > 0 && selected.length < owned.length;
                  }}
                  onChange={() => setSelected(allSelected ? [] : allIds)}
                />
                Select all ({owned.length})
              </label>
              <span className={styles.selectSummary}>
                {selected.length === 0
                  ? "Select words to claim rewards or unbind"
                  : `${selected.length} selected · ${formatEth(selectedTotal)} ETH pending`}
              </span>
            </div>

            <div className={styles.batchActions}>
              <TxButton
                build={() => ({
                  address: requireAddress("rewardsDistributor"),
                  abi: rewardsDistributorAbi,
                  functionName: "claimRewards",
                  args: [selected.map((id) => BigInt(id))],
                })}
                disabled={selected.length === 0 || selectedTotal === 0n}
                disabledHint={
                  selected.length === 0
                    ? "Select at least one word."
                    : selectedTotal === 0n
                      ? "Selected words have nothing to claim yet."
                      : undefined
                }
                onConfirmed={() => {
                  setSelected([]);
                  refetch();
                }}
                confirmedLabel="Claimed ✓"
              >
                Claim selected
              </TxButton>

              <span className={styles.batchDivider} aria-hidden="true" />

              <BatchUnbindConfirm
                rows={selectedRows}
                bountyScanComplete={data?.bountyScanComplete ?? false}
                unbindAvailable={data?.unbindAvailable ?? false}
                onConfirmed={() => {
                  setSelected([]);
                  refetch();
                }}
              />
            </div>
          </div>

          <ul className={styles.grid} aria-busy={status === "loading"} aria-label="Your words">
            {owned.map((t) => {
              const isSel = selected.includes(t.tokenId);
              return (
                <li key={t.tokenId}>
                  <article
                    className={`${styles.card} ${isSel ? styles.cardSelected : ""}`}
                    tabIndex={0}
                    role="link"
                    aria-label={`${t.word}, token №${t.tokenId} — open detail`}
                    onClick={() => router.push(`/gallery/${t.tokenId}`)}
                    onKeyDown={(e) => {
                      if (e.target !== e.currentTarget) return; // ignore keys from inner controls
                      if (e.key === "Enter" || e.key === " ") {
                        e.preventDefault();
                        router.push(`/gallery/${t.tokenId}`);
                      }
                    }}
                  >
                    {/* Selection control — must NOT navigate. Stop propagation on
                        the wrapping label so toggling never opens the token. */}
                    <label
                      className={styles.cardCheck}
                      onClick={(e) => e.stopPropagation()}
                      onKeyDown={(e) => e.stopPropagation()}
                    >
                      <input
                        type="checkbox"
                        aria-label={`Select ${t.word} (№${t.tokenId})`}
                        checked={isSel}
                        onClick={(e) => e.stopPropagation()}
                        onChange={() => toggle(t.tokenId)}
                      />
                    </label>

                    {t.hasBounty ? (
                      <span className={styles.cardBounty} title="Holds an unclaimed bounty share">
                        ◆ bounty
                      </span>
                    ) : null}

                    <span className={styles.cardArt}>
                      <TokenArt tokenId={t.tokenId} alt={t.word} />
                    </span>

                    <div className={styles.cardBody}>
                      <span className={styles.cardWord}>{t.word}</span>
                      <span className={`mono ${styles.cardId}`}>№{t.tokenId}</span>
                      <span className={`mono ${styles.cardPending}`}>
                        {formatEth(t.pendingWei)} ETH
                        <span className={styles.cardPendingLabel}> pending</span>
                      </span>
                    </div>
                  </article>
                </li>
              );
            })}
          </ul>

          <p className={styles.footnote}>
            Bounty shares from the daily game are separate — claim those on{" "}
            <Link href="/game">the game console</Link> before their 7-day
            deadlines. Fee rewards here never expire. Unbinding a word{" "}
            <strong>forfeits any unclaimed bounty share</strong> it holds.
          </p>
        </>
      )}
    </div>
  );
}
