"use client";

import { useState, useRef } from "react";
import { parseEther, formatEther, isAddress, type Hex } from "viem";
import { useAdminData, type AdminData } from "@/lib/reads/admin";
import { useWallet } from "@/lib/wallet/WalletProvider";
import { requireAddress, OUR_ADDRESSES } from "@/lib/contracts/addresses";
import {
  wordBankAbi,
  wordTokenAbi,
  feeHookAbi,
  burnEngineAbi,
  lpLockerAbi,
  bountyEngineAbi,
  royaltySplitterAbi,
} from "@/lib/contracts/abis";
import { IrreversibleAction } from "@/components/Irreversible";
import { Meter, TxButton, PendingState, ErrorState } from "@/components/ui";
import { WordbankGlyph } from "@/components/Logo";
import { formatEth, formatWord, shortAddress } from "@/lib/format";
import { getPublicClient } from "@/lib/contracts/chain";
import { getWalletClient } from "@/lib/contracts/clients";
import { decodeError } from "@/lib/contracts/errors";
import {
  parseSlots,
  parseFragments,
  renderTemplate,
  validateTemplate,
  parseTemplatesJson,
  type ParsedTemplate,
} from "@/lib/admin/templates";
import type { WriteConfig } from "@/lib/hooks/useWrite";
import styles from "./admin.module.css";

/** Phase enum names for display. */
const PHASE_NAMES = ["Setup", "EarlyBird", "Between", "PublicSale"];

export default function AdminPage() {
  const { account } = useWallet();
  const { data: a, status, refetch } = useAdminData();

  if (status === "pending") {
    return <div className="container"><PendingState /></div>;
  }
  if (status === "error") {
    return <div className="container"><ErrorState onRetry={refetch} /></div>;
  }
  if (status === "loading" || !a) {
    return <div className="container"><div className="skeleton" style={{ height: 300, borderRadius: 12, marginTop: 24 }} /></div>;
  }
  if (!a.isOwner) {
    return <Forbidden connected={!!account} />;
  }

  return (
    <div className="container">
      <header className={styles.head}>
        <p className="eyebrow">Owner&apos;s cockpit</p>
        <h1 className={styles.title}>Protocol management</h1>
        <p className={styles.lede}>
          Everything you can do, in order, with its limits in plain sight.
          Anything marked 🔒 happens once and can never be undone — those
          actions will always stop and make you prove you mean it.
        </p>
      </header>

      <nav className={styles.anchors} aria-label="Panels">
        {[
          ["#launch", "Launch & one-time"],
          ["#sale", "Sale"],
          ["#provenance", "Provenance & game"],
          ["#economics", "Economics"],
          ["#royalties", "Royalties"],
          ["#guard", "Launch guard"],
          ["#lock", "Liquidity lock"],
          ["#bounty", "Bounty menus"],
          ["#token-owner", "Token ownership"],
        ].map(([href, label]) => (
          <a key={href} href={href}>{label}</a>
        ))}
      </nav>

      <LaunchPanel a={a} refetch={refetch} />
      <SalePanel a={a} account={account!} refetch={refetch} />
      <ProvenancePanel a={a} refetch={refetch} />
      <EconomicsPanel a={a} refetch={refetch} />
      <RoyaltiesPanel a={a} refetch={refetch} />
      <GuardPanel a={a} refetch={refetch} />
      <LockPanel a={a} account={account!} refetch={refetch} />
      <BountyPanel a={a} refetch={refetch} />
      <TokenOwnerPanel a={a} refetch={refetch} />
    </div>
  );
}

/* ─────────────────── forbidden / hidden ─────────────────── */
function Forbidden({ connected }: { connected: boolean }) {
  return (
    <div className="container">
      <div className={`plate ${styles.forbidden}`}>
        <WordbankGlyph size={40} />
        <h1 className={styles.forbiddenTitle}>There&apos;s nothing for you here</h1>
        <p className={styles.forbiddenNote}>
          This address manages the protocol and answers only to the contract
          owner&apos;s wallet.{" "}
          {connected ? "The connected wallet is not the owner." : "No wallet is connected."}{" "}
          Every power it grants is bounded onchain — there is nothing here
          that could affect your words or your WORD.
        </p>
      </div>
    </div>
  );
}

/* ─────────────────── 1 · launch + one-time ─────────────────── */
function LaunchPanel({ a, refetch }: { a: AdminData; refetch: () => void }) {
  const [hash, setHash] = useState("");
  const validHash = /^0x[0-9a-fA-F]{64}$/.test(hash);
  return (
    <section id="launch" className={`plate ${styles.panel}`}>
      <PanelHead n="1" title="Launch & one-time actions" note="The irreversible, set-once steps. Each reads its on-chain flag — a spent action shows as done, never as a live button." />
      <div className={styles.grid2}>
        <div className={styles.fieldGroup}>
          <p className="eyebrow">Lock word slots (provenance)</p>
          {a.slotsLocked ? (
            <p className={styles.stepDone}>✓ Slots locked — the provenance hash is committed.</p>
          ) : (
            <>
              <label className={styles.field}>
                <span>Provenance hash (bytes32)</span>
                <input className="mono" value={hash} placeholder="0x…64 hex" onChange={(e) => setHash(e.target.value)} />
              </label>
              <IrreversibleAction
                label="Lock slots"
                consequence="Freezes the word slots and commits the provenance hash. The collection's word→trait mapping can never be edited again."
                confirmWord="LOCK"
                wiring="WordBank.lockSlots(hash)"
                state={validHash ? "available" : "blocked"}
                blockedNote="Enter a valid 32-byte hash to arm this."
                build={() => ({ address: requireAddress("wordBank"), abi: wordBankAbi, functionName: "lockSlots", args: [hash as Hex] })}
                onConfirmed={refetch}
              />
            </>
          )}
        </div>
        <div className={styles.fieldGroup}>
          <p className="eyebrow">Seal minting</p>
          {a.mintingSealed ? (
            <p className={styles.stepDone}>✓ Minting sealed at 11,000,000 — supply can only fall now.</p>
          ) : (
            <IrreversibleAction
              label="Seal minting"
              consequence="Permanently caps WORD supply. No further WORD — backing or liquidity — can ever be minted."
              confirmWord="SEAL"
              wiring="WordToken.sealMinting()"
              state="available"
              build={() => ({ address: requireAddress("wordToken"), abi: wordTokenAbi, functionName: "sealMinting" })}
              onConfirmed={refetch}
            />
          )}
        </div>
      </div>
    </section>
  );
}

