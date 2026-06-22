import Link from "next/link";
import { CONTRACTS, etherscanUrl } from "@/lib/mocks/contracts";
import { ProvenanceSection } from "@/components/ProvenanceSection";
import styles from "./docs.module.css";

export const metadata = { title: "Docs" };

/**
 * The honest pages — rewritten 2026-06-22 for the WORD relaunch (standalone token,
 * staking, fixed 25/25/50 fee split, migration, UNCX lock). The NFT collection,
 * art, provenance and daily game are unchanged from the original launch.
 */
export default function DocsPage() {
  return (
    <div className={`container ${styles.page}`}>
      <header className={styles.head}>
        <p className="eyebrow">How it works</p>
        <h1 className={styles.title}>WORDBANK, in plain English</h1>
        <p className={styles.lede}>
          Every figure on this page is enforced by smart-contract code, not by
          promise. Where a guarantee is structural — the code makes it
          impossible to violate — we say so. Where a protection is real but
          imperfect, we say that too (see Honest limits).
        </p>
      </header>

      <nav className={styles.toc} aria-label="Contents">
        <a href="#what">In one minute</a>
        <a href="#relaunch">The relaunch</a>
        <a href="#assets">The two assets</a>
        <a href="#words">The words</a>
        <a href="#art">The art</a>
        <a href="#provenance">Provenance</a>
        <a href="#fees">The fee</a>
        <a href="#staking">Staking</a>
        <a href="#game">The daily game</a>
        <a href="#rewards">NFT rewards</a>
        <a href="#migrate">Migrating old WORD</a>
        <a href="#lock">The liquidity lock</a>
        <a href="#rug">Can the team rug?</a>
        <a href="#limits">Honest limits</a>
        <a href="#contracts">The contracts</a>
        <a href="#life">The life of a word</a>
      </nav>

      {/* ── 1 · what ── */}
      <section id="what" className={styles.section}>
        <h2 className={styles.h2}>What WORDBANK is, in one minute</h2>
        <p className={styles.note}>
          WORDBANK is a collection of <strong>10,000 NFTs, where each NFT is a
          single word</strong> — the word itself, its artwork, everything —
          stored and drawn entirely on the Ethereum blockchain. There are no
          image servers and no IPFS links; if Ethereum exists, the art exists.
        </p>
        <p className={styles.note}>Three things make it more than a picture collection:</p>
        <ol className={styles.numbered}>
          <li>
            <strong>A daily word game</strong> assembles a sentence out of
            randomly chosen living words and pays an ETH prize, split among the
            owners of the words it used.
          </li>
          <li>
            <strong>WORD, a standalone token you stake to earn.</strong> A 1%
            fee on all WORD/ETH trading pays out in ETH — half of it to people
            who stake WORD, continuously.
          </li>
          <li>
            <strong>A shared income stream.</strong> That same 1% fee also pays
            word-NFT holders and funds the game's prize treasury. No emissions,
            no inflation — fees or nothing.
          </li>
        </ol>
        <p className={styles.note}>
          Nobody — including the team — can mint extra WORD, redirect the fee
          split, drain the treasury, or rig the game.{" "}
          <a href="#rug">See "Can the team rug?"</a>
        </p>
      </section>

      {/* ── 2 · relaunch ── */}
      <section id="relaunch" className={styles.section}>
        <h2 className={styles.h2}>The relaunch: why WORD changed</h2>
        <p className={styles.note}>
          In the original design, WORD was <em>bonded to the NFTs</em> — every
          NFT held 1,000 WORD that unbinding released into the market. In
          practice that turned the token into an exit hatch: holders unbound and
          sold, which pushed price down and dried up the trading the whole
          economy depends on.
        </p>
        <p className={styles.note}>
          So WORD was relaunched as a <strong>standalone ERC-20</strong> with a
          fixed 1,000,000 supply, decoupled from the NFTs, and given a real
          reason to be held: <strong>staking</strong>. The new token isn&apos;t
          manufactured by unbinding, and half of every trading fee now flows to
          stakers in ETH. The NFTs keep everything that made them valuable — the
          art, the game, and a share of the fee — and old-WORD holders can{" "}
          <a href="#migrate">migrate</a> to the new token. The original WORD,
          its buy-and-burn, and its backing vault are retired.
        </p>
      </section>

      {/* ── 3 · assets ── */}
      <section id="assets" className={styles.section}>
        <h2 className={styles.h2}>The two assets: WORD and Word NFTs</h2>
        <p className={styles.note}>
          <strong>WORD</strong> is an ordinary ERC-20 token with a{" "}
          <strong>fixed supply of <span className="mono">1,000,000</span></strong>,
          minted once at launch — there is no minting function, no inflation, no
          taxes, no pause button. You earn on WORD by{" "}
          <a href="#staking">staking</a> it; its supply never grows.
        </p>
        <p className={styles.note}>
          <strong>Word NFTs</strong> are the 10,000 collectibles (ERC-721). Each
          holds a word, its category (noun / verb / adjective / adverb), and its
          onchain visual traits. NFT holders earn a share of the trading fee and
          can win the daily game&apos;s prizes — the NFT is your membership in the
          collection&apos;s income, the art, and the game.
        </p>
        <table className={styles.table}>
          <thead>
            <tr>
              <th scope="col">WORD supply</th>
              <th scope="col">Amount</th>
              <th scope="col">Where it lives</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Pool liquidity</td>
              <td className="mono">~700,000 WORD</td>
              <td>Seeded into the trading pool, locked on UNCX</td>
            </tr>
            <tr>
              <td>Migration reserve</td>
              <td className="mono">~300,000 WORD</td>
              <td>Held by the migrator for old-WORD holders to claim</td>
            </tr>
            <tr>
              <td>
                <strong>Total</strong>
              </td>
              <td className="mono">
                <strong>1,000,000 WORD</strong>
              </td>
              <td>Fixed forever</td>
            </tr>
          </tbody>
        </table>
        <p className={styles.note}>
          The entire supply enters circulation through the pool and through
          migration — there is no team allocation and no treasury of WORD to
          unlock.
        </p>
      </section>

      {/* ── 4 · words ── */}
      <section id="words" className={styles.section}>
        <h2 className={styles.h2}>The words: how 10,000 were chosen — all unique</h2>
        <p className={styles.note}>
          The words are <strong>already decided and finalized</strong>,
          selected by an open, rules-based process — not hand-picked, not
          random gibberish — from three trusted public sources: WordNet
          (Princeton&apos;s standard dictionary database), a 50,000-word English
          frequency list (favoring words people recognize), and a public
          profanity blocklist.
        </p>
        <ul className={styles.plainList}>
          <li>Single lowercase words, 3–12 letters, genuine dictionary words.</li>
          <li>Common, recognizable words first (frequency-ranked).</li>
          <li>
            Excluded: filler words (<em>the, and, but</em>), proper nouns
            (<em>Ohio, June</em>), and irregular forms (<em>went, feet</em>) —
            all of which read badly in a generated sentence.
          </li>
          <li>
            Deliberately noun- and verb-heavy, so the game keeps building
            sentences even late in the collection&apos;s life.
          </li>
        </ul>
        <table className={styles.table}>
          <thead>
            <tr>
              <th scope="col">Category</th>
              <th scope="col">Count</th>
            </tr>
          </thead>
          <tbody>
            <tr><td>Nouns</td><td className="mono">4,999</td></tr>
            <tr><td>Verbs</td><td className="mono">2,500</td></tr>
            <tr><td>Adjectives</td><td className="mono">1,701</td></tr>
            <tr><td>Adverbs</td><td className="mono">800</td></tr>
            <tr>
              <td><strong>Total</strong></td>
              <td className="mono"><strong>10,000</strong></td>
            </tr>
          </tbody>
        </table>
        <p className={styles.note}>
          <strong>Are all 10,000 guaranteed unique? Yes — checked twice.</strong>{" "}
          The generator assigns every word exactly once; then a separate
          validation program independently re-reads the finished list and
          verifies exactly 10,000 entries, no duplicates, every letter supported
          by the onchain font, and all 25 honors words present.
        </p>
        <h3 className={styles.h3}>The 25 honors words (the one-of-ones)</h3>
        <p className={styles.note}>
          Twenty-five crypto-culture words are 1/1 &quot;honors&quot; pieces, rendered
          in bespoke hand-styled lettering instead of the collection&apos;s
          typeface. They play exactly like any other word — special looks, zero
          gameplay advantage.
        </p>
      </section>

      {/* ── 5 · art ── */}
      <section id="art" className={styles.section}>
        <h2 className={styles.h2}>The art: how a word becomes onchain artwork</h2>
        <p className={styles.note}>
          Every image is generated <strong>live, onchain, from code</strong> —
          there is no stored picture file. When a marketplace asks for a
          token&apos;s image, the Renderer assembles it on the spot: one typeface
          across the whole collection (Fraunces, embedded in the image); a
          material the word is &quot;written on&quot; — paper, parchment, slate, stained
          glass, gold leaf and more, in rarity tiers from Common to Legendary;
          and an ink and background color chosen so the result is always
          legible. The 25 honors words swap in their bespoke lettering.
        </p>
        <p className={styles.note}>
          <strong>Crucial fairness rule: visual rarity has zero effect on the
          game or rewards.</strong> A Legendary gold-leaf word and a Common paper
          word have identical bounty odds and identical fee share. The game and
          reward contracts are built so they literally cannot read a word&apos;s
          looks.
        </p>
        <p className={styles.note}>
          <strong>Everything is fully onchain.</strong> The font, the material
          designs, and the 25 bespoke artworks live in the contracts themselves.
          No server, no IPFS — the artwork is as permanent as Ethereum.
        </p>
        <h3 className={styles.h3}>Snipe-proof fairness (provenance)</h3>
        <p className={styles.note}>
          WORDBANK uses the standard provenance method: the full, shuffled
          word-and-trait assignment is locked behind a published fingerprint
          before the reveal, and which token gets which word is fixed only
          afterward, using a future Ethereum block&apos;s hash that nobody can
          predict or control. Until that moment,{" "}
          <strong>nobody — including the team — knows which token gets which
          word.</strong>
        </p>
      </section>

      {/* ── 5b · provenance (live on-chain hash) ── */}
      <ProvenanceSection />

      {/* ── 6 · fees ── */}
      <section id="fees" className={styles.section}>
        <h2 className={styles.h2}>The money: a 1% fee, split three ways</h2>
        <p className={styles.note}>
          WORDBANK&apos;s entire ongoing economy runs on{" "}
          <strong>one source: a 1% fee on every trade through the official
          WORD/ETH pool</strong> on Uniswap. The fee is always taken in ETH, and
          a permanent, hardcoded split sends it three ways — there is no admin
          lever to re-weight it:
        </p>
        <table className={styles.table}>
          <thead>
            <tr>
              <th scope="col">Slice</th>
              <th scope="col">Goes to</th>
              <th scope="col">Purpose</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td className="mono">50%</td>
              <td>WORD stakers</td>
              <td>Paid in ETH, pro-rata to staked WORD (<a href="#staking">staking</a>)</td>
            </tr>
            <tr>
              <td className="mono">25%</td>
              <td>NFT holder rewards</td>
              <td>Paid equally across all living word NFTs</td>
            </tr>
            <tr>
              <td className="mono">25%</td>
              <td>Bounty treasury</td>
              <td>Funds the daily game&apos;s prizes</td>
            </tr>
          </tbody>
        </table>
        <p className={styles.note}>
          A public &quot;flush&quot; lets anyone push collected fees to their
          destinations, so the money never depends on the team showing up. There
          is no buy-and-burn — the relaunch token is fixed-supply, so its value
          comes from the staking yield and scarcity, not from burning.
        </p>
        <p className={styles.note}>
          Separately, WORDBANK asks for a <strong>3% royalty</strong> on NFT
          resales, which lands in a dedicated <strong>RoyaltySplitter</strong>{" "}
          contract — ownerless, with the destinations frozen at deploy. (NFT
          royalties are paid voluntarily by marketplaces — see Honest limits.)
        </p>
      </section>

      {/* ── 7 · staking ── */}
      <section id="staking" className={styles.section}>
        <h2 className={styles.h2}>Staking — the reason to hold WORD</h2>
        <p className={styles.note}>
          Stake WORD and you earn <strong>50% of every swap fee, paid in
          ETH</strong>, continuously and pro-rata to your share of the total
          staked. <Link href="/staking">The staking page is here.</Link> Key
          properties:
        </p>
        <ul className={styles.plainList}>
          <li><strong>Rewards are ETH</strong>, not more WORD — there is no token emission or dilution.</li>
          <li><strong>Stake and unstake anytime</strong>, with no lock-up. Claim accrued ETH whenever you like.</li>
          <li><strong>Your share is exact</strong>, tracked by an efficient accumulator — no looping over stakers, no snapshots, no stranded dust.</li>
          <li><strong>Staking is also a sink:</strong> staked WORD is out of the float, which is the point — it rewards holding instead of dumping.</li>
        </ul>
      </section>

      {/* ── 8 · game ── */}
      <section id="game" className={styles.section}>
        <h2 className={styles.h2}>The daily game</h2>
        <p className={styles.note}>
          The protocol&apos;s beating heart: <strong>one sentence per day, drawn
          from living words, paying an ETH prize.</strong>{" "}
          <Link href="/game">The console is here.</Link> It&apos;s unchanged by the
          relaunch — now funded by the 25% bounty slice of the fee.
        </p>
        <h3 className={styles.h3}>How a sentence is made (commit-reveal)</h3>
        <ol className={styles.numbered}>
          <li>
            <strong>Commit.</strong> Any word-NFT holder opens the day&apos;s draw
            by posting a small bond, which records a target block about 3 minutes
            in the future.
          </li>
          <li>
            <strong>Reveal.</strong> Once the target block passes,{" "}
            <strong>anyone</strong> can trigger the reveal. The contract uses
            that block&apos;s hash — unknowable at commit time — to compose a
            sentence from living words, pick a prize, and lock it. The revealer
            earns 2% of the prize, and the committer&apos;s bond refunds.
          </li>
        </ol>
        <p className={styles.note}>
          Prizes are drawn from a menu (up to <span className="mono">0.5 ETH</span>),
          chosen randomly among only the tiers the treasury can currently afford,
          and split equally among the sentence&apos;s words. Each share waits{" "}
          <strong>7 days</strong> and is paid by <strong>claim-time
          ownership</strong> — whoever owns the word when they claim gets its
          share (so buying a winning word before its deadline buys its unclaimed
          prize too). Unclaimed shares sweep back to the treasury.
        </p>
      </section>

      {/* ── 9 · rewards ── */}
      <section id="rewards" className={styles.section}>
        <h2 className={styles.h2}>NFT holder rewards</h2>
        <p className={styles.note}>
          The 25% NFT-rewards slice splits <strong>equally across every living
          NFT</strong>, continuously, using an efficient accounting method that
          pays everyone their exact share without looping through 10,000 holders.
        </p>
        <ul className={styles.plainList}>
          <li>
            <strong>Rewards travel with the NFT.</strong> Sell a word and any
            unclaimed rewards go to whoever holds it at claim time — a public
            view lets buyers check the pending amount before purchase.
          </li>
          <li><strong>Claim anytime</strong>, in batches, with no deadline.</li>
          <li><strong>Fresh activity can&apos;t steal old rewards</strong> — an NFT earns only from fees that arrive while it&apos;s registered.</li>
        </ul>
      </section>

      {/* ── 10 · migrate ── */}
      <section id="migrate" className={styles.section}>
        <h2 className={styles.h2}>Migrating from the old WORD</h2>
        <p className={styles.note}>
          Holders of the original WORD aren&apos;t left behind. A snapshot of every
          old-WORD holder was taken (contracts excluded), and each eligible
          wallet can convert to the new token: you <strong>burn your snapshot
          balance of old WORD and receive a pro-rata share of the migration
          reserve</strong> (~300,000 new WORD). <Link href="/migrate">The
          migration page is here.</Link>
        </p>
        <ul className={styles.plainList}>
          <li><strong>No deadline</strong> — the reserve stays claimable in perpetuity.</li>
          <li><strong>Eligibility and amounts are fixed by the snapshot</strong> (a published Merkle root), so buying old WORD now grants nothing, and the amounts can&apos;t be altered.</li>
          <li><strong>One-way:</strong> migrating burns the old token. There is no team key that can withdraw the reserve.</li>
        </ul>
      </section>

      {/* ── 11 · lock ── */}
      <section id="lock" className={styles.section}>
        <h2 className={styles.h2}>The liquidity lock</h2>
        <p className={styles.note}>
          The anti-rug guarantee. The WORD + ETH seeded into the trading pool is
          held as a position <strong>locked on UNCX (Unicrypt)</strong>, the
          widely-used third-party liquidity locker — not in a team wallet. The
          lock and its duration are publicly verifiable on UNCX, so anyone can
          confirm the liquidity is genuinely locked and for how long.
        </p>
      </section>

      {/* ── 12 · rug ── */}
      <section id="rug" className={styles.section}>
        <h2 className={styles.h2}>Can the team rug?</h2>
        <p className={styles.note}>
          No. WORDBANK is built so that even a fully compromised team key{" "}
          <strong>cannot</strong> steal or destroy what matters. The following
          are structurally impossible — enforced by contract code, not by
          anyone&apos;s promise:
        </p>
        <ul className={styles.plainList}>
          <li>Cannot mint WORD — the supply is fixed at 1,000,000 with no minting function at all.</li>
          <li>Cannot change the fee split — the 25 / 25 / 50 split is hardcoded with no setter.</li>
          <li>Cannot withdraw the migration reserve — the migrator has no owner or admin path.</li>
          <li>Cannot withdraw staked WORD or accrued staking rewards — they belong to stakers.</li>
          <li>Cannot pull the pool liquidity — it is locked on UNCX.</li>
          <li>Cannot rig the daily draw — words and prize are chosen by blockchain randomness, never by a person.</li>
          <li>Cannot change the word list once locked behind its published fingerprint.</li>
        </ul>
        <p className={styles.note}>
          The new contracts were reviewed contract-by-contract by a security pass
          and an extensive automated test suite (including fuzzing). The only
          tunable knob on the fee hook is the rate itself, capped at 2%.
        </p>
      </section>

      {/* ── 13 · honest limits ── */}
      <section id="limits" className={styles.section}>
        <h2 className={styles.h2}>Honest limits</h2>
        <p className={styles.note}>
          The things this protocol bounds but cannot fully prevent. We&apos;d
          rather you read them here than discover them later. None put funds at
          risk.
        </p>
        <ul className={styles.limits}>
          <li>
            <strong>Royalties are a request, not a rule.</strong> Marketplace
            royalties (capped at 10% onchain) are a signal marketplaces honor
            voluntarily. A marketplace that ignores them pays nothing, and no
            contract can force it.
          </li>
          <li>
            <strong>The launch whale-guard raises costs; it doesn&apos;t stop
            whales.</strong> For up to an hour after trading opens, single buys
            above a set size revert. A determined buyer can split across
            transactions and wallets — paying more fees and price impact per
            slice. That friction is the whole promise.
          </li>
          <li>
            <strong>The old WORD still exists on-chain.</strong> The original
            token and its thin, locked pool weren&apos;t deleted (they can&apos;t be) —
            they&apos;re simply abandoned. Always trade and stake the{" "}
            <em>new</em> WORD; verify the contract address from the{" "}
            <a href="#contracts">contracts list</a>.
          </li>
          <li>
            <strong>Visual rarity is worth exactly nothing.</strong> A
            gold-leaf Legendary and a paper Common have identical bounty odds
            and identical fee share. (A guarantee, listed here only to be
            explicit.)
          </li>
        </ul>
      </section>

      {/* ── 14 · contracts ── */}
      <section id="contracts" className={styles.section}>
        <h2 className={styles.h2}>The contracts</h2>
        <p className={styles.note}>
          The active relaunch contracts, the original contracts they reuse, and
          the deprecated original WORD economy — all verified on Etherscan with
          public source code.
        </p>
        <p className={styles.pendingNote} role="status">
          ◌ Any link still showing &quot;pending&quot; publishes the moment that contract
          is verified.
        </p>
        <ul className={styles.contractList}>
          {CONTRACTS.map((c) => {
            const url = etherscanUrl(c);
            return (
              <li key={c.name} className={styles.contractRow}>
                <div className={styles.contractText}>
                  <span className={styles.contractName}>{c.name}</span>
                  <span className={styles.contractDesc}>{c.description}</span>
                </div>
                {url ? (
                  <a
                    href={url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className={styles.contractLink}
                  >
                    Etherscan ↗
                  </a>
                ) : (
                  <a
                    href="#contracts"
                    className={`${styles.contractLink} ${styles.contractPending}`}
                    aria-disabled="true"
                    title="Address publishes at deployment"
                  >
                    Etherscan — pending
                  </a>
                )}
              </li>
            );
          })}
        </ul>
      </section>

      {/* ── 15 · life ── */}
      <section id="life" className={styles.section}>
        <h2 className={styles.h2}>The life of a word, end to end</h2>
        <ol className={styles.numbered}>
          <li>
            <strong>Hold.</strong> Your word NFT earns its equal share of the
            25% rewards stream, continuously, for as long as you hold it.
          </li>
          <li>
            <strong>Play.</strong> Some days the sentence draws your word — and
            its share of an ETH prize is yours to claim within 7 days.
          </li>
          <li>
            <strong>Stake.</strong> Hold WORD and stake it to earn half of every
            trading fee in ETH — the token&apos;s core utility.
          </li>
          <li>
            <strong>Trade.</strong> Sell the NFT and any pending rewards and
            prizes travel with it automatically; a buyer can verify what&apos;s
            pending before they pay.
          </li>
        </ol>
        <p className={styles.note}>
          Meanwhile, every trade in the pool feeds all of this — paying stakers,
          rewarding NFT holders, and funding the game — with no inflation, no
          team emissions, and no off-switch.
        </p>
      </section>

      <footer className={styles.docsFooter}>
        <p>Nothing here is financial advice.</p>
      </footer>
    </div>
  );
}
