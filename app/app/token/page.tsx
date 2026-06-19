"use client";

import Link from "next/link";
import { parseEther } from "viem";
import { useBurnData, useRoyaltyTotals, useBuybackSizing } from "@/lib/reads/token";
import { requireAddress } from "@/lib/contracts/addresses";
import { burnEngineAbi, feeHookAbi, royaltySplitterAbi } from "@/lib/contracts/abis";
import { SwapPanel } from "@/components/SwapPanel";
import { Stat, TxButton, ErrorState, PendingState } from "@/components/ui";
import { formatEth, formatWord } from "@/lib/format";
import styles from "./token.module.css";

const CAP = 11_000_000; // 11,000,000e18 sealed cap — the one fixed number

// UI-only minimum to enable the buyback button. The contract has NO balance
// floor: MIN_BUYBACK_ETH is an anti-dust *minimum-spend*, and when the engine
// balance is below it, executeBuyback simply requires spending the whole
// balance — so a buyback at 0.05 ETH is valid on-chain. This 0.05 is purely
// our UI floor to avoid surfacing uneconomic dust buybacks; it is stricter
// than nothing but looser than the contract's 0.1 minimum-spend.
const BUYBACK_UI_MIN_WEI = parseEther("0.05");

const toWord = (wei: bigint) => Number(wei / 10n ** 18n);

export default function TokenPage() {
  const { data: s, status, refetch } = useBurnData();
  const royalty = useRoyaltyTotals();

  return (
    <div className="container">
      <header className={styles.head}>
        <p className="eyebrow">The WORD token</p>
        <h1 className={styles.title}>Supply only falls</h1>
        <p className={styles.lede}>
          A quarter of every swap fee buys WORD on the open market and burns
          it. Supply descends from the 11,000,000 cap toward a living floor —
          the WORD backing the NFTs still alive — and that floor itself drops
          every time a word is unbound. Holders of plain WORD own the
          shrinking: no NFT required.
        </p>
      </header>

      <div className={styles.layout}>
        <div className={styles.main}>
          {status === "pending" ? (
            <PendingState />
          ) : status === "error" || !s ? (
            status === "error" ? (
              <ErrorState
                hint="Supply couldn't be read. The backing floor is safe either way — try again."
                onRetry={refetch}
              />
            ) : (
              <section className={`plate ${styles.counter} skeleton`} aria-busy />
            )
          ) : (
            <TokenBody s={s} royalty={royalty} refetch={refetch} />
          )}
        </div>

        {/* ── right-side widget: in-dApp swap ── */}
        <aside className={styles.widget}>
          <SwapPanel />
        </aside>
      </div>
    </div>
  );
}