/* ─────────────────── 2 · sale controls ─────────────────── */
function SalePanel({ a, account, refetch }: { a: AdminData; account: string; refetch: () => void }) {
  const [early, setEarly] = useState(a.earlyBirdAllocation);
  const [pub, setPub] = useState(a.publicAllocation);
  // Prices are entered in human-friendly ETH and converted with parseEther on submit.
  // Prefill from the current on-chain value so re-saving never silently changes an untouched field.
  const [earlyPrice, setEarlyPrice] = useState(formatEther(a.earlyBirdPriceWei));
  const [pubPrice, setPubPrice] = useState(formatEther(a.publicPriceWei));
  const [walletCap, setWalletCap] = useState(a.earlyBirdWalletCap);
  const [mintCount, setMintCount] = useState(1);
  const [mintTo, setMintTo] = useState(account);
  const sum = early + pub + 200;
  const sumValid = sum === 10_000;
  const reserveLeft = 200 - a.adminMinted;

  // Parse ETH price strings → wei. parseEther throws on unparseable/negative input.
  // Price 0 is valid (the free-mint / Sepolia path uses 0).
  function parsePriceWei(eth: string): bigint | null {
    const t = eth.trim();
    if (t === "" || t.startsWith("-")) return null;
    try {
      return parseEther(t as `${number}`);
    } catch {
      return null;
    }
  }
  const earlyPriceWei = parsePriceWei(earlyPrice);
  const pubPriceWei = parsePriceWei(pubPrice);
  const pricesValid = earlyPriceWei !== null && pubPriceWei !== null;
  const capValid = Number.isInteger(walletCap) && walletCap >= 0;

  // setSaleConfig only succeeds in Setup (0) or Between (2); the contract reverts otherwise.
  const phaseAllowsConfig = a.phase === 0 || a.phase === 2;
  const configValid = sumValid && pricesValid && capValid && phaseAllowsConfig;
  const configHint = !phaseAllowsConfig
    ? `Sale config is locked while a sale phase is open (current: ${PHASE_NAMES[a.phase]}). Close the sale to a Setup/Between phase first.`
    : !sumValid
      ? "Allocations must total 10,000."
      : !pricesValid
        ? "Enter valid ETH prices (0 is allowed; no negative values)."
        : !capValid
          ? "Early-bird wallet cap must be a whole number ≥ 0."
          : undefined;

  return (
    <section id="sale" className={`plate ${styles.panel}`}>
      <PanelHead n="2" title="Sale controls" note="Allocations and prices, tunable between phases. The contract refuses any setup that doesn't add to exactly 10,000." />
      <div className={styles.grid2}>
        <div className={styles.fieldGroup}>
          <p className="eyebrow">Allocations &amp; prices</p>
          <label className={styles.field}><span>Early bird (count)</span>
            <input type="number" className="mono" value={early} min={0} max={9800} onChange={(e) => setEarly(Number(e.target.value))} /></label>
          <label className={styles.field}><span>Public sale (count)</span>
            <input type="number" className="mono" value={pub} min={0} max={9800} onChange={(e) => setPub(Number(e.target.value))} /></label>
          <label className={styles.field}><span>Admin reserve (count)</span><input type="number" className="mono" value={200} disabled /></label>
          <p className={sumValid ? styles.sumOk : styles.sumBad} role="status">
            {early.toLocaleString()} + {pub.toLocaleString()} + 200 = {sum.toLocaleString()} {sumValid ? "✓" : "— must equal 10,000"}
          </p>
          <label className={styles.field}><span>Early-bird price (ETH)</span>
            <input
              type="text" inputMode="decimal" className="mono" value={earlyPrice} placeholder="0"
              aria-invalid={earlyPriceWei === null}
              onChange={(e) => setEarlyPrice(e.target.value)} /></label>
          <label className={styles.field}><span>Public price (ETH)</span>
            <input
              type="text" inputMode="decimal" className="mono" value={pubPrice} placeholder="0"
              aria-invalid={pubPriceWei === null}
              onChange={(e) => setPubPrice(e.target.value)} /></label>
          <label className={styles.field}><span>Early-bird wallet cap (count)</span>
            <input
              type="number" className="mono" value={walletCap} min={0}
              aria-invalid={!capValid}
              onChange={(e) => setWalletCap(Number(e.target.value))} /></label>
          <p className={styles.fieldHint}>
            A wallet cap of <span className="mono">0</span> blocks all early-bird mints — set it &gt; 0 before opening early bird. Prices are in ETH; 0 is allowed (free / testnet mint).
          </p>
          <TxButton
            disabled={!configValid}
            disabledHint={configHint}
            build={() => ({
              address: requireAddress("wordBank"), abi: wordBankAbi, functionName: "setSaleConfig",
              args: [BigInt(early), BigInt(pub), earlyPriceWei!, pubPriceWei!, BigInt(walletCap)],
            })}
            onConfirmed={refetch}
          >
            Save sale config
          </TxButton>
        </div>

        <div className={styles.fieldGroup}>
          <p className="eyebrow">Phase — current <span className="mono">{PHASE_NAMES[a.phase]}</span></p>
          <div className={styles.actionsCol}>
            <TxButton variant="btn--ghost" build={() => ({ address: requireAddress("wordBank"), abi: wordBankAbi, functionName: "openEarlyBird" })} onConfirmed={refetch}>Open early bird</TxButton>
            <TxButton variant="btn--ghost" build={() => ({ address: requireAddress("wordBank"), abi: wordBankAbi, functionName: "closeEarlyBird" })} onConfirmed={refetch}>Close early bird</TxButton>
            <TxButton variant="btn--ghost" build={() => ({ address: requireAddress("wordBank"), abi: wordBankAbi, functionName: "openPublicSale" })} onConfirmed={refetch}>Open public sale</TxButton>
            <TxButton variant="btn--ghost" build={() => ({ address: requireAddress("wordBank"), abi: wordBankAbi, functionName: "pausePublicSale" })} onConfirmed={refetch}>Pause public sale</TxButton>
          </div>

          <p className="eyebrow" style={{ marginTop: "var(--space-4)" }}>Admin reserve</p>
          <Meter label="Reserve minted" value={a.adminMinted} max={200} detail={`${a.adminMinted} / 200`} />
          <label className={styles.field}><span>Count</span>
            <input type="number" className="mono" min={1} max={Math.max(reserveLeft, 1)} value={mintCount} onChange={(e) => setMintCount(Number(e.target.value))} /></label>
          <label className={styles.field}><span>To</span>
            <input className="mono" value={mintTo} onChange={(e) => setMintTo(e.target.value)} /></label>
          <TxButton
            variant="btn--ghost"
            disabled={mintCount < 1 || mintCount > reserveLeft || !isAddress(mintTo)}
            disabledHint={reserveLeft <= 0 ? "Reserve exhausted." : !isAddress(mintTo) ? "Enter a valid address." : undefined}
            build={() => ({ address: requireAddress("wordBank"), abi: wordBankAbi, functionName: "adminMint", args: [BigInt(mintCount), mintTo as Hex] })}
            onConfirmed={refetch}
          >
            Mint {mintCount} from reserve
          </TxButton>

          <p className="eyebrow" style={{ marginTop: "var(--space-4)" }}>Proceeds</p>
          <p className={`mono ${styles.proceeds}`}>{formatEth(a.proceedsWei)} ETH</p>
          <TxButton
            variant="btn--ghost"
            disabled={a.proceedsWei === 0n}
            disabledHint={a.proceedsWei === 0n ? "No proceeds to withdraw." : undefined}
            build={() => ({ address: requireAddress("wordBank"), abi: wordBankAbi, functionName: "withdrawProceeds", args: [account as Hex] })}
            onConfirmed={refetch}
          >
            Withdraw proceeds
          </TxButton>
        </div>
      </div>
    </section>
  );
}

