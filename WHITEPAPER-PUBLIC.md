# WORDBANK — How It Works

*A fully onchain word game on Ethereum: 10,000 word NFTs, each permanently backed by 1,000 WORD tokens, with a daily sentence-bounty game, a continuous holder-rewards stream, and a buy-and-burn that makes the token deflationary — all funded by a 1% fee on trading, and all enforced by code anyone can read.*

**Public edition · Written in plain English · This is the source content for the dApp's Docs page.**

> A note on truthfulness: every figure here is enforced by the smart-contract code, not by promise. Where a guarantee is structural (the code makes it impossible to violate), it says so. Where a protection is real but imperfect, it says that too — see **Honest limits** at the end.

---

## 1. What WORDBANK is, in one minute

WORDBANK is a collection of **10,000 NFTs**, where each NFT *is a single word* — the word itself, its artwork, everything — stored and drawn entirely on the Ethereum blockchain. There are no image servers and no IPFS links; if Ethereum exists, the art exists.

Three things make it more than a picture collection:

1. **Every word NFT is backed by 1,000 WORD tokens** locked inside the collection's vault. That backing travels with the NFT automatically on every sale and can never be separated from it. You can always "cash out" a word by burning the NFT to release its 1,000 WORD.
2. **A daily word game** assembles a sentence out of randomly chosen living words and pays an ETH prize, split among the owners of the words it used.
3. **A shared income stream.** A 1% fee on all WORD/ETH trading is split three ways — to NFT holders as rewards, to the game's prize treasury, and to a buy-and-burn that steadily shrinks the WORD supply.

Nobody — including the team — can mint extra tokens beyond the fixed cap, redirect the backing, drain the treasury, or rig the game. (See **Can the team rug?**)

---

## 2. The two assets: WORD and Word NFTs

WORDBANK has exactly two things you can own.

**WORD** is an ordinary ERC-20 token (the same standard as most crypto tokens). Its supply is capped at **11,000,000** and can only ever shrink from there (via buy-and-burn), never grow. Burning can never reduce supply below the WORD currently backing the living NFTs (1,000 per alive NFT) — that backing is untouchable. It has no taxes, no transfer tricks, no pause button — it's a plain, vanilla token.

**Word NFTs** are the 10,000 collectibles (ERC-721 standard). Each one holds a word, its category (noun / verb / adjective / adverb), its visual traits, and a claim on 1,000 WORD tokens locked in the vault on its behalf.

The relationship between them is the heart of the design:

| | Amount | Where it lives |
|---|---|---|
| Backing tokens | 10,000,000 WORD (10,000 × 1,000) | Locked in the WordBank vault, behind the NFTs |
| Liquidity tokens | 1,000,000 WORD | Seeded into the trading pool |
| **Total** | **11,000,000 WORD** | — |
| Burn floor (dynamic) | the live backing = alive NFTs × 1,000 WORD | The backing can never be burned; the floor falls as NFTs are unbound |