function TokenBody({
  s,
  royalty,
  refetch,
}: {
  s: NonNullable<ReturnType<typeof useBurnData>["data"]>;
  royalty: ReturnType<typeof useRoyaltyTotals>;
  refetch: () => void;
}) {
  const supply = toWord(s.totalSupplyWei);
  const floor = toWord(s.currentFloorWei);
  const burned = toWord(s.burnedWei);
  const excess = toWord(s.burnableExcessWei);
  const hasExcess = s.burnableExcessWei > 0n;
  const tipWei = (s.pendingEthWei * BigInt(s.tipBps)) / 10000n;

  const floorPct = (floor / CAP) * 100;
  const excessPct = (excess / CAP) * 100;
  const burnedPct = (burned / CAP) * 100;

  // Base gates that don't need a simulation: there must be burnable excess, at
  // least the UI floor of accrued ETH, and no buyback already this block.
  const sameBlock = s.lastBuybackBlock === s.blockNumber;
  const baseEligible =
    hasExcess && s.pendingEthWei >= BUYBACK_UI_MIN_WEI && !sameBlock;

  // Self-sizing: pre-simulate executeBuyback across a small descending set of
  // candidate amounts (min(pending, MAX) → … → MIN_BUYBACK_ETH) and use the
  // LARGEST that simulates successfully as maxEthToSpend — instead of blindly
  // sending the whole accrued balance, which can exceed the thin pool's depth at
  // the current slippage guard and revert. Only run while the base gates pass.
  const sizing = useBuybackSizing(
    s.pendingEthWei,
    s.minBuybackWei,
    s.maxBuybackWei,
    baseEligible,
  );
  const sizingChecked = sizing.status === "loaded" && sizing.data?.checked === true;
  const sizingPending = baseEligible && sizing.status !== "error" && !sizingChecked;
  // The amount we've actually validated will go through (null = none fits today).
  const spendWei = sizing.data?.spendWei ?? null;
  const noneFits = baseEligible && sizingChecked && spendWei === null;

  const buybackReady = baseEligible && spendWei !== null;
  const buybackHint = !hasExcess
    ? "Nothing burnable right now."
    : s.pendingEthWei < BUYBACK_UI_MIN_WEI
      ? `Needs at least ${formatEth(BUYBACK_UI_MIN_WEI, 2)} ETH accrued.`
      : sameBlock
        ? "A buyback already ran this block — try again next block."
        : sizingPending
          ? "Sizing the buyback to what the pool can absorb…"
          : noneFits
            ? "Buyback can't run right now — the WORD/ETH pool is too shallow for a buyback at the current slippage setting. It'll work once the buyback slippage tolerance is raised or pool liquidity is added."
            : sizing.status === "error"
              ? "Couldn't size the buyback right now — try again in a moment."
              : undefined;

  const rt = royalty.data;

  return (
    <>
      {/* ── the live supply ── */}
      <section className={`plate ${styles.counter}`}>
        <p className="eyebrow">WORD supply, live</p>
        <p className={`mono ${styles.supply}`}>{supply.toLocaleString("en-US")}</p>

        <div
          className={styles.track}
          role="img"
          aria-label={`Of the 11,000,000 cap: ${floor.toLocaleString("en-US")} backing the living NFTs, ${excess.toLocaleString("en-US")} burnable now, ${burned.toLocaleString("en-US")} already burned`}
        >
          <div className={styles.trackBar}>
            <span className={styles.segFloor} style={{ width: `${floorPct}%` }} title="Backing the living NFTs — untouchable" />
            <span className={styles.segExcess} style={{ width: `${excessPct}%` }} title="Burnable right now" />
            <span className={styles.segBurned} style={{ width: `${burnedPct}%` }} title="Already burned" />
          </div>
          <ul className={styles.legend}>
            <li><span className={`${styles.dot} ${styles.dotFloor}`} aria-hidden="true" />Backing floor — untouchable</li>
            <li><span className={`${styles.dot} ${styles.dotExcess}`} aria-hidden="true" />Burnable now</li>
            <li><span className={`${styles.dot} ${styles.dotBurned}`} aria-hidden="true" />Already burned</li>
          </ul>
        </div>

        <div className={styles.counterStats}>
          <Stat
            label="Current backing floor"
            value={formatWord(s.currentFloorWei)}
            detail={`${s.aliveCount.toLocaleString("en-US")} words alive × 1,000 — falls as words unbind`}
          />
          <Stat
            label="Burnable right now"
            value={formatWord(s.burnableExcessWei)}
            detail={hasExcess ? "supply above the floor" : "supply has caught up to the floor"}
            tone={hasExcess ? "ok" : undefined}
          />
          <Stat
            label="Burned so far"
            value={formatWord(s.burnedWei)}
            detail="cumulative, for the protocol's life"
            tone="ok"
          />
        </div>
      </section>

      {/* ── buyback (excess) / paused idle state ── */}
      {hasExcess ? (
        <section className={`plate plate--flat ${styles.buyback}`}>
          <div className={styles.buybackText}>
            <p className="eyebrow">Permissionless</p>
            <h2 className={styles.buybackTitle}>Trigger the next buyback</h2>
            <p className={styles.note}>
              Anyone can run the burn — no team, no keeper contract, no
              permission. The engine spends its accrued ETH on the open
              market, burns every WORD it buys, and tips the caller{" "}
              {s.tipBps / 100}% of the spend for the gas.
            </p>
            <dl className={styles.buybackFacts}>
              <div>
                <dt>Accrued &amp; ready</dt>
                <dd className="mono">{formatEth(s.pendingEthWei)} ETH</dd>
              </div>
              <div>
                <dt>Your keeper tip</dt>
                <dd className="mono">≈ {formatEth(tipWei)} ETH</dd>
              </div>
              <div>
                <dt>Per-call bounds</dt>
                <dd className="mono">
                  {formatEth(s.minBuybackWei, 1)}–{formatEth(s.maxBuybackWei, 1)} ETH
                </dd>
              </div>
            </dl>
          </div>
          <div className={styles.buybackAction}>
            <TxButton
              build={() =>
                spendWei === null
                  ? null
                  : {
                      address: requireAddress("burnEngine"),
                      abi: burnEngineAbi,
                      functionName: "executeBuyback",
                      // Send the exact amount we pre-simulated as successful, so
                      // the on-chain call matches what we validated.
                      args: [spendWei],
                    }
              }
              disabled={!buybackReady}
              disabledHint={buybackHint}
              onConfirmed={() => {
                refetch();
                sizing.refetch();
              }}
              confirmedLabel="Burned ✓"
            >
              {spendWei !== null
                ? `Buy & burn ${formatEth(spendWei)} ETH worth`
                : "Buy & burn"}
            </TxButton>
            <p className={styles.smallprint}>
              Protected by an onchain slippage guard ({s.maxSlippageBps / 100}%
              max, hard ceiling 5%) and a one-buyback-per-block limit. A buyback
              can never push supply below the living backing floor — it only ever
              retires the burnable excess.
            </p>
          </div>
        </section>
      ) : (
        <section className={styles.pausedBox}>
          <span className={styles.pausedMark} aria-hidden="true">⏸</span>
          <h2 className={styles.pausedTitle}>Nothing to burn right now</h2>
          <p className={styles.pausedNote}>
            Supply has caught up to the living backing floor — every WORD
            left is backing a word that&apos;s still alive, so there&apos;s no excess
            to retire. The burn isn&apos;t finished; it&apos;s resting. The moment a
            word is unbound, the floor drops by 1,000 WORD, that freed WORD
            becomes burnable, and the buyback resumes automatically. While
            it rests, the fee split runs two-way ({s.rewardsBps / 100}/
            {s.bountyBps / 100} holders/bounty) — the burn quarter folds
            into holders and the game until there&apos;s something to burn again.
          </p>
          <p className={styles.smallprint}>
            no leftover ETH sits idle · the split toggles back to three-way
            the next flush there&apos;s excess
          </p>
        </section>
      )}

      {/* ── fee routing note + public flush ── */}
      <aside className={`well ${styles.routingNote}`}>
        <p>
          <strong>Why the fee split moves.</strong> Each time fees flush,
          the routing checks whether there&apos;s WORD to burn:{" "}
          <span className="mono">excess &gt; 0 → 50 / 25 / 25</span>{" "}
          (holders / bounty / burn), otherwise{" "}
          <span className="mono">70 / 30</span> (holders / bounty). It&apos;s not
          a one-time switch — it follows the burn, flush by flush, for the
          life of the protocol. Live now:{" "}
          <span className="mono">
            {s.rewardsBps / 100} / {s.bountyBps / 100}
            {s.burnBps > 0 ? ` / ${s.burnBps / 100}` : ""}
          </span>
          .
        </p>
        <div className={styles.publicAction}>
          <div>
            <p className={styles.publicLabel}>
              Permissionless — anyone (or any keeper) can push collected fees
              to their streams
            </p>
            <p className={`mono ${styles.publicAmount}`}>
              {formatEth(s.pendingFeesWei)} ETH skimmed, awaiting flush
            </p>
          </div>
          <TxButton
            variant="btn--ghost"
            build={() => ({
              address: requireAddress("feeHook"),
              abi: feeHookAbi,
              functionName: "flush",
            })}
            disabled={s.pendingFeesWei === 0n}
            disabledHint={s.pendingFeesWei === 0n ? "No fees to flush." : undefined}
            onConfirmed={refetch}
            confirmedLabel="Flushed ✓"
          >
            Flush fees
          </TxButton>
        </div>
      </aside>

      {/* ── royalties to date ── */}
      <section className={`plate plate--flat ${styles.royalties}`}>
        <div className={styles.royaltiesHead}>
          <p className="eyebrow">Marketplace royalties to date</p>
          <p className={styles.note}>
            A separate 3% resale royalty lands in the RoyaltySplitter and
            forwards in immutable equal thirds. Totals are summed from its
            payout history; NFT holders get no royalty cut (they&apos;re paid by
            the 1% fee).
          </p>
        </div>
        <div className={styles.royaltiesStats}>
          <Stat label="→ Buy-and-burn" value={`${rt ? formatEth(rt.burnWei) : "…"} ETH`} detail="one third" />
          <Stat label="→ Bounty treasury" value={`${rt ? formatEth(rt.bountyWei) : "…"} ETH`} detail="one third" />
          <Stat label="→ Team" value={`${rt ? formatEth(rt.adminWei) : "…"} ETH`} detail="one third" />
          <Stat
            label="Awaiting distribution"
            value={`${formatEth(s.pendingDistributionWei)} ETH`}
            detail="anyone can flush it"
            tone={s.pendingDistributionWei > 0n ? "ok" : undefined}
          />
        </div>
        <div className={styles.publicAction}>
          <div>
            <p className={styles.publicLabel}>
              Permissionless — anyone (or any keeper) can push the pending
              royalties through the equal-thirds split
            </p>
            <p className={`mono ${styles.publicAmount}`}>
              {formatEth(s.pendingDistributionWei)} ETH awaiting distribution
            </p>
          </div>
          <TxButton
            variant="btn--ghost"
            build={() => ({
              address: requireAddress("royaltySplitter"),
              abi: royaltySplitterAbi,
              functionName: "distribute",
            })}
            disabled={s.pendingDistributionWei === 0n}
            disabledHint={s.pendingDistributionWei === 0n ? "Nothing to distribute." : undefined}
            onConfirmed={() => {
              refetch();
              royalty.refetch();
            }}
            confirmedLabel="Distributed ✓"
          >
            Distribute royalties
          </TxButton>
        </div>
        <p className={styles.smallprint}>
          event-derived (no onchain lifetime counter) · split frozen at
          deploy, ownerless · <Link href="/docs#fees">how royalties work →</Link>
        </p>
      </section>

      {/* ── the vault explainer teaser ── */}
      <aside className={`well ${styles.vaultNote}`}>
        <p>
          <strong>Seeing one address hold ~91% of WORD on a scanner?</strong>{" "}
          That&apos;s the WordBank vault — every NFT&apos;s 1,000-WORD backing, held
          by contract code that can only ever release it to an unbinding
          owner. It is the design, not a whale.{" "}
          <Link href="/docs#vault">Read the full explainer →</Link>
        </p>
      </aside>
    </>
  );
}