/* ─────────────────── 3 · provenance & game ─────────────────── */
function ProvenancePanel({ a, refetch }: { a: AdminData; refetch: () => void }) {
  return (
    <section id="provenance" className={`plate ${styles.panel}`}>
      <PanelHead n="3" title="Provenance & game start" note="The reveal/registry steps are permissionless — surfaced here for convenience and on the public mint page for everyone." />
      <div className={`${styles.gameGate} ${a.registrySynced ? styles.gameGateOk : styles.gameGateWait}`} role="status">
        {a.registrySynced ? (
          <><strong>The daily game is unlocked.</strong> registrySynced() is true.</>
        ) : (
          <><strong>The daily game has not started.</strong> It stays locked (SPEC-3) until sellout, offset reveal, and registry build complete.</>
        )}
      </div>
      <div className={styles.grid2}>
        <div className={styles.fieldGroup}>
          <p className="eyebrow">Offset</p>
          {a.offsetSet ? (
            <p className={styles.stepDone}>✓ Offset fixed — provenance locked in.</p>
          ) : (
            <div className={styles.actionsCol}>
              <TxButton variant="btn--ghost" build={() => ({ address: requireAddress("wordBank"), abi: wordBankAbi, functionName: "revealOffset" })} onConfirmed={refetch}>Reveal offset</TxButton>
              <TxButton variant="btn--ghost" build={() => ({ address: requireAddress("wordBank"), abi: wordBankAbi, functionName: "rearmOffset" })} onConfirmed={refetch}>Re-arm lapsed reveal</TxButton>
            </div>
          )}
        </div>
        <div className={styles.fieldGroup}>
          <p className="eyebrow">Alive registry</p>
          <Meter label="Registry build" value={a.registryCursor} max={a.registryTarget || 1}
            detail={a.registrySynced ? "complete" : `${a.registryCursor} / ${a.registryTarget}`} tone={a.registrySynced ? "ok" : "ink"} />
          <TxButton
            variant="btn--ghost"
            disabled={!a.offsetSet || a.registrySynced}
            disabledHint={!a.offsetSet ? "Waiting on the offset reveal." : a.registrySynced ? "Registry complete." : undefined}
            build={() => ({ address: requireAddress("wordBank"), abi: wordBankAbi, functionName: "buildRegistry", args: [2000n] })}
            onConfirmed={refetch}
          >
            Build next batch
          </TxButton>
        </div>
      </div>
    </section>
  );
}

/* ─────────────────── 4 · economics ─────────────────── */
function BoundedField({
  label, unit = "bps", current, min, max, build, onConfirmed, hint,
}: {
  label: string; unit?: string; current: number; min: number; max: number;
  build: (value: number) => WriteConfig | null; onConfirmed: () => void; hint?: string;
}) {
  const [value, setValue] = useState(current);
  const clamped = Math.max(min, Math.min(max, value));
  const dirty = clamped !== current;
  return (
    <div className={styles.bounded}>
      <div className={styles.boundedHead}>
        <span className={styles.boundedLabel}>{label}</span>
        <span className={styles.boundedNow}>onchain now: <span className="mono">{current} {unit}</span></span>
      </div>
      <div className={styles.boundedRow}>
        <input type="range" min={min} max={max} value={clamped} onChange={(e) => setValue(Number(e.target.value))} aria-label={label} />
        <span className={`mono ${styles.boundedValue}`}>{clamped} {unit}</span>
      </div>
      <p className={styles.boundedBounds}>hard bounds: <span className="mono">{min}–{max} {unit}</span>{hint ? ` · ${hint}` : ""} — out of range is impossible</p>
      <TxButton variant="btn--ghost" disabled={!dirty} disabledHint={!dirty ? "Unchanged." : undefined} build={() => build(clamped)} onConfirmed={onConfirmed}>
        {dirty ? `Set ${clamped} ${unit}` : "Unchanged"}
      </TxButton>
    </div>
  );
}

