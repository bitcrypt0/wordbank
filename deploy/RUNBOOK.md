# WORDBANK Launch Runbook

**Who this is for:** the project owner. Every step says what it does in plain English, what
it costs you in flexibility (some steps can never be undone), and exactly what to run.
Steps marked **🔒 IRREVERSIBLE** cannot be taken back by anyone, ever — including you.

**The shape of the launch, in one paragraph:** you deploy all nine contracts and wire them
together (Phase 1), the artists' word/trait content gets uploaded and the NFT sale runs on
its own schedule, then in a single sitting you mint the 1,000,000 pool WORD, create and fund
the trading pool, lock the liquidity for a year, and switch trading on (Phase 2). Much later,
once every NFT exists, you permanently seal the token and give up your owner powers over it
(Phase 3), which is what makes token-scanner sites show WORD as safe.

Two toolchains do the same thing — use whichever you're comfortable with:
- **Forge scripts** (`script/*.s.sol`) — used for the anvil/testnet rehearsals.
- **Hardhat scripts** (this folder) — `npm install` once, copy `.env.example` to `.env`,
  fill it in, and run the npm commands below. Run `forge build` at the repo root first;
  Hardhat deploys Foundry's compiled artifacts and never compiles anything itself.

---

## Phase 0 — before you touch mainnet

1. **Rehearse on a testnet.** Run the full path on Sepolia first, end to end — see the
   **"Sepolia rehearsal checklist"** section below for the exact critical path (it exercises
   mint → registry → game → pool → swaps → seal → buyback). The pipeline was rehearsed on a
   local chain during development; the testnet pass is yours.
2. **Decide the launch price.** Phase 2 needs `SQRT_PRICE_X96`. Take how many WORD one ETH
   should buy at launch (call it `P`, e.g. 1000), then `SQRT_PRICE_X96 = floor(sqrt(P) × 2^96)`.
   Any agent or engineer can compute this one number for you; it is the single most important
   launch decision because it sets WORD's opening price together with `ETH_LIQUIDITY`.
