"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import {
  useGalleryPage,
  useGalleryById,
  useHonorsScan,
  type GalleryItem,
} from "@/lib/reads/gallery";
import { CATEGORY_LABEL, type Category } from "@/lib/mocks/types";
import { MATERIALS, TIERS } from "@/lib/art";
import { TokenArt } from "@/components/TokenArt";
import {
  TierBadge,
  HonorsBadge,
  EmptyState,
  ErrorState,
  PendingState,
} from "@/components/ui";
import styles from "./gallery.module.css";

const CATEGORIES: (Category | "ALL")[] = ["ALL", "NOUN", "VERB", "ADJ", "ADV"];
const TIER_FILTERS = ["All tiers", ...TIERS];
const PAGE = 48;

function matchesTier(t: GalleryItem, tier: string): boolean {
  if (tier === "All tiers") return true;
  if (t.material === undefined) return false; // pre-reveal placeholders have no tier
  return !!MATERIALS[t.material] && TIERS[MATERIALS[t.material].tier] === tier;
}

export default function GalleryPage() {
  const router = useRouter();
  const [q, setQ] = useState("");
  const [ddId, setDdId] = useState("");
  const [cat, setCat] = useState<Category | "ALL">("ALL");
  const [tier, setTier] = useState("All tiers");
  const [honorsOnly, setHonorsOnly] = useState(false);
  const [limit, setLimit] = useState(PAGE);

  // Three mutually-exclusive modes. A numeric search is a direct token lookup;
  // honors-only scans the whole collection; otherwise we paginate the browse.
  const trimmed = q.trim();
  const idMode = /^\d+$/.test(trimmed);
  const honorsMode = honorsOnly && !idMode;
  const browseMode = !idMode && !honorsMode;

  const browse = useGalleryPage(cat, limit, browseMode);
  const byId = useGalleryById(trimmed); // self-disables unless numeric
  const honors = useHonorsScan(honorsMode);

  // Reveal state drives whether trait-dependent filters/search work. It comes
  // from whichever query has loaded data; default to "revealed" (no banner)
  // until we actually know, so we don't flash the pre-reveal note while loading.
  const revealed =
    browse.data?.revealed ??
    (byId.data ? byId.data.revealed : undefined) ??
    true;
  const preReveal = revealed === false;

  // Resolve the active result set + status for the current mode.
  let status: string;
  let items: GalleryItem[];
  let total: number | null = null;
  let loadedAll = true;
  if (idMode) {
    status = byId.status;
    items = byId.data ? [byId.data] : [];
  } else if (honorsMode) {
    status = honors.status;
    items = (honors.data ?? []).filter((t) => matchesTier(t, tier));
  } else {
    status = browse.status;
    // Trait-dependent filters (word text, tier) only apply once revealed.
    items = (browse.data?.items ?? []).filter((t) =>
      preReveal
        ? true
        : (!trimmed || (t.word ?? "").toLowerCase().includes(trimmed.toLowerCase())) &&
          matchesTier(t, tier),
    );
    total = browse.data?.total ?? null;
    loadedAll = browse.data?.loadedAll ?? true;
  }
  const loadedCount = browse.data?.items.length ?? 0;

  const refetch = idMode ? byId.refetch : honorsMode ? honors.refetch : browse.refetch;

  return (
    <div className="container">
      <header className={styles.head}>
        <p className="eyebrow">The collection</p>
        <h1 className={styles.title}>Gallery</h1>
        <p className={styles.lede}>
          Every living word, rendered exactly as it lives onchain. Open any
          token for its full record — traits, backing, accrued rewards, and
          open bounty shares.
        </p>
        <form
          className={styles.ddLookup}
          onSubmit={(e) => {
            e.preventDefault();
            if (ddId.trim() !== "") router.push(`/gallery/${ddId.trim()}`);
          }}
        >
          <label htmlFor="dd-id">Buying on a marketplace? Check any token first:</label>
          <input
            id="dd-id"
            className="mono"
            inputMode="numeric"
            pattern="[0-9]*"
            placeholder="№ 0–9999"
            value={ddId}
            onChange={(e) => setDdId(e.target.value.replace(/\D/g, ""))}
          />
          <button type="submit" className="btn btn--ghost">
            Due diligence →
          </button>
        </form>
      </header>

      {/* Pre-reveal note — words/traits/1-of-1s aren't decided until sellout. */}
      {preReveal ? (
        <p className={styles.scanNote}>
          ✦ Pre-reveal: words, traits, and 1-of-1s reveal at sell-out — until
          then, browse by token number. Every minted token below is real and
          shows its pre-reveal placeholder.
        </p>
      ) : null}

      {/* Filter bar */}
      <div className={styles.filters} role="search">
        <input
          type="search"
          className={styles.search}
          placeholder={preReveal ? "Search by token №…" : "Search by word or token №…"}
          aria-label={preReveal ? "Search by token id" : "Search words or token id"}
          value={q}
          onChange={(e) => setQ(e.target.value)}
        />
        <select
          aria-label="Filter by category"
          value={cat}
          disabled={preReveal}
          title={preReveal ? "Categories reveal at sell-out" : undefined}
          onChange={(e) => {
            setCat(e.target.value as Category | "ALL");
            setLimit(PAGE);
          }}
        >
          {CATEGORIES.map((c) => (
            <option key={c} value={c}>
              {c === "ALL" ? "All categories" : CATEGORY_LABEL[c]}
            </option>
          ))}
        </select>
        <select
          aria-label="Filter by rarity tier"
          value={tier}
          disabled={preReveal}
          title={preReveal ? "Rarity tiers reveal at sell-out" : undefined}
          onChange={(e) => setTier(e.target.value)}
        >
          {TIER_FILTERS.map((t) => (
            <option key={t}>{t}</option>
          ))}
        </select>
        <label
          className={styles.honorsToggle}
          title={preReveal ? "1-of-1s reveal at sell-out" : undefined}
          style={preReveal ? { opacity: 0.5 } : undefined}
        >
          <input
            type="checkbox"
            checked={honorsOnly}
            disabled={preReveal}
            onChange={(e) => setHonorsOnly(e.target.checked)}
          />
          Honors only
        </label>
      </div>

      {status === "pending" ? (
        <PendingState
          title="The collection isn't live yet"
          hint="Words appear here as minting opens. 10,000, no more, no less."
        />
      ) : status === "loading" && items.length === 0 ? (
        <div className={styles.grid} aria-busy="true" aria-label="Loading words">
          {honorsMode ? (
            <p className={styles.scanNote}>Finding the 1-of-1s across the whole collection…</p>
          ) : (
            Array.from({ length: 8 }).map((_, i) => (
              <div key={i} className={styles.card}>
                <div className="skeleton" style={{ aspectRatio: "1 / 1" }} />
                <div className={styles.cardMeta}>
                  <span className="skeleton">loading…</span>
                </div>
              </div>
            ))
          )}
        </div>
      ) : status === "error" ? (
        <ErrorState
          hint="The gallery couldn't load the collection. The words are safe onchain — try again."
          onRetry={refetch}
        />
      ) : idMode && items.length === 0 ? (
        <EmptyState
          title={`No token at №${trimmed}`}
          hint={
            preReveal
              ? "That token id isn't minted yet, or the number is out of range (0–9999)."
              : "That token id isn't minted/revealed yet, or the number is out of range (0–9999)."
          }
        />
      ) : items.length === 0 ? (
        <EmptyState
          title={honorsMode ? "No honors match" : "No words match"}
          hint={honorsMode ? "Try a different tier, or clear Honors only." : "Loosen the filters, or load more of the collection."}
        />
      ) : (
        <>
          {honorsMode ? (
            <p className={styles.scanNote}>✦ {items.length} honors one-of-ones found.</p>
          ) : null}
          <div className={styles.grid}>
            {items.map((t) => (
              <Link
                key={t.tokenId}
                href={`/gallery/${t.tokenId}`}
                className={`${styles.card} ${styles.cardLink}`}
              >
                <TokenArt tokenId={t.tokenId} alt={t.revealed ? (t.word ?? `№${t.tokenId}`) : `№${t.tokenId} — unrevealed`} />
                <div className={styles.cardMeta}>
                  <span className={styles.cardWord}>{t.revealed ? t.word : "Unrevealed"}</span>
                  <span className={`mono ${styles.cardId}`}>№{t.tokenId}</span>
                </div>
                {t.revealed ? (
                  <div className={styles.cardBadges}>
                    {t.material !== undefined && MATERIALS[t.material] ? (
                      <TierBadge material={t.material} />
                    ) : null}
                    {t.honors ? <HonorsBadge /> : null}
                    {t.category ? <span className={styles.cardCat}>{CATEGORY_LABEL[t.category]}</span> : null}
                  </div>
                ) : null}
              </Link>
            ))}
          </div>

          {browseMode && total !== null && !loadedAll ? (
            <div style={{ textAlign: "center", marginTop: "var(--space-5)" }}>
              <button
                type="button"
                className="btn btn--ghost"
                disabled={browse.status === "loading"}
                onClick={() => setLimit((n) => n + PAGE)}
              >
                {browse.status === "loading" ? "Loading…" : `Load more (${loadedCount} of ${total})`}
              </button>
            </div>
          ) : null}
        </>
      )}
    </div>
  );
}