So ~91% of all WORD sits in the vault as backing, and ~9% trades freely. (This is why a token scanner will show the vault contract holding ~91% — that's the design working, not a whale. See **The "91% in one wallet" question**.)

---

## 3. The words: how the 10,000 were chosen, and why they're all unique

The 10,000 words are **already decided and finalized.** They were selected by an open, rules-based process — not hand-picked, and not random gibberish — from three trusted public sources:

- **WordNet** (Princeton University's standard English dictionary database) — decides what counts as a real word and what part of speech it is.
- **A 50,000-word English frequency list** — ranks words by how common they are, so the collection favors words people actually recognize and can read aloud in a sentence.
- **A public profanity blocklist** — keeps the collection clean.

The selection rules, in plain terms:

- Single lowercase words, 3–12 letters, that are genuine dictionary words.
- Common, recognizable words first (frequency-ranked).
- **Excluded:** filler/function words (the, and, but), proper nouns (Ohio, June), and irregular forms (went, feet) — all of which would read badly in a generated sentence.
- The mix is deliberately **noun- and verb-heavy** so the daily game can keep building sentences even late in the collection's life, after many words have been burned away.

The final distribution (including the 25 special "honors" words) is:

| Category | Count |
|---|---|
| Nouns | 4,999 |
| Verbs | 2,500 |
| Adjectives | 1,701 |
| Adverbs | 800 |
| **Total** | **10,000** |

**Are all 10,000 guaranteed unique? Yes — and it's checked twice.** The generator assigns every word exactly once. Then a completely separate validation program independently re-reads the finished list and verifies: exactly 10,000 entries, **no duplicates** (even ignoring capitalization), every letter is supported by the onchain font, and all 25 honors words are present with the correct categories. There is no path to a repeated word.

### The 25 honors words (the one-of-ones)

Twenty-five words are **1/1 "honors" pieces** — crypto-culture words rendered in bespoke, hand-styled lettering instead of the collection's standard typeface: *Rekt, Pepe, Degen, Lambo, Snipe, Liquid, Pump, Dump, Rug, Floor, Yield, Swap, Trade, Stake, Airdrop, Farm, Satoshi, Hype, Fee, Gas, Sweep, Mint, Dev, Token, Moon.* They play in the game exactly like any other word — special looks, zero gameplay advantage.

---

## 4. The art: how a word becomes onchain artwork

Every Word NFT's image is generated **live, onchain, from code** — there is no stored picture file. When a marketplace or wallet asks for a token's image, the Renderer assembles an SVG (a vector image) on the spot:

- **One typeface** across the whole collection (a freely-licensed font called Fraunces), embedded directly in the image. The word *is* the art; uniform type makes the collection read as a coherent set.
- **A material** the word is "written on" — paper, parchment, slate, stained glass, gold leaf, and more — grouped into rarity tiers from Common to Legendary.
- **An ink and a background color**, chosen from tables that guarantee the result is always legible and tasteful. Backgrounds are always a single solid color.
- The 25 honors words swap the standard typeface for their bespoke lettering.

**Crucial fairness rule: visual rarity has zero effect on the game.** A Legendary gold-leaf word and a Common paper word have *identical* bounty odds, *identical* reward share, and the *identical* 1,000-WORD backing. The game and reward contracts are built so they literally cannot read a word's looks. Rarity is aesthetic flex, nothing more.

**Everything is fully onchain.** The font, the material designs, and the 25 bespoke artworks live in the contracts themselves (using a standard technique that stores large data cheaply as contract code). There is no external server or IPFS dependency anywhere — the artwork is as permanent as Ethereum.

### Snipe-proof fairness (provenance)

A real risk in NFT collections is *sniping* — bots grabbing the rare ones. WORDBANK prevents this with the standard **provenance** method: the full, shuffled word-and-trait assignment is locked behind a published fingerprint before the collection is revealed, and which token gets which word/traits is fixed only afterward, using a future Ethereum block's hash that nobody can predict or control. Until that reveal, **nobody — including the team — knows which token gets which word.** You can't simulate or cherry-pick your way to a Legendary.

---

## 5. The money: a 1% fee, split three ways

All of WORDBANK's ongoing economy is powered by **one source: a 1% fee on ETH flowing through the official WORD/ETH trading pool** on Uniswap. No emissions, no inflation, no treasury unlocks — fees or nothing.

That 1% is automatically routed three ways while the buy-and-burn is still running:

| Slice | Goes to | Purpose |
|---|---|---|
| **50%** | Holder rewards | Paid out equally across all living NFTs |
| **25%** | Bounty treasury | Funds the daily game's prizes |
| **25%** | Buy-and-burn | Buys WORD and destroys it, shrinking supply |

When there is no WORD left to burn right now (supply has caught up to the current backing floor), the split automatically becomes **two-way — 70% holders / 30% bounty** — so the quarter that would fund burning isn't wasted. It switches back to three-way whenever there's WORD to burn again (for example, after NFTs are unbound and release their backing). The split simply follows whether there's anything to burn.

A public "flush" function lets anyone push the collected fees to their destinations, so the money never depends on the team showing up.

### Marketplace royalties — a second stream, split trustlessly

Separately from that trading fee, WORDBANK asks for a **3% royalty** whenever a Word NFT is resold on a marketplace. Those royalties don't go to a wallet — they land in a dedicated contract, the **RoyaltySplitter**, which forwards every payment in **equal thirds**:

| Slice | Goes to |
|---|---|
| **1/3** | Buy-and-burn |
| **1/3** | Bounty treasury (prizes) |
| **1/3** | The team |

The three destinations and the equal split are **frozen when the contract is deployed — there are no controls to change them, and the contract has no owner to abuse**. That's what makes it trustless: holders can verify, once and forever, exactly where royalties go. Anyone can trigger the split with a public function, and a misbehaving wallet can never jam it — the burn and bounty thirds are always paid first.

NFT holders deliberately get **nothing** from royalties — they're already paid by the 1% trading fee above. Two honest notes: marketplace royalties are paid *voluntarily* (no contract can force a marketplace to honor them — see §12), and the 3% rate is adjustable by the admin up to the onchain 10% cap, but the equal three-way split itself can never be re-weighted.

---

## 6. The daily game

This is the protocol's beating heart: **one sentence per day, drawn from living words, paying an ETH prize.**

### How a sentence is made (commit-reveal)

The draw uses a tamper-proof, two-step "commit-reveal" so nobody — not even the person who starts it — can see the outcome in advance or veto a result they dislike:

1. **Commit.** Any word-NFT holder opens the day's draw by posting a small **0.01 ETH bond**. This records a *target block* about 3 minutes in the future. (The game is also structurally locked until the collection has fully sold out and its word registry is built — it cannot start early.)
2. **Reveal.** Once that target block has passed, **anyone** can trigger the reveal. The contract uses the target block's hash — unknowable when the commit was made — as the randomness to: pick a sentence template the current living words can fill, fill its blanks with randomly chosen living words (no word used twice in one sentence), pick a prize amount, and lock that prize. The person who triggers the reveal earns **2% of the prize** as a reward (so it always gets done), and the committer's bond is refunded.

If nobody reveals within the ~48-minute window, anyone can clear the stuck commit; the bond is forfeited to the treasury and a fresh draw can start. This design makes "start a draw, peek, then sulk" impossible and unprofitable.

The sentences are built from a curated set of fill-in-the-blank **templates** (patterns like *"The [adjective] [noun] [verb] the [noun]."*). Whoever maintains the templates shapes the *style* of sentences — never the actual words, which the blockchain's randomness alone selects.

### Prizes

The prize for a sentence is drawn from a menu of **0.05, 0.1, 0.2, 0.25, 0.3, 0.4, or 0.5 ETH**, chosen randomly among only the tiers the treasury can currently afford. This lets the game start paying small prizes early and grow into bigger ones as fees accumulate. The prize is split equally among the words in the sentence.

### Claiming — and how the right owner is verified

Each winning word's share waits **7 days** for its owner to claim. When someone claims, the contract verifies, in order:

1. the event exists,
2. it's still within the 7-day window,
3. that specific word really is in that day's sentence,
4. it hasn't already been claimed, and
5. **the claimant currently owns that word NFT** — checked live against the WordBank's ownership record at the moment of claiming.

That fifth check is the key to "the right holder gets the prize." It uses **claim-time ownership**: the prize belongs to whoever owns the word *when they claim*, not who owned it when the sentence was drawn. A practical consequence — buying a winning word before its deadline buys its unclaimed prize too (and the marketplace view lets a buyer verify exactly what's claimable before purchase). If a word is burned (unbound) before its prize is claimed, the ownership check fails and that share simply returns to the treasury.

Unclaimed prizes after the 7-day deadline are swept back into the treasury to fund future games.

---

## 7. Holder rewards

The 50% rewards slice is split **equally across every living NFT**, continuously, using a well-known efficient accounting method that pays everyone their exact fair share without ever looping through 10,000 holders.

Key properties:

- **Rewards travel with the NFT.** If you sell or transfer a word, any unclaimed rewards go to whoever holds it at claim time — just like the bounty prizes. A public view lets a buyer check the exact pending rewards before purchase.
- **Claim anytime**, in batches, with no deadline.
- **Fresh mints can't steal old rewards** — a newly minted token only earns from fees that arrive *after* it exists.
- **Burning raises everyone else's rate.** When a word is unbound, the survivors split all future fees among fewer NFTs, so each remaining word earns more.

---

## 8. Buy-and-burn — making WORD deflationary

The 25% burn slice gives **WORD token holders** (who may own no NFT) a concrete benefit: a steadily shrinking supply.

It works by **buying WORD on the open market with the collected ETH and destroying it.** This is the deflation engine, and it has carefully designed guardrails:

- **It can never touch the backing.** Burning can never reduce supply below the WORD bound to the living NFTs (1,000 per alive NFT) — this floor is enforced by the token itself. The floor isn't fixed: as NFTs are unbound, the collection shrinks and releases backing into circulation, so the floor falls and that freed WORD becomes burnable too. Deflation therefore continues for the life of the protocol, always stopping short of the backing.
- **Anyone can trigger a buyback** (a small keeper tip of ~1% of the spend rewards whoever does), so it runs itself without the team.
- **It buys in small, rate-limited amounts** with an onchain slippage guard, to limit the price impact and the profit any "sandwich" trader could extract.
- **It runs as its own transaction**, never wedged inside someone else's trade — a deliberate safety choice that avoids a whole class of exploits.

Whenever supply has caught up to the current backing floor, the engine simply pauses (no leftover ETH sits idle — the fee split has already switched to two-way), and it resumes automatically the next time an unbind lowers the floor and frees more WORD to burn.

---

## 9. The liquidity lock

This is the anti-rug guarantee. The WORD + ETH seeded into the trading pool is held as a position that is **locked for at least 1 year** in a dedicated vault. The lock can be **extended but never shortened**, and there is a one-way **"make permanent"** option that converts the lock to forever — the strongest possible trust signal. The locker's address and lock terms are published openly, so anyone can verify the liquidity is genuinely locked and for how long.

---

## 10. Can the team rug?

No. WORDBANK is built so that even a fully compromised team key **cannot** steal or destroy what matters. The following are made structurally impossible by the contract code — not by anyone's promise:

- **Cannot mint WORD beyond the 11,000,000 cap** — and after launch, minting is permanently sealed.
- **Cannot burn below the live backing floor** (the WORD bound to the currently-living NFTs) — the NFT backing is untouchable.
- **Cannot touch or redirect the backing** in the vault — it only ever releases 1,000 at a time to someone burning their own NFT.
- **Cannot shorten the liquidity lock** — it can only be strengthened.
- **Cannot rig the daily draw** — the words and the prize are chosen by blockchain randomness, never by a person.
- **Cannot change the word list** once it's locked behind its published fingerprint.
- **Cannot starve any fee stream to zero** — the splits are adjustable only within hardcoded limits.

The protocol's contracts were reviewed contract-by-contract by an internal security pass and an extensive automated test suite — including "fuzzing" (thousands of randomized action sequences) and a "mainnet-fork" test that runs the whole life cycle against the real Uniswap contracts.

---

## 11. The "91% in one wallet" question

Open WORD on a token scanner and the top holder owns about 91% of supply. **That address is the WordBank vault contract** — it holds the 1,000 WORD bound behind each of the 10,000 NFTs (10,000,000 of the ~11,000,000 total). It is not a person, not the team, and not a whale wallet. Its code can release tokens only one way: 1,000 at a time, to an NFT owner burning their token. It cannot trade, cannot vote, cannot rug. The float you see trading — roughly 9% — is the liquidity allotment, shrinking further as the burn runs. **The vault *is* the product:** it is why every NFT is worth at least its backing.

---

## 12. Honest limits

The things this protocol bounds but cannot fully prevent. We'd rather you read them here than discover them later. None put funds at risk.

- **Royalties are a request, not a rule.** Marketplace royalties (capped at 10% onchain) are a signal marketplaces honor voluntarily. A marketplace that ignores them pays nothing, and no contract can force it. When they *are* paid, they split trustlessly in equal thirds (see §5).
- **The launch whale-guard raises costs; it doesn't stop whales.** For up to an hour after trading opens, single buys above a set size revert. A determined buyer can split across transactions and wallets — paying more fees and more price impact per slice. That friction is the whole promise.
- **Visual rarity is worth exactly nothing in the game.** A gold-leaf Legendary and a paper Common have identical bounty odds, identical fee share, identical 1,000-WORD backing. (This one is a *guarantee*, listed here only to be explicit.)

---

## 13. The contracts

Eight contracts make up WORDBANK. All are verified on Etherscan with public source code; the links are on this page.

| Contract | What it does |
|---|---|
| **WordToken** | The WORD ERC-20. 11M cap, sealed at launch, burnable down to the live backing floor. |
| **WordBank** | The 10,000 NFTs, the locked backing, the word registry, and the unbind (cash-out) path. |
| **Renderer** | Assembles each NFT's artwork onchain. |
| **RewardsDistributor** | Splits the 50% holder-rewards slice equally across living NFTs. |
| **BountyEngine** | The daily game: templates, commit-reveal draw, prizes, claims. |
| **BurnEngine** | Buy-and-burn excess WORD down to the live backing floor, for the protocol's life. |
| **FeeHook** | Skims the 1% trading fee and routes the three-way split. |
| **LPLocker** | Time-locks the initial liquidity. |
| **RoyaltySplitter** | Receives marketplace royalties and splits them trustlessly in equal thirds (burn / bounty / team). |

---

## 14. The life of a word, end to end

1. **Hold.** Your word NFT earns its equal share of the 50% rewards stream, continuously, for as long as you hold it.
2. **Play.** Some days, the game's sentence draws your word — and its share of an ETH prize is yours to claim within 7 days.
3. **Trade.** If you sell it, the backing *and* all pending rewards and prizes travel with it automatically. A buyer can verify exactly what's pending before they pay.
4. **Cash out (unbind).** Whenever you want the tokens, you unbind: your pending rewards settle to you, the NFT burns forever, and the 1,000 WORD land in your wallet. The collection gets one word smaller — raising every survivor's reward rate and bounty odds. There is no undo.

Meanwhile, every trade in the pool feeds all of this — rewarding holders, funding the game, and burning WORD toward its floor — with no inflation, no team emissions, and no off-switch.

---

*Contract addresses and verified source are linked on this page. Nothing here is financial advice.*
