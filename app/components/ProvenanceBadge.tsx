"use client";

import Link from "next/link";
import { useProvenance, PROVENANCE_HASH_FALLBACK } from "@/lib/reads/provenance";
import { truncateHash } from "@/lib/format";
import styles from "./SiteFooter.module.css";

/**
 * Compact, high-visibility provenance reference for the site footer. Shows the
 * truncated committed hash (e.g. 0xd164…ffd1) read live onchain, linking to the
 * full Docs Provenance section. Renders nothing distracting before the menu is
 * committed — it shows a quiet "not yet committed" note instead.
 */
export function ProvenanceBadge() {
  const { data, status } = useProvenance();

  const usingFallback = status === "error";
  const locked = data?.locked ?? false;
  const committed = usingFallback || (status === "loaded" && locked);
  const hash = usingFallback ? PROVENANCE_HASH_FALLBACK : data?.hash ?? "";

  if (status === "loading") {
    return (
      <Link href="/docs#provenance" className={styles.provLink} title="Provenance">
        Provenance: <span className="mono">…</span>
      </Link>
    );
  }

  if (committed && hash) {
    return (
      <Link
        href="/docs#provenance"
        className={styles.provLink}
        title="Verify provenance — keccak256(assets/assignments.json)"
      >
        Provenance <span className="mono">{truncateHash(hash)}</span>
      </Link>
    );
  }

  // Pre-lock / pending — keep it tasteful and quiet.
  return (
    <Link href="/docs#provenance" className={styles.provLink} title="Provenance">
      Provenance: <span className="mono">pending</span>
    </Link>
  );
}
