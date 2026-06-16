"use client";

import {
  useProvenance,
  PROVENANCE_HASH_FALLBACK,
  ASSIGNMENTS_GITHUB_URL,
} from "@/lib/reads/provenance";
import { CopyButton } from "./CopyButton";
import styles from "@/app/docs/docs.module.css";

/**
 * The Provenance trust panel on the Docs page. Reads `provenanceHash` +
 * `slotsLocked` live from WordBank (on-chain is the source of truth) and shows:
 *  - the committed hash (monospace + copy) when slots are LOCKED,
 *  - a "not yet committed" state before lock,
 *  - the committed constant as a fallback if the read errors.
 * It explains what the hash proves and how anyone can recompute + verify it.
 */
export function ProvenanceSection() {
  const { data, status } = useProvenance();

  // Resolve what to display across loading / locked / pre-lock / error states.
  const locked = data?.locked ?? false;
  // On a read error (status === "error") fall back to the committed constant so
  // the page still shows the value; flag it so we don't over-claim "on-chain".
  const usingFallback = status === "error";
  const hash = usingFallback ? PROVENANCE_HASH_FALLBACK : data?.hash ?? "";
  // Treat the fallback as the committed value (it is the on-chain commitment).
  const showCommitted = usingFallback || (status === "loaded" && locked);
  const notYetCommitted = status === "loaded" && !locked && !usingFallback;
  const loading = status === "loading";

  return (
    <section id="provenance" className={styles.section}>
      <h2 className={styles.h2}>Provenance — the published fingerprint</h2>
      <p className={styles.note}>
        Before the reveal, WORDBANK commits to the <strong>entire word and
        trait menu</strong> by publishing a single cryptographic fingerprint —
        the <strong>provenance hash</strong> — onchain. Because the hash is
        recorded before anyone can know which token gets which entry, it proves
        the contents were fixed in advance and{" "}
        <strong>cannot have been changed afterward</strong>. It is the standard
        snipe-proof guarantee, made checkable by anyone.
      </p>

      {loading ? (
        <p className={styles.pendingNote} role="status" aria-busy="true">
          ◌ Reading the committed hash onchain…
        </p>
      ) : showCommitted ? (
        <>
          <div className={styles.provBox}>
            <div className={styles.provHead}>
              <span className={styles.provBadge}>✓ Committed onchain</span>
              <CopyButton
                value={hash}
                label="Copy provenance hash"
                className={styles.provCopy}
              />
            </div>
            <code className={styles.provHash}>{hash}</code>
            <p className={styles.provSource}>
              {usingFallback
                ? "Shown from the published commitment (live read unavailable right now)."
                : "Read live from the WordBank contract’s provenanceHash, with slots locked."}
            </p>
          </div>

          <h3 className={styles.h3}>How to verify it yourself</h3>
          <ol className={styles.numbered}>
            <li>
              Download the public assignment file,{" "}
              <a
                href={ASSIGNMENTS_GITHUB_URL}
                target="_blank"
                rel="noopener noreferrer"
              >
                assets/assignments.json
              </a>
              , from the project’s public GitHub repo.
            </li>
            <li>
              Compute its <span className="mono">keccak256</span> hash (the exact
              bytes of the file).
            </li>
            <li>
              Confirm it matches the hash above — and the same value returned by{" "}
              <span className="mono">provenanceHash()</span> on the WordBank
              contract. If all three agree, the menu is provably the one
              committed at launch.
            </li>
          </ol>
        </>
      ) : notYetCommitted ? (
        <div className={styles.provBox}>
          <span className={`${styles.provBadge} ${styles.provBadgePending}`}>
            ◌ Not yet committed
          </span>
          <p className={styles.provSource}>
            The word and trait slots haven’t been locked onchain yet, so there
            is no committed fingerprint to show. The provenance hash appears here
            — and becomes permanent — the moment{" "}
            <span className="mono">slotsLocked</span> is set, before the reveal.
          </p>
        </div>
      ) : (
        // status === "pending" (no deployment yet)
        <p className={styles.pendingNote} role="status">
          ◌ The provenance hash publishes onchain when the collection deploys
          and its slots are locked.
        </p>
      )}

      <p className={styles.note}>
        <strong>What this does and doesn’t prove.</strong> The provenance hash
        fixes the <em>menu</em> — the full set of words and traits that exist in
        the collection. It is <strong>not</strong> the reveal: which specific
        token receives which entry is decided <em>separately</em>, by a future
        block hash nobody can predict, and is revealed only at sellout. So this
        hash proves the contents were sealed in advance; the per-token
        assignment stays unknowable until the reveal.
      </p>
    </section>
  );
}