function EconomicsPanel({ a, refetch }: { a: AdminData; refetch: () => void }) {
  const [r, setR] = useState(a.rewardsBps);
  const [b, setB] = useState(a.bountyBps);
  const [u, setU] = useState(a.burnBps);
  const sb = a.burnSplitBounds;
  const sum = r + b + u;
  const splitValid = sum === 10000 && r >= sb.rMin && r <= sb.rMax && b >= sb.bMin && b <= sb.bMax && u >= sb.uMin && u <= sb.uMax;

  return (
    <section id="economics" className={`plate ${styles.panel}`}>
      <PanelHead n="4" title="Economics — bounded tuning" note="Every dial has a ceiling and a floor burned into the contracts. You can tune; you cannot rug — and everyone can verify that." />
      <div className={styles.grid2}>
        <div className={styles.fieldGroup}>
          <BoundedField label="Swap fee" current={a.feeBps} min={1} max={a.maxFeeBps} hint="100 bps = 1%"
            build={(v) => ({ address: requireAddress("feeHook"), abi: feeHookAbi, functionName: "setFeeBps", args: [v] })} onConfirmed={refetch} />
          <BoundedField label="Buyback max slippage" current={a.maxSlippageBps} min={0} max={a.maxSlippageCeil}
            build={(v) => ({ address: requireAddress("burnEngine"), abi: burnEngineAbi, functionName: "setMaxSlippageBps", args: [v] })} onConfirmed={refetch} />
        </div>

        <div className={styles.fieldGroup}>
          <p className="eyebrow">Fee split — while burning (sum 100%)</p>
          {([["Holders", r, setR, sb.rMin, sb.rMax], ["Bounties", b, setB, sb.bMin, sb.bMax], ["Burn", u, setU, sb.uMin, sb.uMax]] as const).map(
            ([lab, val, set, mn, mx]) => (
              <label key={lab} className={styles.field}>
                <span>{lab} <span className={styles.boundedBounds}>({mn / 100}–{mx / 100}%)</span></span>
                <input type="number" className="mono" value={val} min={mn} max={mx} step={100} onChange={(ev) => set(Number(ev.target.value))} />
              </label>
            ),
          )}
          <p className={splitValid ? styles.sumOk : styles.sumBad} role="status">
            {r / 100}% + {b / 100}% + {u / 100}% = {sum / 100}% {splitValid ? "✓" : "— must sum to 100% inside every bound"}
          </p>
          <TxButton
            disabled={!splitValid}
            disabledHint={!splitValid ? "Fix the split first." : undefined}
            build={() => ({ address: requireAddress("feeHook"), abi: feeHookAbi, functionName: "setBurnPhaseSplit", args: [r, b, u] })}
            onConfirmed={refetch}
          >
            Save burn-phase split
          </TxButton>
          <PostBurnSplit a={a} refetch={refetch} />
        </div>
      </div>
    </section>
  );
}

function PostBurnSplit({ a, refetch }: { a: AdminData; refetch: () => void }) {
  const [r, setR] = useState(a.postRewardsBps);
  const [b, setB] = useState(a.postBountyBps);
  const pb = a.postSplitBounds;
  const sum = r + b;
  const valid = sum === 10000 && r >= pb.rMin && r <= pb.rMax && b >= pb.bMin && b <= pb.bMax;
  return (
    <div style={{ marginTop: "var(--space-4)" }}>
      <p className="eyebrow">Two-way split — while burning is paused (sum 100%)</p>
      {([["Holders", r, setR, pb.rMin, pb.rMax], ["Bounties", b, setB, pb.bMin, pb.bMax]] as const).map(([lab, val, set, mn, mx]) => (
        <label key={lab} className={styles.field}>
          <span>{lab} <span className={styles.boundedBounds}>({mn / 100}–{mx / 100}%)</span></span>
          <input type="number" className="mono" value={val} min={mn} max={mx} step={100} onChange={(ev) => set(Number(ev.target.value))} />
        </label>
      ))}
      <p className={valid ? styles.sumOk : styles.sumBad}>{r / 100}% + {b / 100}% = {sum / 100}% {valid ? "✓" : "— must sum to 100%"}</p>
      <TxButton variant="btn--ghost" disabled={!valid} disabledHint={!valid ? "Fix the split first." : undefined}
        build={() => ({ address: requireAddress("feeHook"), abi: feeHookAbi, functionName: "setPostBurnSplit", args: [r, b] })} onConfirmed={refetch}>
        Save post-burn split
      </TxButton>
    </div>
  );
}

