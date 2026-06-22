"use client";

import { useState } from "react";
import Link from "next/link";
import { parseEther } from "viem";
import { useWallet } from "@/lib/wallet/WalletProvider";
import { useStakingData } from "@/lib/reads/staking";
import { requireAddress } from "@/lib/contracts/addresses";
import { wordStakingAbi, wordTokenV2Abi } from "@/lib/contracts/abis";
import { Stat, TxButton, ErrorState, PendingState } from "@/components/ui";
import { formatEth, formatWord } from "@/lib/format";
import styles from "./staking.module.css";

/** Parse a token-amount string to wei; null if blank/invalid/non-positive. */
function toWei(s: string): bigint | null {
  const t = s.trim();
  if (!t) return null;
  try {
    const w = parseEther(t);
    return w > 0n ? w : null;
  } catch {
    return null;
  }
}

export default function StakingPage() {
  const { account } = useWallet();
  const { data, status, refetch } = useStakingData();
  const [stakeStr, setStakeStr] = useState("");
  const [unstakeStr, setUnstakeStr] = useState("");

  const stakeWei = toWei(stakeStr);
  const unstakeWei = toWei(unstakeStr);
  const needsApproval = !!stakeWei && !!data && data.allowanceWei < stakeWei;
  const overWallet = !!stakeWei && !!data && stakeWei > data.walletWei;
  const overStaked = !!unstakeWei && !!data && unstakeWei > data.stakedWei;

  return (
    <div className="container">
      <header className={styles.head}>
        <p className="eyebrow">Earn from the fee</p>
        <h1 className={styles.title}>Stake WORD</h1>
        <p className={styles.lede}>
          Half of every 1% swap fee on the WORD/ETH pool streams to stakers in ETH — continuously,
          pro-rata to your stake. Stake to earn it; unstake anytime. Claiming just collects what
          has accrued.
        </p>
      </header>

      {status === "pending" ? (
        <PendingState />
      ) : status === "error" || !data ? (
        <ErrorState hint="Staking state couldn't be read — it keeps accruing onchain regardless. Try again." onRetry={refetch} />
      ) : (
        <>
          <div className={`plate plate--flat ${styles.totals}`}>
            <Stat label="Your stake" value={`${formatWord(data.stakedWei)} WORD`} detail="earning the ETH stream" />
            <Stat
              label="Your pending rewards"
              value={`${formatEth(data.pendingWei)} ETH`}
              detail="claimable now"
              tone={data.pendingWei > 0n ? "ok" : undefined}
            />
            <Stat label="Total staked" value={`${formatWord(data.totalStakedWei)} WORD`} detail="across all stakers" />
          </div>

          {!account ? (
            <div className={`plate ${styles.gate}`}>
              <h2 className={styles.gateTitle}>Connect to stake</h2>
              <p className={styles.gateNote}>The pool fee accrues to stakers either way — connecting lets you stake and claim.</p>
            </div>
          ) : (
            <>
              <div className={styles.cols}>
                {/* ── Stake ── */}
                <section className={`plate ${styles.panel}`}>
                  <p className="eyebrow">Stake</p>
                  <h2 className={styles.panelTitle}>Add to your stake</h2>
                  <p className={styles.note}>Wallet balance: <span className="mono">{formatWord(data.walletWei)} WORD</span></p>
                  <div className={styles.inputRow}>
                    <input
                      className={styles.input}
                      inputMode="decimal"
                      placeholder="0.0"
                      value={stakeStr}
                      onChange={(e) => setStakeStr(e.target.value)}
                      aria-label="Amount of WORD to stake"
                    />
                    <button type="button" className={styles.maxBtn} onClick={() => setStakeStr(formatWord(data.walletWei).replace(/,/g, ""))}>
                      Max
                    </button>
                  </div>
                  {needsApproval ? (
                    <TxButton
                      build={() =>
                        stakeWei
                          ? { address: requireAddress("wordTokenV2"), abi: wordTokenV2Abi, functionName: "approve", args: [requireAddress("wordStaking"), stakeWei] }
                          : null
                      }
                      disabled={!stakeWei || overWallet}
                      disabledHint={overWallet ? "More than your balance." : !stakeWei ? "Enter an amount." : undefined}
                      onConfirmed={refetch}
                      confirmedLabel="Approved ✓"
                    >
                      Approve WORD
                    </TxButton>
                  ) : (
                    <TxButton
                      build={() =>
                        stakeWei
                          ? { address: requireAddress("wordStaking"), abi: wordStakingAbi, functionName: "stake", args: [stakeWei] }
                          : null
                      }
                      disabled={!stakeWei || overWallet}
                      disabledHint={overWallet ? "More than your balance." : !stakeWei ? "Enter an amount." : undefined}
                      onConfirmed={() => {
                        setStakeStr("");
                        refetch();
                      }}
                      confirmedLabel="Staked ✓"
                    >
                      Stake WORD
                    </TxButton>
                  )}
                </section>

                {/* ── Unstake ── */}
                <section className={`plate ${styles.panel}`}>
                  <p className="eyebrow">Unstake</p>
                  <h2 className={styles.panelTitle}>Withdraw your stake</h2>
                  <p className={styles.note}>Staked: <span className="mono">{formatWord(data.stakedWei)} WORD</span> · pending rewards are kept</p>
                  <div className={styles.inputRow}>
                    <input
                      className={styles.input}
                      inputMode="decimal"
                      placeholder="0.0"
                      value={unstakeStr}
                      onChange={(e) => setUnstakeStr(e.target.value)}
                      aria-label="Amount of WORD to unstake"
                    />
                    <button type="button" className={styles.maxBtn} onClick={() => setUnstakeStr(formatWord(data.stakedWei).replace(/,/g, ""))}>
                      Max
                    </button>
                  </div>
                  <TxButton
                    variant="btn--ghost"
                    build={() =>
                      unstakeWei
                        ? { address: requireAddress("wordStaking"), abi: wordStakingAbi, functionName: "unstake", args: [unstakeWei] }
                        : null
                    }
                    disabled={!unstakeWei || overStaked}
                    disabledHint={overStaked ? "More than you've staked." : !unstakeWei ? "Enter an amount." : undefined}
                    onConfirmed={() => {
                      setUnstakeStr("");
                      refetch();
                    }}
                    confirmedLabel="Unstaked ✓"
                  >
                    Unstake WORD
                  </TxButton>
                </section>
              </div>

              <div className={styles.claimRow}>
                <span className={styles.note}>
                  Claimable rewards: <span className="mono">{formatEth(data.pendingWei)} ETH</span>
                </span>
                <TxButton
                  build={() => ({ address: requireAddress("wordStaking"), abi: wordStakingAbi, functionName: "claim" })}
                  disabled={data.pendingWei === 0n}
                  disabledHint={data.pendingWei === 0n ? "Nothing to claim yet." : undefined}
                  onConfirmed={refetch}
                  confirmedLabel="Claimed ✓"
                >
                  Claim {formatEth(data.pendingWei)} ETH
                </TxButton>
              </div>
            </>
          )}

          <p className={styles.footnote}>
            Rewards are paid in ETH and accrue continuously from the live fee split (25% word-NFT
            holders · 25% the daily game · <strong>50% stakers</strong>). New to WORD?{" "}
            <Link href="/token">Get WORD</Link> first, or{" "}
            <Link href="/migrate">migrate from the old token</Link>.
          </p>
        </>
      )}
    </div>
  );
}
