"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { WordbankLockup } from "./Logo";
import { WalletButton } from "./WalletButton";
import styles from "./SiteHeader.module.css";

const NAV = [
  { href: "/gallery", label: "Gallery" },
  { href: "/game", label: "Daily Game" },
  { href: "/rewards", label: "Dashboard" },
  { href: "/token", label: "WORD" },
  { href: "/staking", label: "Stake" },
  { href: "/migrate", label: "Migrate" },
  { href: "/docs", label: "Docs" },
] as const;

export function SiteHeader() {
  const pathname = usePathname();
  return (
    <header className={styles.header}>
      <div className={`container ${styles.inner}`}>
        <Link href="/" className={styles.brand} aria-label="WORDBANK home">
          <WordbankLockup />
        </Link>
        <nav aria-label="Primary" className={styles.nav}>
          {NAV.map((item) => {
            const active =
              pathname === item.href || pathname.startsWith(item.href + "/");
            return (
              <Link
                key={item.href}
                href={item.href}
                className={`${styles.navLink} ${active ? styles.active : ""}`}
                aria-current={active ? "page" : undefined}
              >
                {item.label}
              </Link>
            );
          })}
        </nav>
        <div className={styles.wallet}>
          <WalletButton />
        </div>
      </div>
    </header>
  );
}