/* ─────────────────── royalties ─────────────────── */
function RoyaltiesPanel({ a, refetch }: { a: AdminData; refetch: () => void }) {
  const splitterAddr = OUR_ADDRESSES.royaltySplitter ?? "";
  const [bps, setBps] = useState(a.royaltyBps);
  const [receiver, setReceiver] = useState(a.royaltyReceiver);
  const clampedBps = Math.max(0, Math.min(a.maxRoyaltyBps, bps));
  const dirty = clampedBps !== a.royaltyBps || receiver.toLowerCase() !== a.royaltyReceiver.toLowerCase();
  const onSplitter = receiver.toLowerCase() === splitterAddr.toLowerCase();
  const hasPendingAdmin = a.pendingAdminWei > 0n;

  return (
    <section id="royalties" className={`plate ${styles.panel}`}>
      <PanelHead n="·" title="Royalties" note="Marketplace royalties land in the RoyaltySplitter and split in immutable equal thirds — burn / bounty / team. The split is frozen and ownerless; the only knobs are the ERC-2981 rate/receiver and the permissionless plumbing." />
      <div className={`${styles.gameGate} ${onSplitter ? styles.gameGateOk : styles.gameGateWait}`} role="status">
        {onSplitter ? (
          <><strong>Trustless split intact.</strong> Royalties route to the RoyaltySplitter — 1/3 burn · 1/3 bounty · 1/3 team, frozen and ownerless.</>
        ) : (
          <><strong>⚠ Trustless split abandoned.</strong> The receiver no longer points at the RoyaltySplitter. Point it back unless you truly intend this.</>
        )}
      </div>
      <div className={styles.grid2}>
        <div className={styles.fieldGroup}>
          <p className="eyebrow">Royalty rate &amp; receiver</p>
          <div className={styles.bounded}>
            <div className={styles.boundedHead}>
              <span className={styles.boundedLabel}>ERC-2981 rate</span>
              <span className={styles.boundedNow}>onchain now: <span className="mono">{a.royaltyBps} bps</span></span>
            </div>
            <div className={styles.boundedRow}>
              <input type="range" min={0} max={a.maxRoyaltyBps} step={50} value={clampedBps} onChange={(e) => setBps(Number(e.target.value))} aria-label="Royalty rate (bps)" />
              <span className={`mono ${styles.boundedValue}`}>{(clampedBps / 100).toFixed(2)}%</span>
            </div>
            <p className={styles.boundedBounds}>hard bound: <span className="mono">0–{a.maxRoyaltyBps} bps</span> (≤10%) — out of range is impossible</p>
          </div>
          <label className={styles.field}><span>Receiver</span>
            <input className="mono" value={receiver} onChange={(e) => setReceiver(e.target.value)} aria-label="Royalty receiver address" /></label>
          <p className={onSplitter ? styles.boundedBounds : styles.sumBad}>
            {onSplitter ? "Points at the RoyaltySplitter — keeps the split trustless." : "Off the splitter — the equal-thirds guarantee no longer applies."}
          </p>
          <div className={styles.actionsCol}>
            {receiver.toLowerCase() !== splitterAddr.toLowerCase() ? (
              <button type="button" className="btn btn--ghost" onClick={() => setReceiver(splitterAddr)}>Reset to splitter</button>
            ) : null}
            <TxButton
              variant="btn--ghost"
              disabled={!dirty || !isAddress(receiver)}
              disabledHint={!isAddress(receiver) ? "Enter a valid receiver address." : !dirty ? "Unchanged." : undefined}
              build={() => ({ address: requireAddress("wordBank"), abi: wordBankAbi, functionName: "setRoyalty", args: [receiver as Hex, BigInt(clampedBps)] })}
              onConfirmed={refetch}
            >
              Set royalty
            </TxButton>
          </div>
        </div>

        <div className={styles.fieldGroup}>
          <p className="eyebrow">Distribution plumbing</p>
          <p className={styles.stepDetail}>Pending distribution: <span className="mono">{formatEth(a.pendingDistributionWei)} ETH</span> — anyone can split it (permissionless).</p>
          <TxButton
            disabled={a.pendingDistributionWei === 0n}
            disabledHint={a.pendingDistributionWei === 0n ? "Nothing to distribute." : undefined}
            build={() => ({ address: requireAddress("royaltySplitter"), abi: royaltySplitterAbi, functionName: "distribute" })}
            onConfirmed={refetch}
          >
            Distribute now
          </TxButton>
          {hasPendingAdmin ? (
            <div style={{ marginTop: "var(--space-3)" }}>
              <p className={styles.stepDetail}>Held team slice: <span className="mono">{formatEth(a.pendingAdminWei)} ETH</span> (a direct send failed).</p>
              <TxButton variant="btn--ghost"
                build={() => ({ address: requireAddress("royaltySplitter"), abi: royaltySplitterAbi, functionName: "withdrawAdmin" })} onConfirmed={refetch}>
                Withdraw admin slice
              </TxButton>
            </div>
          ) : (
            <p className={styles.stepDetail}>No pending team slice. <span className="mono">withdrawAdmin()</span> appears only if a direct team-slice send fails.</p>
          )}
          <p className="eyebrow" style={{ marginTop: "var(--space-3)" }}>Stuck tokens</p>
          <RescueToken refetch={refetch} />
        </div>
      </div>
    </section>
  );
}

function RescueToken({ refetch }: { refetch: () => void }) {
  const [token, setToken] = useState("");
  return (
    <>
      <label className={styles.field}><span>Token</span>
        <input className="mono" value={token} placeholder="0x… (not WETH)" onChange={(e) => setToken(e.target.value)} /></label>
      <p className={styles.stepDetail}><strong>WETH is blocked</strong> — it auto-splits via distribute().</p>
      <TxButton variant="btn--ghost" disabled={!isAddress(token)} disabledHint={!isAddress(token) ? "Enter a token address." : undefined}
        build={() => ({ address: requireAddress("royaltySplitter"), abi: royaltySplitterAbi, functionName: "rescueToken", args: [token as Hex] })} onConfirmed={refetch}>
        Rescue token
      </TxButton>
    </>
  );
}

