"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { parseUnits, formatUnits, type PublicClient } from "viem";
import { useWallet } from "@/lib/wallet/WalletProvider";
import { useSwapData } from "@/lib/reads/swap";
import { getPublicClient } from "@/lib/contracts/chain";
import { quoteExactIn } from "@/lib/swap/quote";
import { minOut, type Direction } from "@/lib/swap/pool";
import {
  buildSwapConfig,
  buildErc20ApproveConfig,
  buildPermit2ApproveConfig,
} from "@/lib/swap/execute";
import { TxButton, PendingState } from "@/components/ui";
import { formatEth, formatWord } from "@/lib/format";
import styles from "./SwapPanel.module.css";

const SLIPPAGE_PRESETS = [10, 50, 100]; // bps: 0.1% / 0.5% / 1%
const DEFAULT_SLIPPAGE_BPS = 50;

/** Parse a human decimal string to wei (18 decimals), 0n on bad input. */
function toWei(v: string): bigint {
  try {
    if (!v || Number.isNaN(Number(v))) return 0n;
    return parseUnits(v as `${number}`, 18);
  } catch {
    return 0n;
  }
}

interface QuoteState {
  amountOutWei: bigint;
  priceImpactBps: number;
  loading: boolean;
  failed: boolean;
}

export function SwapPanel() {
  const { account, wrongNetwork, switchToMainnet } = useWallet();
  const { data: s, status, refetch } = useSwapData();

  const [direction, setDirection] = useState<Direction>("buy");
  const [amount, setAmount] = useState("");
  const [slippageBps, setSlippageBps] = useState(DEFAULT_SLIPPAGE_BPS);
  const [quote, setQuote] = useState<QuoteState>({ amountOutWei: 0n, priceImpactBps: 0, loading: false, failed: false });

  const amountInWei = toWei(amount);
  const quoteSeq = useRef(0);

  // Live quote off the V4 Quoter (debounced).
  useEffect(() => {
    if (amountInWei <= 0n || status !== "loaded") {
      setQuote({ amountOutWei: 0n, priceImpactBps: 0, loading: false, failed: false });
      return;
    }
    const seq = ++quoteSeq.current;
    setQuote((q) => ({ ...q, loading: true, failed: false }));
    const t = setTimeout(() => {
      quoteExactIn(getPublicClient() as unknown as PublicClient, direction, amountInWei)
        .then((res) => {
          if (seq !== quoteSeq.current) return;
          setQuote({ amountOutWei: res.amountOutWei, priceImpactBps: res.priceImpactBps, loading: false, failed: false });
        })
        .catch(() => {
          if (seq !== quoteSeq.current) return;
          setQuote({ amountOutWei: 0n, priceImpactBps: 0, loading: false, failed: true });
        });
    }, 300);
    return () => clearTimeout(t);
  }, [amountInWei, direction, status]);

  if (status === "pending") {
    return (
      <section className={`plate ${styles.panel}`} aria-label="Swap WORD and ETH">
        <PendingState title="Swap goes live at launch" hint="The WORD/ETH pool and trade panel activate once the contracts are deployed and trading is enabled." />
      </section>
    );
  }

  const inToken = direction === "buy" ? "ETH" : "WORD";
  const outToken = direction === "buy" ? "WORD" : "ETH";
  const balanceWei = s ? (direction === "buy" ? s.ethBalanceWei : s.wordBalanceWei) : 0n;
  const minReceivedWei = minOut(quote.amountOutWei, slippageBps);

  // ── real reverts, pre-checked client-side ──
  const tradingEnabled = !!s?.tradingEnabled;
  const overCap = direction === "buy" && !!s?.guardActive && quote.amountOutWei > (s?.buyCapWei ?? 0n);
  const insufficient = amountInWei > balanceWei;

  // Sell two-step: ERC-20 → Permit2 → swap.
  const nowSec = Math.floor(Date.now() / 1000);
  const needsErc20 = direction === "sell" && amountInWei > 0n && (s?.erc20ToPermit2Wei ?? 0n) < amountInWei;
  const needsPermit2 =
    direction === "sell" &&
    amountInWei > 0n &&
    !needsErc20 &&
    ((s?.permit2AllowanceWei ?? 0n) < amountInWei || (s?.permit2Expiration ?? 0) <= nowSec);

  const rateText = (() => {
    if (amountInWei <= 0n || quote.amountOutWei <= 0n) return "—";
    const inF = Number(formatUnits(amountInWei, 18));
    const outF = Number(formatUnits(quote.amountOutWei, 18));
    if (inF === 0) return "—";
    return direction === "buy"
      ? `1 ETH ≈ ${(outF / inF).toLocaleString("en-US", { maximumFractionDigits: 0 })} WORD`
      : `1 WORD ≈ ${(outF / inF).toLocaleString("en-US", { maximumFractionDigits: 6 })} ETH`;
  })();
  const highImpact = quote.priceImpactBps >= 150;

  // ── blocking banner + disabled reason ──
  let banner: { tone: "warn" | "info" | "error"; text: React.ReactNode } | null = null;
  if (!tradingEnabled) {
    banner = { tone: "info", text: <><strong>Trading isn&apos;t open yet.</strong> Swaps revert until the team calls <span className="mono">enableTrading()</span> once, at launch. The pool exists; it just won&apos;t accept trades before then.</> };
  } else if (wrongNetwork) {
    banner = { tone: "error", text: <><strong>Wrong network.</strong> The WORD/ETH pool lives on Ethereum mainnet. Switch networks to trade.</> };
  } else if (account && insufficient && amountInWei > 0n) {
    banner = { tone: "error", text: <><strong>Insufficient {inToken}.</strong> You have {direction === "buy" ? formatEth(balanceWei) : formatWord(balanceWei)} {inToken}; this trade needs more.</> };
  } else if (overCap) {
    banner = { tone: "warn", text: <><strong>Launch window: max 10,000 WORD per buy.</strong> For the first hour after trading opens, the anti-whale guard reverts any single buy whose output exceeds <span className="mono">10,000 WORD</span>. Lower your amount, or wait for the guard to lift (≤ 1 hour, one-way).</> };
  }

  const canSwap =
    tradingEnabled && !wrongNetwork && !!account && amountInWei > 0n && !insufficient && !overCap && !quote.failed && quote.amountOutWei > 0n && !needsErc20 && !needsPermit2;

  const setMax = () => setAmount(formatUnits(balanceWei, 18));

  return (
    <section className={`plate ${styles.panel}`} aria-label="Swap WORD and ETH">
      <header className={styles.head}>
        <h2 className={styles.title}>Buy &amp; sell WORD</h2>
        <div className={styles.toggle} role="tablist" aria-label="Trade direction">
          <button type="button" role="tab" aria-selected={direction === "buy"}
            className={`${styles.toggleBtn} ${direction === "buy" ? styles.toggleOn : ""}`}
            onClick={() => { setDirection("buy"); setAmount(""); }}>Buy</button>
          <button type="button" role="tab" aria-selected={direction === "sell"}
            className={`${styles.toggleBtn} ${direction === "sell" ? styles.toggleOn : ""}`}
            onClick={() => { setDirection("sell"); setAmount(""); }}>Sell</button>
        </div>
      </header>

      {/* input (pay) */}
      <div className={styles.field}>
        <div className={styles.fieldHead}>
          <label htmlFor="swap-amount" className="eyebrow">You pay</label>
          <span className={styles.balance}>
            Balance: <span className="mono">{direction === "buy" ? formatEth(balanceWei) : formatWord(balanceWei)}</span> {inToken}
            {account && balanceWei > 0n ? (
              <button type="button" className={styles.maxBtn} onClick={setMax}>MAX</button>
            ) : null}
          </span>
        </div>
        <div className={styles.inputRow}>
          <input id="swap-amount" className={`mono ${styles.input}`} inputMode="decimal" placeholder="0.0"
            value={amount} onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))} />
          <span className={styles.token}>{inToken}</span>
        </div>
      </div>

      {/* output (receive) */}
      <div className={`${styles.field} ${styles.fieldOut}`}>
        <div className={styles.fieldHead}><span className="eyebrow">You receive (estimated)</span></div>
        <div className={styles.inputRow}>
          <output className={`mono ${styles.input} ${styles.output}`}>
            {quote.loading ? "…" : amountInWei > 0n ? (direction === "buy" ? formatWord(quote.amountOutWei) : formatEth(quote.amountOutWei)) : "0.0"}
          </output>
          <span className={styles.token}>{outToken}</span>
        </div>
      </div>

      {/* quote detail */}
      {amountInWei > 0n && quote.amountOutWei > 0n ? (
        <dl className={styles.detail}>
          <div><dt>Rate</dt><dd className="mono">{rateText}</dd></div>
          <div><dt>Price impact</dt><dd className={`mono ${highImpact ? styles.warnText : ""}`}>{(quote.priceImpactBps / 100).toFixed(2)}%</dd></div>
          <div><dt>Min. received</dt><dd className="mono">{direction === "buy" ? `${formatWord(minReceivedWei)} WORD` : `${formatEth(minReceivedWei)} ETH`}</dd></div>
        </dl>
      ) : quote.failed && amountInWei > 0n ? (
        <p className={styles.txNote}>Couldn&apos;t fetch a quote — the pool may have no liquidity yet, or the amount is out of range.</p>
      ) : null}

      {/* slippage */}
      <div className={styles.slippage}>
        <span className="eyebrow">Slippage tolerance</span>
        <div className={styles.slipControls}>
          {SLIPPAGE_PRESETS.map((bps) => (
            <button key={bps} type="button" className={`${styles.slipBtn} ${slippageBps === bps ? styles.slipOn : ""}`} onClick={() => setSlippageBps(bps)}>
              {bps / 100}%
            </button>
          ))}
          <span className={styles.slipCustom}>
            <input type="number" className="mono" aria-label="Custom slippage percent" min={0} max={50} step={0.1}
              value={(slippageBps / 100).toString()}
              onChange={(e) => setSlippageBps(Math.max(0, Math.min(5000, Math.round(Number(e.target.value) * 100))))} />%
          </span>
        </div>
      </div>

      {/* fee disclosure — one compact line */}
      <p className={styles.fee}>
        <strong>1% protocol fee</strong> on every trade. <Link href="/docs#fees">How it works →</Link>
      </p>

      {/* banner */}
      {banner ? (
        <div className={`${styles.banner} ${banner.tone === "error" ? styles.bannerError : banner.tone === "warn" ? styles.bannerWarn : styles.bannerInfo}`}
          role={banner.tone === "info" ? "status" : "alert"}>
          {banner.text}
        </div>
      ) : null}

      {/* actions */}
      {!account ? (
        <button type="button" className="btn" disabled>Connect wallet to trade</button>
      ) : wrongNetwork ? (
        <button type="button" className="btn" onClick={() => void switchToMainnet()}>Switch to Ethereum</button>
      ) : !tradingEnabled ? (
        <button type="button" className="btn" disabled>Trading not enabled</button>
      ) : needsErc20 ? (
        <div className={styles.approveRow}>
          <div className={styles.steps}>
            <span className={`${styles.step} ${styles.stepActive}`}>1 · Approve WORD</span>
            <span className={styles.step}>2 · Permit2</span>
            <span className={styles.step}>3 · Swap</span>
          </div>
          <TxButton build={buildErc20ApproveConfig} onConfirmed={refetch} confirmedLabel="Approved ✓">
            Approve WORD for Permit2
          </TxButton>
          <p className={styles.approveNote}>One-time. Buying with ETH needs no approval.</p>
        </div>
      ) : needsPermit2 ? (
        <div className={styles.approveRow}>
          <div className={styles.steps}>
            <span className={styles.step}>1 · Approve WORD ✓</span>
            <span className={`${styles.step} ${styles.stepActive}`}>2 · Permit2</span>
            <span className={styles.step}>3 · Swap</span>
          </div>
          <TxButton build={() => buildPermit2ApproveConfig(amountInWei)} onConfirmed={refetch} confirmedLabel="Permitted ✓">
            Permit the router
          </TxButton>
        </div>
      ) : (
        <TxButton
          build={() => buildSwapConfig(direction, amountInWei, minReceivedWei)}
          disabled={!canSwap}
          disabledHint={amountInWei <= 0n ? "Enter an amount." : insufficient ? `Insufficient ${inToken}.` : overCap ? "Over the launch-window cap." : quote.amountOutWei <= 0n ? "Waiting for a quote." : undefined}
          onConfirmed={() => { setAmount(""); refetch(); }}
          confirmedLabel="Swapped ✓"
        >
          {direction === "buy" ? "Buy WORD" : "Sell WORD"}
        </TxButton>
      )}
    </section>
  );
}