3. **Have the canonical Uniswap V4 + WETH9 addresses** for the chain — take them from the
   official Uniswap / WETH deployments pages, never from a search result:
   | Chain | PoolManager | PositionManager | Canonical WETH9 |
   |---|---|---|---|
   | Ethereum mainnet (1) | from Uniswap's official V4 deployments | from Uniswap's official V4 deployments | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
   | Sepolia (11155111) | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` | `0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4` | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
   | mainnet-fork Anvil | the live mainnet addresses (the fork keeps chainId 1) | the live mainnet addresses | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |

   **Full Sepolia address set** (for the mint bot, swap testing, and the seed script — pulled
   from Uniswap's official developer docs; **re-verify against the docs at launch time**, these
   move):
   - PoolManager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`
   - PositionManager `0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4`
   - UniversalRouter `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b`
   - V4 Quoter `0x61b3f2011a92d183c7dbadbda940a7555ccf9227`
   - StateView `0xe1dd9c3fa50edb962e442f60dfbc432e24537e4c`
   - Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3` (same on every chain)
   - WETH9 `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`

   The deploy script **hard-requires** the `WETH` env to equal the canonical WETH9 for the
   chainid and **asserts `royaltySplitter.weth()` on-chain after deploy** (RS-2) — so a wrong
   WETH can never ship on a known chain. A *bare* local Anvil (chainId 31337, no fork) is the
   only case the table doesn't cover; there you must set `WETH_OVERRIDE` to your test WETH9, an
   explicit opt-in so it's never silently wrong. Prefer a **mainnet-fork** Anvil for any run
   that exercises swaps or the WETH-unwrap path — those only work against canonical Uniswap +
   WETH9, which a fork has and a bare Anvil does not.
4. **Fund the admin wallet** with the seed ETH (`ETH_LIQUIDITY`) plus gas headroom.

## Sepolia rehearsal checklist

The full critical path that exercises everything, in order. This is the dress rehearsal of the
real launch on Sepolia (chainId 11155111 — addresses in the Phase-0 table). Do it once before
mainnet.

**Test-ETH-saving config (recommended for the rehearsal):** in `setSaleConfig`, set
**`earlyBirdAllocation = 0`, `publicAllocation = 9,800`, and all prices = 0**. That skips the
early-bird phase entirely and makes all 9,800 public mints free, so the rehearsal costs only gas.
Spread the mints across a **few different wallets** so you can test reward claims and the daily
game realistically (one wallet owning everything wouldn't exercise multi-owner payouts).

1. **Phase 1 — deploy** (`npm run deploy:protocol`) with the Sepolia env (V4 addresses + WETH9
   from the Phase-0 table). Verify the run prints the verified WETH9.
2. **Phase 1.5 — content upload + lock:** `npm run upload:renderer` (font/fragments/honors →
   seal) then `npm run upload:slots` (10,000 word slots → `lockSlots`), then
   `npm run verify:content`. See the Phase 1.5 section for details. (Until sealed, `tokenURI`
   reverts `NotSealed`; until locked, `openEarlyBird` reverts `SetupIncomplete`.)
3. **`setSaleConfig(0, 9800, 0, 0, 0)`** then **`openEarlyBird()` → (auto-advances, or
   `closeEarlyBird()` → `openPublicSale()`)** to reach the public phase. (With early bird = 0 you
   go straight to opening the public sale via Between.)
4. **Mint out the 9,800** with the mint bot (`mint-bot/`), spread across a few wallets.
5. **`adminMint` the 200 reserve** so all 10,000 exist.
6. **Phase 2.5 — `npm run sync-registry`**: reveals the provenance offset and builds the game
   registry to `registrySynced() == true`.
7. **Test the holder rewards claim and the daily game** (commit → reveal → claim) with the
   multiple wallets — this is the main reason to spread the mints.
8. **Phase 2 — seed, lock, go live (three scripts now):** `npm run seed-and-launch` to seed the
   pool with a small amount (e.g. **0.5 ETH + 1,000,000 WORD**), then `npm run lock-liquidity` to
   lock the LP, then `npm run enable-trading` to switch trading on. (Recommended order:
   seed → lock → enable-trading.)
9. **Test buy/sell swaps and `flush()`** — confirm the 1% skim accrues and `flush()` routes it
   3-way (there will be burnable excess at this point: the 1M pool WORD is above the live floor).
10. **Phase 3 — seal** (`npm run seal-and-renounce`). ⚠️ **`executeBuyback` only works
    post-seal** — the token refuses to burn until minting is sealed. So testing the buy-and-burn
    requires having minted out all 10,000 (steps 4–5) **and** sealed (this step).
11. **Test `executeBuyback`** — confirm it buys WORD on the pool and burns it, and that the split
    behaves per the dynamic model (3-way while excess exists; 2-way once supply reaches the live
    floor).

**Skippable on testnet:** RoyaltySplitter — royalties are marketplace-driven (a real secondary
sale on a marketplace that honors ERC-2981), awkward to simulate on Sepolia. Owner's call; its
behavior is covered by unit + integration/fork tests. The RS-2 WETH guard already verified the
splitter's `weth()` at deploy in step 1.

## Phase 1 — deploy everything (`npm run deploy:protocol`)

Deploys, in order: WordBank (which itself deploys WordToken), Renderer, BountyEngine,
RewardsDistributor, BurnEngine, FeeHook, LPLocker, RoyaltySplitter. Then wires the one-time
connections: renderer and rewards-distributor into WordBank, **BurnEngine as WordToken's only
`burner`** (the single address ever allowed to destroy WORD, only down to the live backing
floor), and **the marketplace royalty** — `setRoyalty(RoyaltySplitter, 300)` points
WordBank's ERC-2981 receiver at the splitter at **3%**. The RoyaltySplitter is trustless: it
forwards every royalty payment in fixed equal thirds (1/3 buy-and-burn, 1/3 bounty treasury,
1/3 you) with no setters — nobody, including you, can re-point or re-weight it after deploy.
The 3% rate itself stays adjustable on WordBank (hard ceiling 10%) via `setRoyalty`; only the
*split* is immutable. (Needs WETH in the env — the splitter auto-unwraps WETH-denominated
royalties before splitting; non-ETH token royalties wait for your `rescueToken`.)

The FeeHook is special: Uniswap V4 reads a hook's permissions from its **address**, so the
script first mines a CREATE2 salt until the address ends in the right permission bits
(`0x…CC` pattern), then deploys to exactly that address and double-checks it. You'll see
the mined salt in the output; it's also saved to `addresses/<network>.json` with everything
else.

**Launch checklist — RS-2 (WETH integrity):** the deploy run prints `verified WETH9: …` /
`verified RoyaltySplitter.weth() == canonical WETH9: …`. Confirm that value equals the
canonical WETH9 in the Phase-0 table for your chain. (The script already reverts if the `WETH`
env is wrong on a known chain and re-asserts `royaltySplitter.weth()` on-chain after deploy —
this line is the operator's eyeball confirmation in the run output.)

**Immediately after** (scanner hygiene #1): verify every contract on Etherscan, **WordToken
first** — unverified token source is an instant red flag on every scanner.

This is now **one command**:

1. Put your Etherscan API key in `deploy/.env` (one line):
   `ETHERSCAN_API_KEY=your_key_here` — get a free key at https://etherscan.io/myapikey
   (one key works for every chain).
2. From the `deploy/` folder, run:
   `npm run verify:mainnet`   (or `npm run verify:sepolia` for the testnet rehearsal)

It verifies all nine live contracts itself, in the right order (WordToken first), waiting for
Etherscan to confirm each one before the next, and prints a final `9/9 verified ✅` summary.
You don't need Foundry on your PATH — it finds `forge` automatically. It's **safe to re-run**:
contracts that are already verified report ✅ and are skipped, and if one fails the run keeps
going and lists what's left so you can just run the command again to retry the rest.

(Power-user / debugging: `npm run verify-commands` still just **prints** the nine
`forge verify-contract` commands without running them — for hand-execution from the repo root.
It defaults to mainnet; add `-- --network sepolia` to print the Sepolia set. You can also add
`-- --print` to any of these to force print-only.)

Then, on Etherscan, **name-tag WordBank** (scanner hygiene #5): it will hold ~91% of WORD
supply forever (it's the vault physically holding every NFT's 1,000-WORD backing), and an
anonymous contract sitting on 91% of supply looks terrifying on a holders chart. Verified
source + a public name + the FAQ copy (agents 8/9 carry it) is the mitigation.

### If something goes wrong mid-Phase 1

**First resort: just re-run the same command.** Phase 1 is resumable — each contract is
deployed only if it isn't already recorded in `addresses/<network>.json` (the file is written
**immediately after each deploy**, so a crash never orphans a live contract), and the
one-time wiring calls are skipped if already done (read from the on-chain getters). So fix the
cause and run `npm run deploy:protocol` again; you'll see "already deployed — skip" /
"already done — skip" for everything that completed, and it picks up the rest. A second clean
run is fully idempotent.

**Recovering a WordBank that deployed before the file was written.** WordBank deploys
WordToken in its own constructor, so the very first transaction creates *two* live contracts.
If a run crashed right after that first tx (before `addresses/<network>.json` existed), a
plain re-run would deploy a fresh WordBank and waste that gas. Instead, reuse the live one:

```
WORDBANK_ADDRESS=<the existing WordBank> npm run deploy:protocol
```

The script reads WordToken from `wordBank.wordToken()` on that address, records both, then
deploys Renderer → … → RoyaltySplitter and wires everything. (The forge mirror,
`script/01_DeployProtocol.s.sol`, takes the same `WORDBANK_ADDRESS`.)

**The `to: ""` RPC quirk (why the first mainnet attempt crashed).** Some RPC providers return
`to: ""` instead of `to: null` in the transaction/receipt response for a contract-creation tx,
which ethers v6 rejects (`invalid value for value.to (value="")`) — this crashed the owner's
first mainnet run *after* WordBank had already deployed. The deploy signer now goes through a
provider that normalizes `to: "" → null` before ethers parses it, so any RPC works. If you
ever see that error on an older copy of the scripts, switching RPCs (e.g. to Alchemy, which
returns `to: null`) is the stop-gap; the current scripts handle it directly.

## Phase 1.5 — upload the art + words, then lock (`npm run upload:renderer` + `npm run upload:slots`) — 🔒 IRREVERSIBLE

This is the step that puts the actual collection on-chain. Phase 1 deployed empty contracts;
nothing can mint until this runs. It's two commands, both run with the **same admin key** as
Phase 1 (the calls are owner-only). Run `forge build` at the repo root first, as always.

**1. `npm run upload:renderer`** — uploads the typeface, the 20 material surfaces with their
ink/background tables, and the 25 one-of-one artworks to the **Renderer**, then **🔒 seals**
it. After the seal the Renderer's art is frozen forever; until the seal, `tokenURI` reverts
`NotSealed` (minted NFTs would have no art — not even the pre-reveal "unrevealed" card).

**2. `npm run upload:slots`** — writes all **10,000 word/trait slots** (the shuffled,
snipe-proof arrangement) to **WordBank** in ~200 transactions, then **🔒 locks** them with the
**provenance hash** — the public commitment that the assignment can never change. The hash is
printed, and saved into `addresses/<network>.json` as `provenanceHash`. **Publish it with the
collection** (it's `keccak256` of `assets/assignments.json`, so anyone can reproduce it from the
public file and confirm no word/trait was swapped after launch). *This is not the reveal* — which
word each tokenId ultimately gets is still hidden until Phase 2.5; this step only commits the
fixed menu of contents.

**Both commands are resumable.** They're many transactions over a flaky RPC, so each one checks
what's already on-chain and continues from there — if either dies partway (gas spike, RPC
hiccup), **just run it again** and it picks up where it left off. Re-running after completion is a
safe no-op (it prints "already sealed" / "already locked"). Optional: `SLOT_BATCH` (default 50)
sets how many slots per transaction.

**3. `npm run verify:content`** — read-only smoke check: confirms the Renderer is sealed, the
slots are locked, the on-chain provenance hash matches `assets/assignments.json`, spot-checks a
few slots (including a 1/1), and renders a real token's art end-to-end. Run it before opening the
sale.

Once this phase is done, `openEarlyBird()` will succeed (before it, WordBank reverts
`SetupIncomplete`). The pipeline was smoke-tested end-to-end on a local mainnet-fork.

## Between phases — the NFT sale

This is the mint itself: the 10,000 word NFTs come into existence here, before any pool exists.
The pool is not created until Phase 2, so **trading stays impossible throughout the sale** — that
is deliberate. Do not announce a pool or token address yet.

**Prerequisite — run Phase 1.5 first (content upload + lock).** Before anyone can mint, the
Phase 1.5 commands must have (a) uploaded the font + material/ink/background fragments + 25
artworks to the **Renderer and sealed it**, and (b) written the 10,000 word slots to WordBank
and **`lockSlots(provenanceHash)`** (the snipe-proof commitment). Until the Renderer is sealed,
`tokenURI` reverts `NotSealed` — minted NFTs would have no metadata/art (not even the pre-reveal
placeholder). So: **renderer content uploaded + sealed, word slots locked (Phase 1.5), renderer +
rewards-distributor wired (Phase 1)** are all required before `openEarlyBird()` will succeed
(`WordBank` enforces this — it reverts `SetupIncomplete` otherwise).

**The sale calls (admin, on WordBank), in order:**
1. `setSaleConfig(earlyBirdAllocation, publicAllocation, earlyBirdPrice, publicPrice, earlyBirdWalletCap)`
   — allocations must satisfy `earlyBird + public + 200 (admin reserve) == 10,000`. Settable only
   in Setup or Between (never while a phase is open).
2. `openEarlyBird()` — opens the early-bird phase (cheaper price, per-wallet cap). Buyers call
   `earlyBirdMint(count)`. When the early-bird allocation sells out it **auto-advances** to the
   public sale; or you call `closeEarlyBird()` to end it early (→ Between, where you may
   `setSaleConfig` again, e.g. to fold an undersold early-bird remainder into the public
   allocation).
3. `openPublicSale()` — opens the public phase (higher price, no per-wallet cap). Buyers call
   `publicMint(count)`. (`pausePublicSale()` returns to Between if you need to reconfigure.)
4. **`adminMint(count, to)`** — your 200-token reserve, mintable any time (no price; doesn't
   trigger or delay the provenance reveal). Mint it out before Phase 3 (the seal needs all 10,000
   to exist).

**The mint bot drives the sellout.** You do not hand-click 9,800 mints. Agent 9's mint bot
(`mint-bot/`) is the tool that mints the public allocation to sellout (and is how the Sepolia
rehearsal mints out). The 9,800th public mint arms the provenance offset → **Phase 2.5
(`sync-registry`)** reveals it and builds the game registry.

## Phase 2 — seed the pool, lock liquidity, go live — 🔒 mostly irreversible

**Phase 2 is now THREE separate scripts you run on your own schedule** (changed 2026-06-16, at
the owner's direction — previously this was one combined `seed-and-launch` run):

| Step | Script | npm command | What it does |
|---|---|---|---|
| **2a** | `02-seed-and-launch.ts` | `npm run seed-and-launch` | Seed the pool (mint liquidity, init pool, mint position, wire BurnEngine). **Stops here — trading OFF, position UNlocked.** |
| **2b** | `04-lock-liquidity.ts` | `npm run lock-liquidity` | Lock the position in the LPLocker (≥ 1 year). |
| **2c** | `05-enable-trading.ts` | `npm run enable-trading` | Flip the trading switch — the market opens. |

They are **independent** and you control the timing of each. **Recommended order: 2a → 2b →
2c** (lock the liquidity *before* you open trading, so the position is provably locked the
moment anyone can buy). But nothing technically forces that order, and you can leave gaps
between them (hours, days) if you want.

> **⚠️ TWO trade-offs you are accepting by splitting these — read before you announce anything:**
>
> 1. **Between 2a (seed) and 2c (enable trading): the pool exists but swaps are gated.** A
>    honeypot scanner that probes the pool in this window will report "cannot buy/sell" — i.e.
>    it looks exactly like a honeypot. **So do NOT announce the token or the pool address until
>    AFTER 2c (enable trading) is done.** (Scanner hygiene #3.)
> 2. **Between 2a (seed) and 2b (lock): the position NFT sits UNlocked in your admin wallet.**
>    During this window the liquidity is *not* yet locked. **So do NOT publish the LPLocker
>    address or the "liquidity is locked" claim until AFTER 2b is done.** (Scanner hygiene #4.)
>
> The clean way to satisfy both: run 2a → 2b → 2c back-to-back when you're ready to launch, and
> announce only after 2c. The split simply means you *can* pace them out if you have a reason to.

**Phase 3 (seal/renounce) does NOT depend on lock or trading** — you can seal whenever the
mint-out is complete, in any order relative to 2b/2c. **But** `executeBuyback` needs trading
live (the pool must actually be tradeable), so do 2c before you expect any meaningful
buybacks. (Buybacks also need the seal — see Phase 3.)

### 2a — seed the pool (`npm run seed-and-launch`)

Mints the liquidity, creates the pool, deposits the liquidity, and wires the BurnEngine. **It
stops there: trading stays OFF and the position is NOT yet locked.** Cost: the ETH side of your
seed (`ETH_LIQUIDITY`) plus gas for ~4 transactions.

**It is fully resumable.** Every step first checks on-chain whether it's already done and
skips it if so (logging "already done"), and the position's tokenId is written to
`addresses/<network>.json` the instant it's minted. So if the script dies partway — gas
spike, RPC hiccup, a revert — you just **re-run the same command** and it continues from where
it stopped; it never re-mints liquidity, mints a second position, or double-spends. (See "If
something goes wrong mid-Phase 2" below for the one recovery flag you may need.)

1. Mints the 1,000,000 liquidity WORD to you (hard cap in the token — you could not mint
   more if you tried).
2. Grants the one-time token approvals the position manager needs.
3. Creates the ETH/WORD pool **with the FeeHook attached** at your chosen price.
4. Deposits the ETH + WORD as full-range liquidity; you receive a position NFT (its tokenId
   is recorded to `addresses/<network>.json` immediately).
5. **Points the BurnEngine at the pool** (`setPool` — one-time; the engine itself verifies
   on-chain that the pool belongs to our FeeHook and that the hook routes back to this engine,
   so the burn money cannot be aimed at a foreign pool even by mistake). This is pool wiring,
   not trade-activation — it's safe to do here and it needs the pool to exist.

When it finishes, the pool is seeded but inert: **no one can trade yet, and the liquidity is
not yet locked.** The script's closing log points you at 2b and 2c.

### 2b — lock the liquidity (`npm run lock-liquidity`) — when you're ready — 🔒

Locks the seeded position NFT in the LPLocker. Cost: gas for 2 transactions (approve + lock).
**Idempotent** — if it's already locked it logs "already locked — skip" and does nothing.

You can extend the lock or make it permanent later; you can never shorten it. You can still
collect the pool's LP fee earnings the whole time (`LPLocker.collectFees`) — that's your
revenue, separate from the 1% protocol skim. The position comes back to you at expiry; until
then nobody, including you, can pull the liquidity. **After this completes, publish the
LPLocker address and the lock terms in your launch announcement** (scanner hygiene #4): custom
lockers aren't auto-recognized by scanners' LP-lock checks, so the publication is the trust
signal. (Don't publish it *before* 2b — see trade-off #2 above.)

**Lock duration:** the lock is set to **366 days** by default (`LOCK_DURATION_DAYS`), a
deliberate 1-day buffer over the contract's 365-day minimum — computed from the live on-chain
clock and asserted to clear the minimum before the transaction is sent. (The buffer exists
because a duration computed at exactly 365 days can dip *under* the minimum by the seconds it
takes the transaction to mine — which is the bug that reverted `LockTooShort` on the first
Sepolia attempt.) You can raise it (e.g. `LOCK_DURATION_DAYS=730` for a 2-year lock) but not
below the 365-day floor.

**Which position does it lock?** By default the one 2a recorded in `addresses/<network>.json`.
If you ever need to point it at a specific tokenId (recovery — see below), pass
`POSITION_TOKEN_ID=<id> npm run lock-liquidity`. The forge mirror
(`script/04_LockLiquidity.s.sol`) keeps no ledger, so it *always* needs `POSITION_TOKEN_ID`.

### 2c — enable trading (`npm run enable-trading`) — when you're ready — 🔒

Flips the FeeHook's trading switch. Cost: gas for 1 transaction. **Idempotent** — if trading
is already live it logs "already live — skip" and does nothing. Before flipping, it
sanity-checks that the pool is initialized and the BurnEngine is wired (a clear error if 2a
wasn't run yet).

One-way: there is no off switch. From this moment the anti-whale guard rejects any single buy
of more than 10,000 WORD; it dies automatically after 1 hour (or earlier if you call
`sunsetGuard()` — also one-way). The 1% fee skim is live: 50% to NFT holders, 25% to the
bounty treasury, 25% to buy-and-burn.

**This is the announcement gate.** Until 2c is done the pool looks like a honeypot to scanners
(trade-off #1 above), so **do not announce the token or pool address until after this
completes.**

After this phase anyone, not just you, can call `flush()` on the FeeHook — it pushes the
accrued fees to the three destinations, and it needs no attention from you.

**One thing does NOT start yet: the actual burning.** The BurnEngine's quarter of the fees
starts piling up in the engine from the first trade, and that ETH is perfectly safe there —
but `executeBuyback()` (the call that spends it on WORD and destroys the WORD) stays
switched off until **Phase 3, the seal**. That's by design: the token refuses to burn
anything while minting is still open, so the "supply only ever goes down" promise can never
be contradicted mid-mint. Anyone who calls `executeBuyback()` before the seal just gets a
clear "minting not sealed" error and wastes their own gas — nothing is lost or stuck. The
instant Phase 3's seal lands, buybacks go live, keepers start earning their 1% tip, and
from then on the burn truly runs itself with no ops burden on you.

## Phase 2.5 — fix the words and build the game registry (`npm run sync-registry`)

**When:** as soon as the 9,800th public NFT is minted (the sale selling out). This can land
before or after Phase 2 — the two are independent — but the daily game cannot start until
this phase is done.

**What it's for:** until the sale sells out, nobody — including you — knows which word and
artwork each NFT gets; that's what makes the mint snipe-proof. The moment the last public
NFT mints, the contract arms a short countdown (~3 minutes). After it, this script locks in
the random assignment ("reveals the offset") from a fresh block hash, then files all ~9,800
NFTs into the game's word registry in batches of 250 per transaction (about 40
transactions; the script loops until the contract reports `registrySynced() == true`).

**If you're late:** the reveal must happen within roughly **50 minutes** of the sellout
(256 blocks). Anyone can call it — it's permissionless, so in practice a collector will
likely beat you to it — but if the window lapses unrevealed, the script safely re-arms a
new countdown and tells you to re-run it ~3 minutes later. Nothing is lost either way; it
just delays the next step.

**⚠️ THE ANNOUNCEMENT GATE — the one rule of this phase:** do **not** announce, promote,
or open the daily word game until the script prints `registrySynced() == true`. Here's why,
honestly: before the reveal, a game round simply refuses to run (harmless). But **between
the reveal and the end of the batch-filing, the registry is only partially filled — a game
round started in that window would draw its sentence from a biased subset of words.** The
script runs the whole thing in minutes precisely so this window is a non-event — but only
if nothing is announced before it finishes. (Agent 6 covers this window in integration
tests; the bias is bounded and brief, but "don't start the game yet" costs nothing.)

The 200 admin-reserve NFTs are unaffected — you can mint them before or after this phase;
they join the registry automatically as they mint.

## Phase 3 — seal and renounce (`npm run seal-and-renounce`) — 🔒 IRREVERSIBLE

Run **only after every one of the 10,000 NFTs exists — including your own 200-token
reserve** (an unminted reserve blocks the seal; mint it out first). The script checks all
preconditions and aborts loudly if any fail. It then:

1. **🔒 Seals minting** — total supply is fixed at 11,000,000 and from here can only ever
   shrink, via buy-and-burn, down to the **live backing floor** (`alive NFTs × 1,000 WORD` —
   10,000,000 while all 10,000 are alive, and lower as NFTs unbind). It can never rise again.
2. **🔒 Renounces your ownership of WordToken** — after sealing, your owner powers on the
   token (liquidity minting, burner wiring) are already dead code, so renouncing costs
   nothing and buys the strongest scanner signal there is: owner = 0x0, nothing mintable,
   no privileges (scanner hygiene #2).

Ordering matters: renounce **after** burner is set + liquidity minted + seal. The script
enforces this; don't hand-run the calls out of order.

**Don't dawdle on this phase (operational recommendation, from the security review).** The
seal is also the on-switch for buy-and-burn: every day between the public sellout and the
seal is a day the burn slice sits idle in the engine instead of working. And the engine
deliberately spends at most 1 ETH per block (its anti-manipulation pacing), so a balance
that grew large during a long wait gets worked down slowly afterwards rather than in one
satisfying burn. So: once the 9,800 public NFTs sell out, **mint your 200-token reserve and
run this phase promptly** — same week, not same quarter. (If you have reasons to hold the
reserve back, nothing breaks — the ETH waits safely — but the burn story you'll be
marketing doesn't start until you do this.)

## Ongoing owner powers (all bounded — nothing here can rug)

| Power | Where | Bound |
|---|---|---|
| Tune swap fee | `FeeHook.setFeeBps` | 0.01%–2% hard ceiling |
| Tune the 3-way split (used when there's burnable WORD) | `FeeHook.setBurnPhaseSplit` | rewards 40–60 / bounty 15–35 / burn 15–35, sums to 100 |
| Tune the 2-way split (used when there's none) | `FeeHook.setPostBurnSplit` | rewards 50–80 / bounty 20–50 |
| End launch guard early | `FeeHook.sunsetGuard` | one-way; auto-dies at +1h anyway |
| Tune buyback slippage tolerance | `BurnEngine.setMaxSlippageBps` | 0.01%–5% hard ceiling |
| Collect LP fee revenue | `LPLocker.collectFees` | fees only, never principal |
| Extend / permanent-ize the lock | `LPLocker.extendLock` / `makePermanent` | strengthen-only, both |
| Tune royalty rate / receiver | `WordBank.setRoyalty` | bps ≤ 10% ceiling |
| Rescue non-ETH token royalties | `RoyaltySplitter.rescueToken` | cannot touch WETH (which auto-splits); the splitter's equal-thirds split has NO setter |

Anyone (not just you) can call `RoyaltySplitter.distribute()` to flush accrued royalties into
the equal-thirds split — like `FeeHook.flush()`, it never needs you.

**How the burn behaves over the protocol's life (the dynamic floor — interfaces-v4).** There is
no "buy-and-burn finishes" moment and no permanent end state. The floor is **live**: it is
always `(number of NFTs still alive) × 1,000 WORD` — i.e. exactly the backing the surviving NFTs
require. The BurnEngine buys and burns the **excess** above that floor. When supply reaches the
current floor there is simply nothing to burn, so `executeBuyback()` is a clean no-op until more
excess appears — the engine **never retires**. Whenever someone unbinds an NFT, that frees its
1,000 WORD into circulation and lowers the floor by 1,000, so new excess appears and the burn
**resumes on its own**. This continues for the life of the protocol.

The fee split follows the same logic, chosen **per `flush()`**, with no permanent collapse:
- **While there is burnable excess** → 3-way (default 50% holders / 25% bounty / 25% burn).
- **When there is none** (supply is at the live floor) → 2-way (default 70% holders / 30%
  bounty); the burn slice folds into the other two so no fee idles.

It flips back to 3-way the next time an unbind frees excess. Both split configs above stay live
and tunable forever; you never need to act for any of this — `flush()` and `executeBuyback()` are
permissionless and keeper-run. (Aligns with architecture §6 and WHITEPAPER §10.)

## If buybacks won't run: temporarily add liquidity (add → run buybacks → remove)

**Symptom.** A keeper calls `executeBuyback` and it reverts `SlippageExceeded`. This happens
when the pool is **too thin**: the buyback's own price impact pushes the ETH cost past the
BurnEngine's slippage guard (≤ 5%), so the swap is rejected to protect the protocol from a bad
fill. Even the engine's smallest spend (0.1 ETH) can over-impact a shallow pool.

**Fix.** Temporarily **deepen the pool** with your own liquidity so a 0.1 ETH buyback stays
inside tolerance, run the buybacks you need, then **pull that liquidity back out**. Two scripts
do this, and they are deliberately kept separate from the locked seed position:

| Step | Script | npm command | What it does |
|---|---|---|---|
| add | `06-add-liquidity.ts` | `npm run add-liquidity` | Mints a NEW full-range position on the existing pool from your ETH + WORD. **This position is yours and is NOT locked** — it stays fully withdrawable. Its id is recorded under `extraLiquidityPositionId` (kept separate from the locked seed `positionTokenId`). |
| remove | `07-remove-liquidity.ts` | `npm run remove-liquidity` | Decreases that extra position to zero and burns it, returning the ETH + WORD **plus any LP fees it earned** to your wallet. Refuses to touch the locked seed position. Clears the recorded id. |

> **This does NOT weaken the LP lock.** The extra position is a *second*, separate position that
> never enters the LPLocker. Your locked seed liquidity (`positionTokenId`, the one published in
> your lock claim) is untouched the entire time — script 07 hard-refuses to act on it. Add/remove
> liquidity also does **not** trigger the 1% FeeHook skim (the hook only fires on swaps), so there
> is no fee on either op.

**You supply the WORD yourself.** Adding balanced liquidity at the current price needs **both**
ETH and WORD in roughly the pool's current ratio. The owner sources the WORD (e.g. from collected
LP fees via `LPLocker.collectFees`, or any WORD you hold) into the deployer/admin wallet first.
`06-add-liquidity` **checks your ETH + WORD balance up front** and aborts with a clear message if
you're short, rather than failing mid-transaction. It sizes liquidity to whichever side binds and
sweeps the unused remainder of the other side back to you.

**The flow, step by step:**

1. Put the WORD you want to add into the deployer wallet, and decide how much ETH + WORD to add
   (more depth = more buyback headroom; you get it all back on remove).
2. Set the two env vars (in `deploy/.env` or inline) and run the add:

   ```
   ETH_LIQUIDITY_ADD=2000000000000000000      # 2 ETH, in wei
   WORD_LIQUIDITY_ADD=2000000000000000000000  # 2,000 WORD, in wei (you source this)
   npm run add-liquidity                       # add 06; prints the new position id + pool depth
   ```

3. Run your buybacks — the keeper calls `executeBuyback` as normal; they now clear the guard.
   (If the pool is *very* thin you may also widen the tolerance toward the 5% ceiling with
   `BurnEngine.setMaxSlippageBps` up to 500 — but deeper liquidity is the cleaner lever.)
4. When done, remove the extra depth and take everything back:

   ```
   npm run remove-liquidity                    # remove 07; returns ETH + WORD + LP fees, burns the position
   ```

**Idempotent + resumable.** `06` refuses to mint a second extra position if one is already
recorded (remove it first to re-add at a new size); `07` is a no-op if there's nothing to remove.
The forge mirrors are `script/06_AddLiquidity.s.sol` / `script/07_RemoveLiquidity.s.sol` (they
keep no on-disk ledger, so 06 **prints** the new tokenId and you pass it to 07 as
`POSITION_TOKEN_ID`, plus the locked id as `LOCKED_POSITION_TOKEN_ID` for the refuse-if-equal
guard).

## If something goes wrong mid-Phase 2

**First resort: just re-run the same command.** All three scripts are resumable/idempotent —
each reads on-chain state and skips whatever is already done (you'll see "already done" /
"already locked — skip" / "already live — skip" lines). So fix the cause (gas, RPC) and re-run
the same `npm run seed-and-launch` / `npm run lock-liquidity` / `npm run enable-trading`. None
of them re-mints liquidity, mints a second position, double-approves, re-initializes the pool,
re-locks, or re-enables trading. Nothing user-facing exists until 2c (enable trading), so a
stalled launch is an inconvenience, not an incident.

**The one case that needs a flag — a position minted but not recorded.** 2a saves the
position's tokenId to `addresses/<network>.json` the instant it mints, so a normal crash is
fully self-recovering: a plain re-run of 2a continues, and 2b (lock) then reads that recorded
tokenId automatically. But if a position was minted by a run that never got to save it (e.g.
the original Sepolia attempt, before this fix), the ledger won't have the id. To recover, give
the existing position id to whichever step needs it:

```
# resume the seed (adopts the existing position instead of minting a second one):
POSITION_TOKEN_ID=<the minted tokenId> npm run seed-and-launch
# or lock an existing (recorded or not) position directly:
POSITION_TOKEN_ID=<the minted tokenId> npm run lock-liquidity
```

Find the tokenId from the failed run's output, the mint transaction on Etherscan (the
PositionManager `Transfer` to your wallet), or `PositionManager.nextTokenId() − 1` if it was
the most recent mint. (The forge mirrors `script/02_SeedPoolAndLaunch.s.sol` and
`script/04_LockLiquidity.s.sol` take the same `POSITION_TOKEN_ID` env — and because a forge
script keeps no addresses ledger, `04_LockLiquidity` *always* needs it.)

**Recovering a stuck pre-split Sepolia run** (the old combined script that reverted at the lock
after minting position **35975**): the seed itself is done, so finish it as two steps —
`POSITION_TOKEN_ID=35975 npm run lock-liquidity` (locks 35975 with the corrected 366-day
duration), then `npm run enable-trading`. (2a's `setPool` is idempotent, so re-running
`npm run seed-and-launch` first is harmless if you want to confirm the pool wiring.)

> **Numbering note.** The two new scripts are numbered **04-** and **05-** as an
> order-of-operations hint (they run *after* 2a). They do **not** mean "Phase 4 / Phase 5" — in
> runbook terms they are Phase **2b** and **2c**. The existing `02b-sync-registry` (Phase 2.5)
> and `03-seal-and-renounce` (Phase 3) keep their names and numbers. So the filename order on
> disk is 02 → 02b → 03 → 04 → 05, but the operational order is 2a (02) → 2b (04) → 2c (05),
> with Phase 2.5 (02b) and Phase 3 (03) independent of the lock/trading steps.