/* ─────────────────── 5 · launch guard ─────────────────── */
function GuardPanel({ a, refetch }: { a: AdminData; refetch: () => void }) {
  const enabled = a.tradingEnabledAt > 0;
  return (
    <section id="guard" className={`plate ${styles.panel}`}>
      <PanelHead n="5" title="Launch guard" note="Trading opens once, by your hand. The anti-whale buy cap then runs at most one hour and dies on its own — it can never come back." />
      <div className={styles.grid2}>
        <div className={styles.fieldGroup}>
          <p className="eyebrow">Trading gate</p>
          <IrreversibleAction
            label="Enable trading"
            consequence="Opens the pool to everyone, permanently, and starts the one-hour anti-whale clock. There is no pause and no second launch."
            confirmWord="OPEN"
            wiring="FeeHook.enableTrading() — one-time"
            state={enabled ? "done" : "available"}
            doneNote="Trading enabled — tradingEnabledAt is set onchain."
            build={() => ({ address: requireAddress("feeHook"), abi: feeHookAbi, functionName: "enableTrading" })}
            onConfirmed={refetch}
          />
        </div>
        <div className={styles.fieldGroup}>
          <p className="eyebrow">Anti-whale guard</p>
          {!enabled ? (
            <p className={styles.stepBlocked}>Arms automatically the moment trading is enabled.</p>
          ) : a.guardActive && !a.guardSunset ? (
            <IrreversibleAction
              label="Sunset guard early"
              consequence="Removes the per-swap buy cap now instead of at the one-hour mark. The guard cannot be re-enabled by anyone, ever."
              confirmWord="SUNSET"
              wiring="FeeHook.sunsetGuard() — one-time"
              state="available"
              build={() => ({ address: requireAddress("feeHook"), abi: feeHookAbi, functionName: "sunsetGuard" })}
              onConfirmed={refetch}
            />
          ) : (
            <p className={styles.stepDone}>✓ Guard over — {a.guardSunset ? "sunset by you" : "expired at the 1-hour mark"}. It can never return.</p>
          )}
        </div>
      </div>
    </section>
  );
}

/* ─────────────────── 6 · liquidity lock ─────────────────── */
function LockPanel({ a, account, refetch }: { a: AdminData; account: string; refetch: () => void }) {
  const [date, setDate] = useState("");
  const newUntil = date ? Math.floor(new Date(date).getTime() / 1000) : 0;
  const extendValid = newUntil > a.lockedUntil;
  return (
    <section id="lock" className={`plate ${styles.panel}`}>
      <PanelHead n="6" title="Liquidity lock" note="The anti-rug guarantee. The LP position can only ever be locked longer — never released early. LP fee income stays collectable throughout." />
      <div className={styles.grid2}>
        <div className={styles.fieldGroup}>
          <p className="eyebrow">Lock status</p>
          {!a.lockLocked ? (
            <p className={styles.stepBlocked}>Not locked yet — deposit the position after seeding the pool (<span className="mono">LPLocker.lock</span>).</p>
          ) : a.lockPermanent ? (
            <p className={styles.stepDone}>✦ Permanent. The position can never be withdrawn by anyone. Fee collection continues forever.</p>
          ) : (
            <>
              <p className={styles.stepDone}>✓ Locked until <strong>{new Date(a.lockedUntil * 1000).toLocaleDateString()}</strong> (extendable, never shortenable).</p>
              <label className={styles.field}><span>Extend to</span>
                <input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
              <TxButton variant="btn--ghost" disabled={!extendValid} disabledHint={!extendValid ? "Pick a later date." : undefined}
                build={() => ({ address: requireAddress("lpLocker"), abi: lpLockerAbi, functionName: "extendLock", args: [BigInt(newUntil)] })} onConfirmed={refetch}>
                Extend lock
              </TxButton>
            </>
          )}
        </div>
        <div className={styles.fieldGroup}>
          <p className="eyebrow">LP fee revenue</p>
          <p className={styles.stepDetail}>The pool&apos;s own LP fees — separate from the 1% skim. Collecting never touches the locked principal.</p>
          <TxButton variant="btn--ghost" disabled={!a.lockLocked} disabledHint={!a.lockLocked ? "Lock a position first." : undefined}
            build={() => ({ address: requireAddress("lpLocker"), abi: lpLockerAbi, functionName: "collectFees", args: [account as Hex] })} onConfirmed={refetch}>
            Collect LP fees
          </TxButton>
          {a.lockLocked && !a.lockPermanent ? (
            <div style={{ marginTop: "var(--space-4)" }}>
              <IrreversibleAction
                label="Make lock permanent"
                consequence="Converts the lock into a forever-lock. The LP principal becomes unwithdrawable by anyone — including you — for all time. Fee collection keeps working."
                confirmWord="PERMANENT"
                wiring="LPLocker.makePermanent() — one-way"
                state="available"
                build={() => ({ address: requireAddress("lpLocker"), abi: lpLockerAbi, functionName: "makePermanent" })}
                onConfirmed={refetch}
              />
            </div>
          ) : null}
        </div>
      </div>
    </section>
  );
}

/* ─────────────────── 7 · bounty menus ─────────────────── */
function BountyPanel({ a, refetch }: { a: AdminData; refetch: () => void }) {
  const [tiersEth, setTiersEth] = useState(a.tiersWei.map((t) => formatEth(t)).join(", "));
  let parsedTiers: bigint[] = [];
  let tiersError = "";
  try {
    parsedTiers = tiersEth.split(",").map((s) => parseEther(s.trim() as `${number}`)).filter((_, i, arr) => arr.length > 0);
    if (parsedTiers.length === 0 || parsedTiers.length > a.maxTiers) tiersError = `1–${a.maxTiers} tiers`;
    else if (parsedTiers.some((t) => t < a.minTierWei || t > a.maxTierWei))
      tiersError = `each ${formatEth(a.minTierWei)}–${formatEth(a.maxTierWei)} ETH`;
    else {
      for (let i = 1; i < parsedTiers.length; i++) if (parsedTiers[i] <= parsedTiers[i - 1]) tiersError = "ascending order";
    }
  } catch {
    tiersError = "invalid number";
  }

  return (
    <section id="bounty" className={`plate ${styles.panel}`}>
      <PanelHead n="7" title="Bounty menus" note="You set the menu; the chain does the drawing. Templates cap at the on-chain MAX_SLOTS; prizes live within MIN/MAX_TIER_VALUE." />
      <div className={styles.grid2}>
        <div className={styles.fieldGroup}>
          <p className="eyebrow">Sentence templates ({a.templateCount} / {a.maxTemplates})</p>
          <TemplateList a={a} refetch={refetch} />
          <AddTemplate a={a} refetch={refetch} />
        </div>
        <div className={styles.fieldGroup}>
          <p className="eyebrow">Prize tiers ({formatEth(a.minTierWei)}–{formatEth(a.maxTierWei)} ETH, ≤{a.maxTiers})</p>
          <label className={styles.field}><span>Tiers (ETH, ascending)</span>
            <input className="mono" value={tiersEth} onChange={(e) => setTiersEth(e.target.value)} /></label>
          <p className={tiersError ? styles.sumBad : styles.boundedBounds}>{tiersError ? `— ${tiersError}` : "✓ valid menu"}</p>
          <TxButton variant="btn--ghost" disabled={!!tiersError} disabledHint={tiersError ? "Fix the tier menu." : undefined}
            build={() => ({ address: requireAddress("bountyEngine"), abi: bountyEngineAbi, functionName: "setTiers", args: [parsedTiers] })} onConfirmed={refetch}>
            Save tier menu
          </TxButton>
        </div>
      </div>
    </section>
  );
}

