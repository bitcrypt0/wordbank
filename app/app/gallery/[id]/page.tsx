"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useWallet } from "@/lib/wallet/WalletProvider";
import { useTokenDetail } from "@/lib/reads/tokenDetail";
import { requireAddress } from "@/lib/contracts/addresses";
import { rewardsDistributorAbi } from "@/lib/contracts/abis";
import { CATEGORY_LABEL } from "@/lib/mocks/types";
import { MATERIALS, TIERS } from "@/lib/art";
import { TokenArt } from "@/components/TokenArt";
import {
  TierBadge,
  HonorsBadge,
  EmptyState,
  ErrorState,
  PendingState,
  TxButton,
} from "@/components/ui";
import { formatEth, formatWord, shortAddress, timeRemaining } from "@/lib/format";
import { isoFromUnix } from "@/lib/reads/bounties";
import styles from "./token.module.css";

export default function TokenPage() {
  const params = useParams<{ id: string }>();
  const { account } = useWallet();
  const tokenId = Number(params.id);
  const { data: token, status, refetch } = useTokenDetail(tokenId);

  if (status === "pending") {
    return (
      <div className="container" style={{ paddingBlock: "var(--space-8)" }}>
        <PendingState />
      </div>
    );
  }

  if (status === "loading" || !token) {
    return status === "error" ? (
      <div className="container" style={{ paddingBlock: "var(--space-8)" }}>
        <ErrorState
          hint="This token's record couldn't be read. The word and its backing are unaffected — try again."
          onRetry={refetch}
        />
      </div>
    ) : (
      <div className={`container ${styles.layout}`} aria-busy="true">
        <div className="skeleton" style={{ aspectRatio: "1 / 1" }} />
        <div className={styles.facts}>
          <span className="skeleton">№00000</span>
          <span className="skeleton" style={{ fontSize: "var(--text-3xl)" }}>
            loading
          </span>
        </div>
      </div>
    );
  }

  if (!token.exists) {
    return (
      <div className="container" style={{ paddingBlock: "var(--space-8)" }}>
        <EmptyState
          title={`No word at №${params.id}`}
          hint="That tokenId hasn't been minted, or the id was mistyped. The collection runs №0–9999."
        />
        <p style={{ marginTop: "var(--space-4)" }}>
          <Link href="/gallery">← Back to the gallery</Link>
        </p>
      </div>
    );
  }

  // Trait tables are only meaningful post-reveal; pre-reveal these stay undefined
  // so we render the "Unrevealed" placeholder treatment instead of misleading
  // tier/ink/background derived from default-0 indices.
  const material = token.revealed ? MATERIALS[token.material] : undefined;
  const tier = material ? TIERS[material.tier] : "";
  const ink = material?.inks[token.ink];
  const background = material?.backgrounds[token.background];
  const bounty = token.bounties[0];

  return (
    <div className="container">
      <nav className={styles.crumbs} aria-label="Breadcrumb">
        <Link href="/gallery">Gallery</Link>
        <span aria-hidden="true"> / </span>
        <span className="mono">№{token.tokenId}</span>
      </nav>

      <div className={styles.layout}>
        {/* ── The artwork, on its own ground ── */}
        <figure
          className={styles.plate}
          style={{ background: token.honors ? undefined : background?.color }}
        >
          <TokenArt
            tokenId={token.tokenId}
            alt={
              token.revealed
                ? `${token.word} — ${tier} ${material?.name ?? ""}`
                : `№${token.tokenId} — unrevealed`
            }
          />
        </figure>

        {/* ── The record ── */}
        <div className={styles.facts}>
          <p className={`mono ${styles.id}`}>№{token.tokenId}</p>
          <h1 className={styles.word}>{token.revealed ? token.word : "Unrevealed"}</h1>
          <div className={styles.badges}>
            {token.revealed ? (
              <>
                {material ? <TierBadge material={token.material} /> : null}
                {token.honors ? <HonorsBadge /> : null}
                <span className={styles.cat}>{CATEGORY_LABEL[token.category]}</span>
              </>
            ) : (
              <span className="badge">Reveals at sell-out</span>
            )}
            {!token.alive ? (
              <span className="badge" style={{ color: "var(--danger)" }}>
                Unbound — burned
              </span>
            ) : null}
          </div>

          <dl className={styles.traits}>
            {token.revealed ? (
              <>
                <Trait label="Material" value={`${material?.name ?? "—"} · ${tier}`} />
                <Trait label="Ink" value={ink?.name ?? "—"} swatch={token.honors ? undefined : ink?.color} />
                <Trait
                  label="Background"
                  value={background?.name ?? "—"}
                  swatch={token.honors ? undefined : background?.color}
                />
                <Trait
                  label="Lettering"
                  value={
                    token.honors
                      ? "Hand-lettered one-of-one (honors)"
                      : "Fraunces — the collection face"
                  }
                />
              </>
            ) : (
              <Trait
                label="Word & traits"
                value="Unrevealed — assigned at sell-out, then committed against the provenance hash."
              />
            )}
            <Trait
              label="Owner"
              value={
                token.owner ? (
                  <span className="mono">{shortAddress(token.owner)}</span>
                ) : (
                  "— (token burned)"
                )
              }
            />
          </dl>

          <p className={styles.rarityNote}>
            {token.revealed ? (
              <>
                Visual rarity is aesthetic only. {tier} changes nothing about this
                word&apos;s bounty odds, fee share, or backing — the game economy
                is flat across all 10,000 words.
              </>
            ) : (
              <>
                This token is minted and fully backed. Its word and visual traits
                are assigned at sell-out and revealed against the provenance hash
                — rarity is aesthetic only and changes nothing about backing,
                bounty odds, or fee share.
              </>
            )}
          </p>

          {token.alive &&
          account &&
          token.owner &&
          account.toLowerCase() === token.owner.toLowerCase() ? (
            <div className={styles.actions}>
              <TxButton
                build={() => ({
                  address: requireAddress("rewardsDistributor"),
                  abi: rewardsDistributorAbi,
                  functionName: "claimRewards",
                  args: [[BigInt(token.tokenId)]],
                })}
                disabled={token.pendingRewardsWei === 0n}
                disabledHint={token.pendingRewardsWei === 0n ? "Nothing to claim yet." : undefined}
                onConfirmed={refetch}
                confirmedLabel="Claimed ✓"
              >
                Claim {formatEth(token.pendingRewardsWei)} ETH rewards
              </TxButton>
              {token.unbindAvailable ? (
                <Link href={`/unbind/${token.tokenId}`} className="btn btn--danger">
                  Unbind…
                </Link>
              ) : (
                <span
                  className="btn btn--danger"
                  aria-disabled="true"
                  title="Unbinding opens after the reveal, once the collection is revealed and the registry is built (after the public sell-out). The confirm step also types the word, which is assigned at sell-out."
                  style={{ opacity: 0.5, pointerEvents: "none" }}
                >
                  Unbind (after reveal)
                </span>
              )}
            </div>
          ) : null}
        </div>
      </div>

      {/* ── Buyer due diligence — first-class, not a footnote ── */}
      <section className={`plate ${styles.dd}`} aria-labelledby="dd-title">
        <header className={styles.ddHead}>
          <p className="eyebrow">Before you buy</p>
          <h2 id="dd-title" className={styles.ddTitle}>
            Buyer due diligence
          </h2>
          <p className={styles.ddLede}>
            Everything of value attached to №{token.tokenId} is visible
            onchain. This is the full list — check it against any marketplace
            listing.
          </p>
        </header>

        <div className={styles.ddGrid}>
          <DdItem
            ok={token.alive}
            title="Backing intact"
            value={
              token.alive
                ? `${formatWord(token.bondedBalanceWei)} WORD bound`
                : "0 WORD — released at unbind"
            }
            note={
              token.alive
                ? "Held by the WordBank vault, keyed to this tokenId. It travels with every transfer and cannot be separated from the NFT."
                : "This token was unbound: the NFT is burned and its 1,000 WORD were released to the unbinder. It can never be re-minted."
            }
          />
          <DdItem
            ok={token.alive && token.pendingRewardsWei > 0n}
            neutral={!token.alive || token.pendingRewardsWei === 0n}
            title="Pending fee rewards"
            value={`${formatEth(token.pendingRewardsWei)} ETH`}
            note="Accrued holder fee-share, unclaimed. Rewards are keyed to the token, not the wallet — whoever owns it at claim time collects."
          />
          <DdItem
            ok={Boolean(bounty)}
            neutral={!bounty}
            title="Open bounty share"
            value={
              bounty
                ? `${formatEth(bounty.sharePerWordWei)} ETH · ${timeRemaining(isoFromUnix(bounty.deadline))}`
                : "None outstanding"
            }
            note={
              bounty
                ? `This word appeared in sentence #${bounty.eventId}. The share pays the owner at claim time — if it's still unclaimed when you buy, it's yours.`
                : "This word hasn't appeared in a recent unclaimed sentence. Past shares lapse back to the treasury after 7 days."
            }
          />
        </div>

        <footer className={styles.ddVerify}>
          Verify each line yourself — one view call each, no trust required:{" "}
          <span className="mono">bondedBalance(tokenId)</span> ·{" "}
          <span className="mono">pendingRewards(tokenId)</span> ·{" "}
          <span className="mono">isClaimable(eventId, tokenId)</span>
        </footer>
      </section>
    </div>
  );
}

function Trait({
  label,
  value,
  swatch,
}: {
  label: string;
  value: React.ReactNode;
  swatch?: string;
}) {
  return (
    <div className={styles.trait}>
      <dt className="eyebrow">{label}</dt>
      <dd className={styles.traitValue}>
        {swatch ? (
          <span className={styles.swatch} style={{ background: swatch }} aria-hidden="true" />
        ) : null}
        {value}
      </dd>
    </div>
  );
}

function DdItem({
  ok,
  neutral = false,
  title,
  value,
  note,
}: {
  ok: boolean;
  neutral?: boolean;
  title: string;
  value: string;
  note: string;
}) {
  const mark = neutral ? "—" : ok ? "✓" : "✕";
  const tone = neutral ? "var(--ink-faint)" : ok ? "var(--ok)" : "var(--danger)";
  return (
    <div className={styles.ddItem}>
      <span className={styles.ddMark} style={{ color: tone, borderColor: tone }} aria-hidden="true">
        {mark}
      </span>
      <div>
        <p className={styles.ddItemTitle}>{title}</p>
        <p className={`mono ${styles.ddItemValue}`}>{value}</p>
        <p className={styles.ddItemNote}>{note}</p>
      </div>
    </div>
  );
}
