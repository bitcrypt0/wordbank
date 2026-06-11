"use client";

import { useEffect, useRef, useState } from "react";
import { useWallet } from "@/lib/wallet/WalletProvider";
import { shortAddress } from "@/lib/format";
import styles from "./WalletButton.module.css";

/**
 * Wallet connect button — injected wallets only (root AGENTS.md), wired to the
 * real EIP-6963/1193 lifecycle in lib/wallet. Agent 8's five visual states are
 * preserved: disconnected → connecting → connected (pill) | wrong-network.
 * A picker (announced providers) appears when several wallets are installed.
 */
export function WalletButton() {
  const {
    status,
    account,
    wrongNetwork,
    providerInfo,
    providers,
    error,
    initializing,
    connect,
    disconnect,
    switchToMainnet,
  } = useWallet();

  const [pickerOpen, setPickerOpen] = useState(false);
  const wrapRef = useRef<HTMLDivElement>(null);

  // Close the picker on outside click / Escape.
  useEffect(() => {
    if (!pickerOpen) return;
    const onDown = (e: MouseEvent) => {
      if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) {
        setPickerOpen(false);
      }
    };
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setPickerOpen(false);
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [pickerOpen]);

  // Connected + right network → address pill (click to disconnect).
  if (status === "connected" && !wrongNetwork && account) {
    return (
      <button
        type="button"
        className={styles.address}
        title={`${providerInfo?.name ?? "Wallet"} — click to disconnect`}
        onClick={disconnect}
      >
        <span className={styles.dot} aria-hidden="true" />
        <span className="mono">{shortAddress(account)}</span>
      </button>
    );
  }

  // Connected but on the wrong chain → one-click switch.
  if (status === "connected" && wrongNetwork) {
    return (
      <button
        type="button"
        className={`${styles.address} ${styles.wrong}`}
        title="Switch back to Ethereum"
        onClick={() => void switchToMainnet()}
      >
        <span className={`${styles.dot} ${styles.dotWrong}`} aria-hidden="true" />
        Wrong network — switch to Ethereum
      </button>
    );
  }

  // Connecting (wallet prompt open) or restoring a prior session on load.
  if (status === "connecting" || initializing) {
    return (
      <button type="button" className="btn" aria-busy="true" disabled>
        <span className={styles.spinner} aria-hidden="true" />
        {initializing ? "…" : "Connecting…"}
      </button>
    );
  }

  // Disconnected.
  const onConnectClick = () => {
    if (providers.length > 1) {
      setPickerOpen((v) => !v);
    } else {
      void connect(); // single provider (or none → sets a guidance error)
    }
  };

  return (
    <div className={styles.wrap} ref={wrapRef}>
      <button type="button" className="btn" onClick={onConnectClick}>
        Connect wallet
      </button>

      {pickerOpen && providers.length > 1 && (
        <div className={styles.picker} role="menu" aria-label="Choose a wallet">
          {providers.map((p) => (
            <button
              key={p.info.rdns}
              type="button"
              role="menuitem"
              className={styles.pickerItem}
              onClick={() => {
                setPickerOpen(false);
                void connect(p.info.rdns);
              }}
            >
              {p.info.icon ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img className={styles.pickerIcon} src={p.info.icon} alt="" />
              ) : null}
              {p.info.name}
            </button>
          ))}
        </div>
      )}

      {error && providers.length === 0 ? (
        <p className={styles.hint}>
          No injected wallet found. Install a browser wallet (e.g. MetaMask,
          Rabby) and reload to connect.
        </p>
      ) : null}
    </div>
  );
}