function TemplateList({ a, refetch }: { a: AdminData; refetch: () => void }) {
  return (
    <ul className={styles.templateList}>
      {Array.from({ length: a.templateCount }).map((_, id) => (
        <li key={id} className={styles.templateRow}>
          <span className={styles.templateText}>Template №{id}</span>
          <TxButton variant="btn--ghost"
            build={() => ({ address: requireAddress("bountyEngine"), abi: bountyEngineAbi, functionName: "removeTemplate", args: [BigInt(id)] })} onConfirmed={refetch}>
            Remove
          </TxButton>
        </li>
      ))}
      {a.templateCount === 0 ? <li className={styles.stepDetail}>No templates yet.</li> : null}
    </ul>
  );
}

function AddTemplate({ a, refetch }: { a: AdminData; refetch: () => void }) {
  // Default example uses a leading "The " + spaces around the verb so the
  // rendered sentence has correct gaps. ADJ, NOUN, VERB → "The luminous ember will wander."
  const [slots, setSlots] = useState("ADJ, NOUN, VERB");
  const [fragments, setFragments] = useState("The | | will |.");
  const slotIdx = parseSlots(slots);
  const frags = parseFragments(fragments); // VERBATIM — spaces are literal, never trimmed
  const { ok: valid, error } = validateTemplate(slotIdx, frags, a.maxSlots);
  const preview = renderTemplate(slotIdx, frags);

  return (
    <div style={{ marginTop: "var(--space-3)" }}>
      <label className={styles.field}><span>Slots (≤{a.maxSlots})</span>
        <input className="mono" value={slots} onChange={(e) => setSlots(e.target.value)} placeholder="ADJ, NOUN, VERB" /></label>
      <label className={styles.field}><span>Fragments</span>
        <input className="mono" value={fragments} onChange={(e) => setFragments(e.target.value)} /></label>
      <p className={styles.boundedBounds}>
        pipe <span className="mono">|</span> separates fragments; <strong>spaces are literal</strong> (kept exactly).
        Need {slotIdx.length + 1} fragments for {slotIdx.length || "n"} slots.
      </p>

      {/* live rendered preview — what a drawn sentence looks like, spacing included */}
      <div className={styles.previewBox}>
        <span className="eyebrow">Preview</span>
        <p className={styles.previewSentence}>{valid ? preview : <span className={styles.previewMuted}>{preview || "…"}</span>}</p>
      </div>

      <p className={valid ? styles.boundedBounds : styles.sumBad}>{valid ? "✓ valid template" : `— ${error}`}</p>
      <TxButton variant="btn--ghost" disabled={!valid} disabledHint={!valid ? "Fix slots/fragments." : undefined}
        build={() => ({ address: requireAddress("bountyEngine"), abi: bountyEngineAbi, functionName: "addTemplate", args: [slotIdx, frags] })} onConfirmed={refetch}>
        Add template
      </TxButton>

      <BulkImport a={a} refetch={refetch} />
    </div>
  );
}

