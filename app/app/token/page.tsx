"use client";

import Link from "next/link";
import { useTokenV2Data } from "@/lib/reads/tokenV2";
import { requireAddress } from "@/lib/contracts/addresses";
import { feeHookV2Abi } from "@/lib/contracts/abis";
import { SwapPanel } from "@/components/SwapPanel";
import { Stat, TxButton, ErrorState, PendingState } from "@/components/ui";
import { formatEth, formatWord } from "@/lib/format";
import styles from "./token.module.css";

export default function TokenPage() {
  const { data: s, status, refetch } = useTokenV2Data();

  return (
    <div className="container">
      <header className={styles.head}>
        <p className="eyebrow">The WORD token</p>
        <h1 className={styles.title}>Hold it, stake it, earn the fee</h1>
        <p className={styles.lede}>
          WORD is a standalone token with a fixed 1,000,000 supply — no inflation, no minting.
          Every trade on the WORD/ETH pool pays a 1% fee, and half of it streams to WORD{" "}
          <Link href="/staking">stakers</Link> in ETH. The other half funds the word-NFT holders
          and the daily game.
        </p>
      </header>

      <div className={styles.layout}>
        <div className={styles.main}>
          {status === "pending" ? (
            <PendingState />
          ) : status === "error" || !s ? (
            <ErrorState hint="Token state couldn't be read — try again." onRetry={refetch} />
          ) : (
            <TokenBody s={s} refetch={refetch} />
          )}
        </div>

        <aside className={styles.widget}>
          <SwapPanel />
        </aside>
      </div>
    </div>
  );
}

function TokenBody({
  s,
  refetch,
}: {
  s: NonNullable<ReturnType<typeof useTokenV2Data>["data"]>;
  refetch: () => void;
}) {
  return (
    <>
      {/* ── supply ── */}
      <section className={`plate ${styles.counter}`}>
        <p className="eyebrow">WORD supply — fixed</p>
        <p className={`mono ${styles.supply}`}>{formatWord(s.totalSupplyWei)}</p>
        <div className={styles.counterStats}>
          <Stat label="Total supply" value={`${formatWord(s.totalSupplyWei)} WORD`} detail="fixed forever — no minting" />
          <Stat
            label="Staked"
            value={`${formatWord(s.totalStakedWei)} WORD`}
            detail="earning the ETH fee stream"
            tone={s.totalStakedWei > 0n ? "ok" : undefined}
          />
          <Stat
            label="Trading"
            value={s.tradingEnabled ? "Live" : "Opens soon"}
            detail={s.tradingEnabled ? "the pool is open" : "enableTrading() pending"}
            tone={s.tradingEnabled ? "ok" : undefined}
          />
        </div>
      </section>

      {/* ── fee split + permissionless flush ── */}
      <aside className={`well ${styles.routingNote}`}>
        <p>
          <strong>Where the 1% fee goes.</strong> A fixed, hardcoded split every flush —{" "}
          <span className="mono">
            {s.rewardsBps / 100} / {s.bountyBps / 100} / {s.stakingBps / 100}
          </span>{" "}
          (word-NFT holders / daily game / <strong>WORD stakers</strong>). There&apos;s no admin
          lever over it. Fees skim into the hook on each trade and anyone can push them to their
          streams.
        </p>
        <div className={styles.publicAction}>
          <div>
            <p className={styles.publicLabel}>
              Permissionless — anyone (or any keeper) can flush collected fees to the three streams
            </p>
            <p className={`mono ${styles.publicAmount}`}>
              {formatEth(s.pendingFeesWei)} ETH skimmed, awaiting flush
            </p>
          </div>
          <TxButton
            variant="btn--ghost"
            build={() => ({ address: requireAddress("feeHookV2"), abi: feeHookV2Abi, functionName: "flush" })}
            disabled={s.pendingFeesWei === 0n}
            disabledHint={s.pendingFeesWei === 0n ? "No fees to flush." : undefined}
            onConfirmed={refetch}
            confirmedLabel="Flushed ✓"
          >
            Flush fees
          </TxButton>
        </div>
      </aside>

      {/* ── staking CTA ── */}
      <section className={`plate plate--flat ${styles.counter}`}>
        <p className="eyebrow">Put WORD to work</p>
        <h2 className={styles.title} style={{ fontSize: "var(--text-lg)" }}>Stake to earn ETH</h2>
        <p className={styles.note}>
          Staking is the reason to hold: half of every swap fee is paid to stakers in ETH,
          pro-rata, continuously. Unstake anytime.
        </p>
        <div className={styles.publicAction}>
          <Link href="/staking" className="btn">Go to staking</Link>
        </div>
      </section>

      {/* ── migration note ── */}
      <aside className={`well ${styles.vaultNote}`}>
        <p>
          <strong>Held the old WORD?</strong> Eligible holders from the snapshot can convert it
          one-for-share to the new token — burn old, receive new, no deadline.{" "}
          <Link href="/migrate">Migrate here →</Link>
        </p>
      </aside>
    </>
  );
}
