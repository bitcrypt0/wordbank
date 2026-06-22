import Link from "next/link";
import { WordbankGlyph } from "./Logo";
import { ProvenanceBadge } from "./ProvenanceBadge";
import styles from "./SiteFooter.module.css";

export function SiteFooter() {
  return (
    <footer className={styles.footer}>
      <div className={`container ${styles.inner}`}>
        <div className={styles.brand}>
          <WordbankGlyph size={22} ground="var(--paper)" ink="var(--ink)" />
          <p className={styles.tagline}>
            Ten thousand words, fully onchain. Each one backed by 1,000 WORD.
          </p>
        </div>
        <nav aria-label="Footer" className={styles.cols}>
          <div>
            <p className={styles.colTitle}>Protocol</p>
            <Link href="/gallery">Gallery</Link>
            <Link href="/game">Daily Game</Link>
            <Link href="/rewards">Dashboard</Link>
            <Link href="/token">WORD token</Link>
            <Link href="/staking">Stake WORD</Link>
            <Link href="/migrate">Migrate</Link>
          </div>
          <div>
            <p className={styles.colTitle}>Read</p>
            <Link href="/docs#what">How it works</Link>
            <Link href="/docs#staking">Earn by staking</Link>
            <Link href="/docs#limits">Honest limits</Link>
            <Link href="/docs#contracts">The contracts</Link>
          </div>
        </nav>
      </div>
      <div className={`container ${styles.legal}`}>
        <span>WORDBANK — the word is the art.</span>
        <ProvenanceBadge />
        <span className="mono">fully onchain · Ethereum mainnet</span>
      </div>
    </footer>
  );
}