/* Bulk import: paste / load the canonical templates.json and add each entry. */
type RowStatus = "pending" | "running" | "ok" | "fail" | "skipped";
function BulkImport({ a, refetch }: { a: AdminData; refetch: () => void }) {
  const { account, provider, wrongNetwork } = useWallet();
  const [raw, setRaw] = useState("");
  const [parsed, setParsed] = useState<ParsedTemplate[] | null>(null);
  const [parseError, setParseError] = useState<string | null>(null);
  const [statuses, setStatuses] = useState<Record<number, { status: RowStatus; error?: string }>>({});
  const [running, setRunning] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  const doParse = (text: string) => {
    setRaw(text);
    if (!text.trim()) {
      setParsed(null);
      setParseError(null);
      return;
    }
    const r = parseTemplatesJson(text, a.maxSlots);
    setParseError(r.error ?? null);
    setParsed(r.error ? null : r.templates);
    setStatuses({});
  };

  const onFile = (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0];
    if (!f) return;
    f.text().then(doParse);
    if (fileRef.current) fileRef.current.value = "";
  };

  const validCount = parsed?.filter((t) => t.validation.ok).length ?? 0;

  const runImport = async () => {
    if (!parsed || !provider || !account) return;
    setRunning(true);
    const bountyEngine = requireAddress("bountyEngine");
    const publicClient = getPublicClient();
    const walletClient = getWalletClient(provider, account);
    for (let i = 0; i < parsed.length; i++) {
      const t = parsed[i];
      if (!t.validation.ok) {
        setStatuses((s) => ({ ...s, [i]: { status: "skipped", error: t.validation.error } }));
        continue;
      }
      setStatuses((s) => ({ ...s, [i]: { status: "running" } }));
      try {
        const { request } = await publicClient.simulateContract({
          account,
          address: bountyEngine,
          abi: bountyEngineAbi,
          functionName: "addTemplate",
          args: [t.slotIdx, t.fragments],
        });
        const hash = await walletClient.writeContract(request);
        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        setStatuses((s) => ({
          ...s,
          [i]: receipt.status === "reverted" ? { status: "fail", error: "reverted" } : { status: "ok" },
        }));
      } catch (err) {
        const d = decodeError(err);
        setStatuses((s) => ({ ...s, [i]: { status: "fail", error: d.message } }));
        if (d.rejected) break; // user cancelled — stop the run
      }
    }
    setRunning(false);
    refetch();
  };

  return (
    <details className={styles.bulk}>
      <summary className={styles.bulkSummary}>Bulk import (paste / load templates.json)</summary>
      <p className={styles.stepDetail}>
        Loads the canonical set (<span className="mono">assets/templates.json</span>) and adds each
        template — one simulated transaction per entry, with per-row result.
      </p>
      <textarea
        className={`mono ${styles.bulkArea}`}
        rows={5}
        value={raw}
        placeholder='[{ "slots": ["ADJ","NOUN","VERB"], "fragments": ["The "," "," will ","."] }, …]  or  { "templates": [ … ] }'
        onChange={(e) => doParse(e.target.value)}
      />
      <div className={styles.actionsCol}>
        <button type="button" className="btn btn--ghost" onClick={() => fileRef.current?.click()}>Load .json file…</button>
        <input ref={fileRef} type="file" accept=".json,application/json" onChange={onFile} style={{ display: "none" }} />
      </div>
      {parseError ? <p className={styles.sumBad}>— {parseError}</p> : null}
      {parsed ? (
        <>
          <p className={styles.boundedBounds}>
            {parsed.length} parsed · <strong>{validCount}</strong> valid
            {validCount !== parsed.length ? ` · ${parsed.length - validCount} invalid (will skip)` : ""}
          </p>
          <ol className={styles.bulkList}>
            {parsed.map((t, i) => {
              const st = statuses[i]?.status;
              const mark = st === "ok" ? "✓" : st === "fail" ? "✕" : st === "running" ? "…" : st === "skipped" ? "⃠" : t.validation.ok ? "•" : "✕";
              return (
                <li key={i} className={styles.bulkRow}>
                  <span className={styles.bulkMark} data-st={st ?? (t.validation.ok ? "ready" : "invalid")}>{mark}</span>
                  <span className={styles.bulkPreview}>{t.preview || "(empty)"}</span>
                  {!t.validation.ok ? <span className={styles.sumBad}>{t.validation.error}</span> : null}
                  {statuses[i]?.error && st === "fail" ? <span className={styles.sumBad}>{statuses[i].error}</span> : null}
                </li>
              );
            })}
          </ol>
          {/* Custom multi-tx flow (one addTemplate per entry) — not the single-tx TxButton. */}
          <button
            type="button"
            className="btn"
            disabled={running || validCount === 0 || !account || wrongNetwork}
            onClick={() => void runImport()}
          >
            {running ? "Importing…" : `Import ${validCount} template${validCount === 1 ? "" : "s"}`}
          </button>
          {!account ? <p className={styles.stepDetail}>Connect the owner wallet to import.</p> : null}
          {wrongNetwork ? <p className={styles.sumBad}>Wrong network.</p> : null}
        </>
      ) : null}
    </details>
  );
}

/* ─────────────────── 8 · token ownership ─────────────────── */
function TokenOwnerPanel({ a, refetch }: { a: AdminData; refetch: () => void }) {
  return (
    <section id="token-owner" className={`plate ${styles.panel} ${a.tokenRenounced ? styles.panelDead : ""}`}>
      <PanelHead n="8" title="Token ownership" note="WordToken's owner can mint the liquidity allotment and set the burner — until ownership is renounced. Then nobody can, ever again." />
      {a.tokenRenounced ? (
        <div className={styles.deadBox} role="status">
          <p className={styles.deadTitle}>Ownership renounced — permanently disabled</p>
          <ul className={styles.deadList}>
            <li><span className="mono">mintLiquidity</span> — supply sealed at ≤11,000,000 forever</li>
            <li><span className="mono">setBurner</span> — the BurnEngine is the only burner, forever</li>
          </ul>
          <p className={styles.stepDetail}>This panel stays visible as the receipt of that promise.</p>
        </div>
      ) : (
        <div className={styles.grid2}>
          <div className={styles.fieldGroup}>
            <p className="eyebrow">Owner-only token controls</p>
            <p className={styles.stepDetail}>Burner: <span className="mono">{shortAddress(a.burner)}</span></p>
            <p className={styles.stepDetail}>Minting: {a.mintingSealed ? "sealed at 11,000,000" : "open"}</p>
          </div>
          <div className={styles.fieldGroup}>
            <p className="eyebrow">The last step</p>
            <IrreversibleAction
              label="Renounce token ownership"
              consequence="WordToken will have no owner, forever. Nobody — not you, not a future buyer of the project, not a hacker with your key — will ever mint liquidity or change the burner again."
              confirmWord="RENOUNCE"
              wiring="WordToken.renounceOwnership()"
              state="available"
              build={() => ({ address: requireAddress("wordToken"), abi: wordTokenAbi, functionName: "renounceOwnership" })}
              onConfirmed={refetch}
            />
          </div>
        </div>
      )}
    </section>
  );
}

/* ─────────────────── shared ─────────────────── */
function PanelHead({ n, title, note }: { n: string; title: string; note: string }) {
  return (
    <header className={styles.panelHead}>
      <p className="eyebrow">Panel {n}</p>
      <h2 className={styles.panelTitle}>{title}</h2>
      <p className={styles.panelNote}>{note}</p>
    </header>
  );
}