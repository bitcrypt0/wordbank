import Link from "next/link";
import { CONTRACTS, etherscanUrl } from "@/lib/mocks/contracts";
import { ProvenanceSection } from "@/components/ProvenanceSection";
import styles from "./docs.module.css";

export const metadata = { title: "Docs" };

/**
 * The honest pages — expanded from WHITEPAPER-PUBLIC.md (the curated,
 * user-facing source of truth) per the 2026-06-13 owner change order.
 *
 * Protected copy: the "Honest limits" section wording is charter-required;
 * its current form (aligned to the public whitepaper, wallet-cap bullet
 * dropped, Accepted-trade-offs removed) is overseer-authorized by that
 * change order. Don't edit it further without overseer sign-off.
 *
 * Contracts section: links render from lib/mocks/contracts.ts — agent 9
 * fills the per-contract `address` fields at deployment (see HANDOFF.md).
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
        <a href="#assets">The two assets</a>
        <a href="#words">The words</a>
        <a href="#art">The art</a>
        <a href="#provenance">Provenance</a>
        <a href="#fees">The fee</a>
        <a href="#game">The daily game</a>
        <a href="#rewards">Holder rewards</a>
        <a href="#burn">Buy-and-burn</a>
        <a href="#lock">The liquidity lock</a>
        <a href="#rug">Can the team rug?</a>
        <a href="#vault">The 91% question</a>
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
            <strong>Every word NFT is backed by 1,000 WORD tokens</strong>{" "}
            locked inside the collection's vault. The backing travels with the
            NFT automatically on every sale and can never be separated from
            it. You can always "cash out" a word by burning the NFT to release
            its 1,000 WORD.
          </li>
          <li>
            <strong>A daily word game</strong> assembles a sentence out of
            randomly chosen living words and pays an ETH prize, split among
            the owners of the words it used.
          </li>
          <li>
            <strong>A shared income stream.</strong> A 1% fee on all WORD/ETH
            trading splits three ways — to NFT holders as rewards, to the
            game's prize treasury, and to a buy-and-burn that steadily shrinks
            the WORD supply.
          </li>
        </ol>
        <p className={styles.note}>
          Nobody — including the team — can mint extra tokens beyond the fixed
          cap, redirect the backing, drain the treasury, or rig the game.{" "}
          <a href="#rug">See "Can the team rug?"</a>
        </p>
      </section>

      {/* ── 2 · assets ── */}
      <section id="assets" className={styles.section}>
        <h2 className={styles.h2}>The two assets: WORD and Word NFTs</h2>
        <p className={styles.note}>
          <strong>WORD</strong> is an ordinary ERC-20 token. Its supply is
          capped at <span className="mono">11,000,000</span> and can only ever
          shrink from there, via buy-and-burn — never grow. Burning can never
          reduce supply below the WORD currently backing the living NFTs
          (1,000 per alive word); that backing is untouchable. No taxes, no
          transfer tricks, no pause button: a plain, vanilla token.
        </p>
        <p className={styles.note}>
          <strong>Word NFTs</strong> are the 10,000 collectibles (ERC-721).
          Each holds a word, its category (noun / verb / adjective / adverb),
          its visual traits, and a claim on 1,000 WORD locked in the vault on
          its behalf.
        </p>
        <table className={styles.table}>
          <thead>
            <tr>
              <th scope="col"></th>
              <th scope="col">Amount</th>
              <th scope="col">Where it lives</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Backing tokens</td>
              <td className="mono">10,000,000 WORD</td>
              <td>Locked in the WordBank vault, behind the NFTs</td>
            </tr>
            <tr>
              <td>Liquidity tokens</td>
              <td className="mono">1,000,000 WORD</td>
              <td>Seeded into the trading pool</td>
            </tr>
            <tr>
              <td>
                <strong>Total</strong>
              </td>
              <td className="mono">
                <strong>11,000,000 WORD</strong>
              </td>
              <td>—</td>
            </tr>
            <tr>
              <td>Burn floor (dynamic)</td>
              <td className="mono">alive NFTs × 1,000</td>
              <td>The backing can never be burned; the floor falls as NFTs are unbound</td>
            </tr>
          </tbody>
        </table>
        <p className={styles.note}>
          So ~91% of all WORD sits in the vault as backing, and ~9% trades
          freely. This is why a token scanner shows the vault holding ~91% —
          the design working, not a whale. <a href="#vault">More below.</a>
        </p>
      </section>

      {/* ── 3 · words ── */}
      <section id="words" className={styles.section}>
        <h2 className={styles.h2}>The words: how 10,000 were chosen — all unique</h2>
        <p className={styles.note}>
          The words are <strong>already decided and finalized</strong>,
          selected by an open, rules-based process — not hand-picked, not
          random gibberish — from three trusted public sources: WordNet
          (Princeton's standard dictionary database, deciding what's a real
          word and its part of speech), a 50,000-word English frequency list
          (favoring words people recognize and can read aloud), and a public
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
            sentences even late in the collection's life, after many words
            have been burned away.
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
          The generator assigns every word exactly once; then a completely
          separate validation program independently re-reads the finished list
          and verifies exactly 10,000 entries, no duplicates (even ignoring
          capitalization), every letter supported by the onchain font, and all
          25 honors words present with correct categories. There is no path to
          a repeated word.
        </p>
        <h3 className={styles.h3}>The 25 honors words (the one-of-ones)</h3>
        <p className={styles.note}>
          Twenty-five crypto-culture words are 1/1 "honors" pieces, rendered
          in bespoke hand-styled lettering instead of the collection's
          typeface: <em>Rekt, Pepe, Degen, Lambo, Snipe, Liquid, Pump, Dump,
          Rug, Floor, Yield, Swap, Trade, Stake, Airdrop, Farm, Satoshi, Hype,
          Fee, Gas, Sweep, Mint, Dev, Token, Moon.</em> They play exactly like
          any other word — special looks, zero gameplay advantage.
        </p>
      </section>

      {/* ── 4 · art ── */}
      <section id="art" className={styles.section}>
        <h2 className={styles.h2}>The art: how a word becomes onchain artwork</h2>
        <p className={styles.note}>
          Every image is generated <strong>live, onchain, from code</strong> —
          there is no stored picture file. When a marketplace asks for a
          token's image, the Renderer assembles it on the spot: one typeface
          across the whole collection (Fraunces, freely licensed, embedded in
          the image); a material the word is "written on" — paper, parchment,
          slate, stained glass, gold leaf and more, in rarity tiers from
          Common to Legendary; and an ink and solid background color chosen
          from tables that guarantee the result is always legible. The 25
          honors words swap in their bespoke lettering.
        </p>
        <p className={styles.note}>
          <strong>Crucial fairness rule: visual rarity has zero effect on the
          game.</strong> A Legendary gold-leaf word and a Common paper word
          have identical bounty odds, identical reward share, and the
          identical 1,000-WORD backing. The game and reward contracts are
          built so they literally cannot read a word's looks.
        </p>
        <p className={styles.note}>
          <strong>Everything is fully onchain.</strong> The font, the material
          designs, and the 25 bespoke artworks live in the contracts
          themselves. No server, no IPFS — the artwork is as permanent as
          Ethereum.
        </p>
        <h3 className={styles.h3}>Snipe-proof fairness (provenance)</h3>
        <p className={styles.note}>
          A real risk in NFT collections is sniping — bots grabbing the rare
          ones. WORDBANK uses the standard provenance method: the full,
          shuffled word-and-trait assignment is locked behind a published
          fingerprint before the reveal, and which token gets which word is
          fixed only afterward, using a future Ethereum block's hash that
          nobody can predict or control. Until that moment,{" "}
          <strong>nobody — including the team — knows which token gets which
          word.</strong> You can't simulate or cherry-pick your way to a
          Legendary.
        </p>
      </section>

      {/* ── 4b · provenance (live on-chain hash) ── */}
      <ProvenanceSection />

      {/* ── 5 · fees ── */}
      <section id="fees" className={styles.section}>
        <h2 className={styles.h2}>The money: a 1% fee, split three ways</h2>
        <p className={styles.note}>
          WORDBANK's entire ongoing economy runs on{" "}
          <strong>one source: a 1% fee on ETH flowing through the official
          WORD/ETH trading pool</strong> on Uniswap. No emissions, no
          inflation, no treasury unlocks — fees or nothing.
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
              <td>Holder rewards</td>
              <td>Paid out equally across all living NFTs</td>
            </tr>
            <tr>
              <td className="mono">25%</td>
              <td>Bounty treasury</td>
              <td>Funds the daily game's prizes</td>
            </tr>
            <tr>
              <td className="mono">25%</td>
              <td>Buy-and-burn</td>
              <td>Buys WORD and destroys it, shrinking supply</td>
            </tr>
          </tbody>
        </table>
        <p className={styles.note}>
          When there's no WORD to burn right now — supply has caught up to the
          current backing floor — the split automatically becomes two-way,{" "}
          <strong>70% holders / 30% bounty</strong>, so the burn quarter isn't
          wasted. It switches back to three-way whenever there's WORD to burn
          again (for example, after NFTs are unbound and release their
          backing). The split simply follows whether there's anything to burn,
          flush by flush. A public "flush" lets anyone push collected fees to
          their destinations, so the money never depends on the team showing
          up.
        </p>

        <h3 className={styles.h3}>Marketplace royalties — a second stream, split trustlessly</h3>
        <p className={styles.note}>
          Separately from that trading fee, WORDBANK asks for a{" "}
          <strong>3% royalty</strong> whenever a Word NFT is resold on a
          marketplace. Those royalties don't go to a wallet — they land in a
          dedicated contract, the <strong>RoyaltySplitter</strong>, which
          forwards every payment in <strong>equal thirds</strong>:
        </p>
        <table className={styles.table}>
          <thead>
            <tr>
              <th scope="col">Slice</th>
              <th scope="col">Goes to</th>
            </tr>
          </thead>
          <tbody>
            <tr><td className="mono">1/3</td><td>Buy-and-burn</td></tr>
            <tr><td className="mono">1/3</td><td>Bounty treasury (prizes)</td></tr>
            <tr><td className="mono">1/3</td><td>The team</td></tr>
          </tbody>
        </table>
        <p className={styles.note}>
          The three destinations and the equal split are{" "}
          <strong>frozen when the contract is deployed — there are no controls
          to change them, and the contract has no owner to abuse</strong>.
          That's what makes it trustless: holders can verify, once and
          forever, exactly where royalties go. Anyone can trigger the split
          with a public function, and a misbehaving wallet can never jam it —
          the burn and bounty thirds are always paid first.
        </p>
        <p className={styles.note}>
          NFT holders deliberately get <strong>nothing</strong> from
          royalties — they're already paid by the 1% trading fee above. Two
          honest notes: marketplace royalties are paid <em>voluntarily</em> (no
          contract can force a marketplace to honor them — see Honest limits),
          and the 3% rate is adjustable by the admin up to the onchain 10%
          cap, but the equal three-way split itself can never be re-weighted.
        </p>
      </section>

      {/* ── 6 · game ── */}
      <section id="game" className={styles.section}>
        <h2 className={styles.h2}>The daily game</h2>
        <p className={styles.note}>
          The protocol's beating heart: <strong>one sentence per day, drawn
          from living words, paying an ETH prize.</strong>{" "}
          <Link href="/game">The console is here.</Link>
        </p>
        <h3 className={styles.h3}>How a sentence is made (commit-reveal)</h3>
        <ol className={styles.numbered}>
          <li>
            <strong>Commit.</strong> Any word-NFT holder opens the day's draw
            by posting a small 0.01 ETH bond, which records a target block
            about 3 minutes in the future. (The game is also structurally
            locked until the collection has sold out and its word registry is
            built — it cannot start early.)
          </li>
          <li>
            <strong>Reveal.</strong> Once the target block passes,{" "}
            <strong>anyone</strong> can trigger the reveal. The contract uses
            that block's hash — unknowable at commit time — to pick a sentence
            template the living words can fill, fill its blanks (no word
            twice), pick a prize, and lock it. The revealer earns 2% of the
            prize, and the committer's bond refunds.
          </li>
        </ol>
        <p className={styles.note}>
          If nobody reveals within the ~48-minute window, anyone can clear the
          stuck commit; the bond forfeits to the treasury and a fresh draw can
          start. "Start a draw, peek, then sulk" is impossible and
          unprofitable. Sentences come from fill-in-the-blank templates
          (<em>"The [adjective] [noun] [verb] the [noun]."</em>) — whoever
          maintains the templates shapes the <em>style</em> of sentences,
          never the actual words, which the blockchain's randomness alone
          selects.
        </p>
        <h3 className={styles.h3}>Prizes</h3>
        <p className={styles.note}>
          Each sentence's prize is drawn from a menu of{" "}
          <span className="mono">0.05, 0.1, 0.2, 0.25, 0.3, 0.4, or 0.5 ETH</span>,
          chosen randomly among only the tiers the treasury can currently
          afford — so the game starts paying small prizes early and grows into
          bigger ones as fees accumulate. The prize splits equally among the
          sentence's words.
        </p>
        <h3 className={styles.h3}>Claiming — how the right owner is verified</h3>
        <p className={styles.note}>
          Each winning word's share waits <strong>7 days</strong>. A claim is
          paid only after the contract verifies, in order: the event exists;
          it's within the window; that word really is in that sentence; it
          hasn't been claimed; and{" "}
          <strong>the claimant currently owns the word NFT</strong> — checked
          live at the moment of claiming. That last check is "claim-time
          ownership": the prize belongs to whoever owns the word{" "}
          <em>when they claim</em>. A practical consequence — buying a winning
          word before its deadline buys its unclaimed prize too (the{" "}
          <Link href="/gallery">due-diligence panel</Link> shows exactly
          what's claimable before you pay). Unclaimed shares sweep back to the
          treasury after the deadline.
        </p>
      </section>

      {/* ── 7 · rewards ── */}
      <section id="rewards" className={styles.section}>
        <h2 className={styles.h2}>Holder rewards</h2>
        <p className={styles.note}>
          The 50% rewards slice splits <strong>equally across every living
          NFT</strong>, continuously, using an efficient accounting method
          that pays everyone their exact share without ever looping through
          10,000 holders. Key properties:
        </p>
        <ul className={styles.plainList}>
          <li>
            <strong>Rewards travel with the NFT.</strong> Sell a word and any
            unclaimed rewards go to whoever holds it at claim time — a public
            view lets buyers check the exact pending amount before purchase.
          </li>
          <li>
            <strong>Claim anytime</strong>, in batches, with no deadline.
          </li>
          <li>
            <strong>Fresh mints can't steal old rewards</strong> — a new token
            earns only from fees that arrive after it exists.
          </li>
          <li>
            <strong>Burning raises everyone else's rate.</strong> When a word
            is unbound, survivors split future fees among fewer NFTs.
          </li>
        </ul>
      </section>

      {/* ── 8 · burn ── */}
      <section id="burn" className={styles.section}>
        <h2 className={styles.h2}>Buy-and-burn — making WORD deflationary</h2>
        <p className={styles.note}>
          The 25% burn slice gives <strong>WORD token holders</strong> (who
          may own no NFT) a concrete benefit: a steadily shrinking supply. It
          buys WORD on the open market with the collected ETH and destroys
          it — with guardrails:
        </p>
        <ul className={styles.plainList}>
          <li>
            <strong>It can never touch the backing.</strong> Burning can never
            reduce supply below the WORD bound to the living NFTs (1,000 per
            alive word) — a floor enforced by the token itself. The floor
            isn't fixed: as NFTs are unbound the collection shrinks and
            releases backing into circulation, so the floor falls and that
            freed WORD becomes burnable too. Deflation continues for the life
            of the protocol, always stopping short of the live backing.
          </li>
          <li>
            <strong>Anyone can trigger a buyback</strong> — a ~1% keeper tip
            rewards whoever does — so it runs without the team.{" "}
            <Link href="/token">Try it here.</Link>
          </li>
          <li>
            <strong>It buys in small, rate-limited amounts</strong> with an
            onchain slippage guard, limiting price impact and what any
            sandwich trader could extract.
          </li>
          <li>
            <strong>It runs as its own transaction</strong>, never wedged
            inside someone else's trade — a deliberate safety choice.
          </li>
        </ul>
        <p className={styles.note}>
          Whenever supply has caught up to the current floor, the engine simply
          pauses — no leftover ETH sits idle, because the fee split has already
          switched to two-way — and it resumes automatically the next time an
          unbind lowers the floor and frees more WORD to burn.
        </p>
      </section>

      {/* ── 9 · lock ── */}
      <section id="lock" className={styles.section}>
        <h2 className={styles.h2}>The liquidity lock</h2>
        <p className={styles.note}>
          The anti-rug guarantee. The WORD + ETH seeded into the trading pool
          is held as a position <strong>locked for at least 1 year</strong> in
          a dedicated vault. The lock can be <strong>extended but never
          shortened</strong>, and a one-way <strong>"make permanent"</strong>{" "}
          option converts it to forever — the strongest possible trust signal.
          The locker's address and terms are published openly, so anyone can
          verify the liquidity is genuinely locked, and for how long.
        </p>
      </section>

      {/* ── 10 · rug ── */}
      <section id="rug" className={styles.section}>
        <h2 className={styles.h2}>Can the team rug?</h2>
        <p className={styles.note}>
          No. WORDBANK is built so that even a fully compromised team key{" "}
          <strong>cannot</strong> steal or destroy what matters. The following
          are structurally impossible — enforced by contract code, not by
          anyone's promise:
        </p>
        <ul className={styles.plainList}>
          <li>Cannot mint WORD beyond the 11,000,000 cap — and after launch, minting is permanently sealed.</li>
          <li>Cannot burn below the live backing floor (the WORD bound to the currently-living NFTs) — the NFT backing is untouchable.</li>
          <li>Cannot touch or redirect the vault's backing — it releases only 1,000 at a time, to someone burning their own NFT.</li>
          <li>Cannot shorten the liquidity lock — it can only be strengthened.</li>
          <li>Cannot rig the daily draw — words and prize are chosen by blockchain randomness, never by a person.</li>
          <li>Cannot change the word list once locked behind its published fingerprint.</li>
          <li>Cannot starve any fee stream to zero — the splits adjust only within hardcoded limits.</li>
        </ul>
        <p className={styles.note}>
          The contracts were reviewed contract-by-contract by an internal
          security pass and an extensive automated test suite — including
          fuzzing (thousands of randomized action sequences) and a
          mainnet-fork test running the whole life cycle against the real
          Uniswap contracts.
        </p>
      </section>

      {/* ── 11 · vault ── */}
      <section id="vault" className={styles.section}>
        <h2 className={styles.h2}>"Why does one address hold ~91% of WORD?"</h2>
        <p className={styles.note}>
          Open WORD on a token scanner and the top holder owns about 91% of
          supply. <strong>That address is the WordBank vault contract</strong> —
          it holds the 1,000 WORD bound behind each of the 10,000 NFTs
          (10,000,000 of the ~11,000,000 total). It is not a person, not the
          team, and not a whale wallet. Its code can release tokens only one
          way: 1,000 at a time, to an NFT owner burning their token in the
          unbind flow. It cannot trade, cannot vote, cannot rug. The float you
          see trading — roughly 9% — is the liquidity allotment, shrinking
          further as the burn runs. <strong>The vault <em>is</em> the
          product:</strong> it is why every NFT is worth at least its backing.
        </p>
      </section>

      {/* ── 12 · honest limits ── */}
      <section id="limits" className={styles.section}>
        <h2 className={styles.h2}>Honest limits</h2>
        <p className={styles.note}>
          The things this protocol bounds but cannot fully prevent. We'd
          rather you read them here than discover them later. None put funds
          at risk.
        </p>
        <ul className={styles.limits}>
          <li>
            <strong>Royalties are a request, not a rule.</strong> Marketplace
            royalties (capped at 10% onchain) are a signal marketplaces honor
            voluntarily. A marketplace that ignores them pays nothing, and no
            contract can force it.
          </li>
          <li>
            <strong>The launch whale-guard raises costs; it doesn't stop
            whales.</strong> For up to an hour after trading opens, single
            buys above a set size revert. A determined buyer can split across
            transactions and wallets — paying more fees and more price impact
            per slice. That friction is the whole promise.
          </li>
          <li>
            <strong>Visual rarity is worth exactly nothing in the game.</strong>{" "}
            A gold-leaf Legendary and a paper Common have identical bounty
            odds, identical fee share, identical 1,000-WORD backing. (This one
            is a guarantee, listed here only to be explicit.)
          </li>
        </ul>
      </section>

      {/* ── 13 · contracts ── */}
      <section id="contracts" className={styles.section}>
        <h2 className={styles.h2}>The contracts</h2>
        <p className={styles.note}>
          Nine contracts make up WORDBANK. All will be verified on Etherscan
          with public source code.
        </p>
        <p className={styles.pendingNote} role="status">
          ◌ Addresses publish at deployment — the links below go live the
          moment the contracts do.
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

      {/* ── 14 · life ── */}
      <section id="life" className={styles.section}>
        <h2 className={styles.h2}>The life of a word, end to end</h2>
        <ol className={styles.numbered}>
          <li>
            <strong>Hold.</strong> Your word earns its equal share of the 50%
            rewards stream, continuously, for as long as you hold it.
          </li>
          <li>
            <strong>Play.</strong> Some days the sentence draws your word —
            and its share of an ETH prize is yours to claim within 7 days.
          </li>
          <li>
            <strong>Trade.</strong> Sell it, and the backing <em>and</em> all
            pending rewards and prizes travel with it automatically. A buyer
            can verify exactly what's pending before they pay.
          </li>
          <li>
            <strong>Cash out (unbind).</strong> Whenever you want the tokens:
            pending rewards settle to you, the NFT burns forever, and 1,000
            WORD land in your wallet. The collection gets one word smaller —
            raising every survivor's reward rate and bounty odds. There is no
            undo.
          </li>
        </ol>
        <p className={styles.note}>
          Meanwhile, every trade in the pool feeds all of this — rewarding
          holders, funding the game, burning WORD toward its floor — with no
          inflation, no team emissions, and no off-switch.
        </p>
      </section>

      <footer className={styles.docsFooter}>
        <p>Nothing here is financial advice.</p>
      </footer>
    </div>
  );
}
