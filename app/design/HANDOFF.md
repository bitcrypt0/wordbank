# HANDOFF.md — the complete wiring map for agent 9 (frontend-dapp)

> **Status: COMPLETE — all seven surfaces + chrome mapped.** Names below are
> the real ones from `src/` and the frozen `src/interfaces/` (interfaces-v2).
> Wallet integration is **injected wallets only** (no RainbowKit/WalletConnect),
> per root AGENTS.md. Chain: Ethereum mainnet (chainId 1).

## 1 · The seam

Every dynamic value flows from **`lib/mocks/`** — `tokens.ts`, `game.ts`,
`mint.ts`, `burn.ts`, `admin.ts`, with types in `types.ts`. Each field is
annotated with its source view. Replace constants with reads; components
don't change. Wei values are decimal strings → `BigInt(x)`.

Three dev scaffolds to keep during wiring, then delete:

| Scaffold | File | Replaced by |
|---|---|---|
| Global data/wallet toolbar | `lib/devstate.tsx` + `components/DevToolbar.tsx` | wallet: injected provider state; data: query status (loading/error/empty) |
| Per-surface scenario bars | `lib/scenario.tsx` (used by mint/game/token/admin) | real onchain state per the tables below |
| `MockAction` buttons | `components/ui.tsx` | real tx buttons — every instance's call is in its `wiring` prop and below |

**Artwork:** `lib/art.tsx` (`<WordArt>`) composes regular-word SVGs from the
Renderer's own fragment tables and uses agent 2's files for honors. Replace
call sites with the image from `WordBank.tokenURI(tokenId)` (Base64 JSON →
`image`). Pre-reveal, `tokenURI` returns the unrevealed URI — the design for
that state is `UnrevealedPlate` in `app/mint/page.tsx`.

**Identity note:** `MOCK_VIEWER` → connected account. `MOCK_OWNER` → compare
against `Ownable.owner()` on the relevant contract (WordBank / FeeHook /
LPLocker / BountyEngine / BurnEngine share an owner at launch; WordToken's
owner may be renounced — see Admin §8).

## 2 · Global chrome

| Element | Wire to |
|---|---|
| Wallet button: disconnected → connecting | `eth_requestAccounts` pending |
| connected pill | account + `chainId === 1` check |
| owner variant (gold dot + "owner" tag) | `account === owner()` |
| wrong-network | `chainId !== 1` → `wallet_switchEthereumChain` |
| Hero/home stats | `WordToken.totalSupply()`, `WordToken.burnedTotal()`, `WordBank.totalAlive()`, BountyEngine `freeTreasury()` |
| Admin route | hidden from nav by design; gate the page on `owner()` (see §9) |

## 3 · Mint (`app/mint/page.tsx`)

Scenario → onchain state: `not-open` = `phase == Setup`; `early-bird` =
`phase == EarlyBird`; `public-sale` = `phase == PublicSale` (a `Between`
pause renders the not-open card with "between phases" copy — phase enum:
`Setup, EarlyBird, Between, PublicSale`); `sold-out` = `earlyBirdMinted +
publicMinted == PUBLIC_SUPPLY`.

| Element / slot | Wire to (WordBank) |
|---|---|
| Phase badge | `phase` |
| Price | `earlyBirdPrice` / `publicPrice` |
| Mint button | `earlyBirdMint(count)` / `publicMint(count)` — payable `price * count` |
| Wallet-cap meter | `earlyBirdMintedBy(account)` vs `earlyBirdWalletCap` |
| Allocation meters | `earlyBirdMinted`/`earlyBirdAllocation`, `publicMinted`/`publicAllocation` |
| Provenance progress | `earlyBirdMinted + publicMinted` vs `PUBLIC_SUPPLY` (9,800) |
| Total minted | `totalMinted()` of `MAX_SUPPLY` |
| Unrevealed plate | shown while `offsetSet == false` (`tokenURI` returns the unrevealed URI) |

## 4 · Daily game (`app/game/page.tsx`)

Phase resolution (in order):
1. `WordBank.registrySynced() == false` → **pre-start** (progress: `registryCursor`/10,000)
2. `currentCommit.targetBlock == 0` (no pending commit) → **idle**
3. `block.number <= targetBlock` → **committed**
4. `targetBlock < block.number <= targetBlock + 256` → **revealable**
5. past the window unrevealed → **expired**
6. **revealed** = the newest `SentenceGenerated` event still inside its claim window (independent of 1–5; show alongside idle/committed when both apply — the mock shows one at a time, compose as fits)

| Element / slot | Wire to (BountyEngine unless noted) |
|---|---|
| Treasury meter | `freeTreasury()` (= balance − `lockedFunds()`) |
| Tier ladder + affordability | `tiers()`, mark `tier <= freeTreasury()` |
| Commit button | `commit()` payable `BOND` (0.01 ETH); requires `WordBank.balanceOf(account) >= 1` |
| Commit gating | one per `CYCLE_LENGTH` (24h) via `lastEventTimestamp` |
| Block countdown | `currentCommit.targetBlock` vs chain head (`REVEAL_DELAY` = 15) |
| Reveal button + 2% callout | `reveal()` — reward = `REVEAL_REWARD_BPS` of drawn tier |
| Reveal window | `targetBlock + BLOCKHASH_WINDOW` (256 blocks ≈ 48 min) |
| Expired → clear button | `expireCommit()` |
| **Sentence composition** | `SentenceGenerated(eventId, tokenIds, words, templateId, amount, sharePerWord, deadline)` — words come in the event; fragments from `getTemplate(templateId)`; art via `tokenURI(tokenIds[i])` |
| Per-word claim button | `claim(eventId, tokenId)`; show iff `isClaimable(eventId, tokenId)` && `ownerOf(tokenId) == account` |
| "Claim both" batch | `claimMany(eventId, tokenIds[])` |
| Claimed/forfeit chips | `isClaimable` false + `BountyClaimed` logs; burned word = `WordBank.isAlive(id) == false` |
| Deadline countdown | `eventInfo(eventId).deadline` |
| History rail | past `SentenceGenerated` events (indexer); status from `eventInfo().swept`, `BountyClaimed` logs, `sweep(eventId)` callable post-deadline |

## 5 · Rewards (`app/rewards/page.tsx`)

| Element / slot | Wire to |
|---|---|
| Owned-token list | enumerate account's tokens (Transfer logs / indexer — WordBank is not ERC721Enumerable) |
| Per-token pending | `RewardsDistributor.pendingRewards(tokenId)` |
| Batch claim | `RewardsDistributor.claimRewards(tokenIds[])` — reverts whole batch on any non-owned id; build the array from checked rows |
| Lifetime claimed | sum of `Claimed(tokenId, to, amount)` events for the account (indexer aggregate) |
| Stream % | `FeeHook.rewardsBps` (live: 50% three-way while there's WORD to burn; 70% two-way while burning is paused — toggles per flush) |

## 6 · Unbind (`app/unbind/[id]/page.tsx`)

| Element / slot | Wire to |
|---|---|
| Rewards-settled figure (step 1 & receipt) | `pendingRewards(tokenId)` read at flow start |
| Bounty-forfeit warning | any recent event where `isClaimable(eventId, tokenId)` — same discovery as the token page |
| Final act | `WordBank.unbind(tokenId)` (batch: `unbindMany(tokenIds[])`) |
| Receipt values | `SettledAndClosed` + `Transfer` (WORD) events from the tx receipt |
| "Already unbound" state | `isAlive(tokenId) == false` |

## 7 · Token / burn (`app/token/page.tsx`)

**DYNAMIC FLOOR** — there is no `burnComplete` and no fixed `BURN_FLOOR`.
The floor is the live backing (`alive × 1,000 WORD`) and falls as NFTs are
unbound; burning never permanently ends — it pauses when supply has caught
up to the floor and resumes on the next unbind. Mock seam: `lib/mocks/burn.ts`
(scenarios `burning` / `paused`). The page's two states are driven by
`burnableExcess() > 0` (buyback card) vs `== 0` (paused idle state).

| Element / slot | Wire to |
|---|---|
| Live supply | `WordToken.totalSupply()` |
| Living backing floor | `WordToken.currentBurnFloor()` (= alive × 1,000e18) |
| Burnable right now | `WordToken.burnableExcess()` (= totalSupply − currentBurnFloor); drives buyback-vs-paused |
| Burned so far | `WordToken.burnedTotal()` (cumulative, no fixed denominator) |
| Three-segment bar | floor / excess / burned, against the fixed 11,000,000e18 cap (`SEALED_CAP_WEI` in mock) |
| Alive count (floor context) | `WordBank.totalAlive()` |
| Accrued ETH | `BurnEngine.pendingEth()` |
| Est. WORD out | quote spot from the pool (display-only estimate) |
| Keeper tip | `TIP_BPS` (100 = 1%) of spend |
| Trigger button | `BurnEngine.executeBuyback(maxEthToSpend)` — clamp to `MIN_BUYBACK_ETH`–`MAX_BUYBACK_ETH` (0.1–1 ETH); disabled if `burnableExcess() == 0`, `pendingEth() < MIN_BUYBACK_ETH`, or `lastBuybackBlock == block.number` |
| Slippage caption | `maxSlippageBps` (ceiling `MAX_SLIPPAGE_BPS` = 500) |
| Fee-slice stat / routing note | `FeeHook.burnBps` — follows the **live** routing per flush: three-way (50/25/25) while `burnableExcess() > 0`, two-way (70/30) while paused. NOT a one-time collapse; it toggles back when burning resumes. |
| Paused idle state | `burnableExcess() == 0` — "nothing to burn right now; resumes when a word is unbound". No leftover ETH (split already two-way). |

## 8 · Gallery & token page (M1 section, unchanged)

| Element / slot | Wire to |
|---|---|
| Token list | `aliveCount(category)` + `aliveAt(category, i)` (unstable order — snapshot per render) or indexer |
| Word / category / traits / art | `wordOf(id)`, `categoryOf(id)`, `wordDataOf(id)` / `tokenURI(id)` metadata |
| Owner / alive | `ownerOf(id)` (reverts on burned → designed state), `isAlive(id)` |
| DD: backing | `bondedBalance(id)` (1,000e18 or 0) |
| DD: pending rewards | `pendingRewards(id)` |
| DD: bounty share | `isClaimable(eventId, id)` + `eventInfo(eventId)` over recent events |
| DD lookup form | client-side route to `/gallery/<id>` (no chain call) |
| Claim rewards button | `claimRewards([id])` |
| Unbind button | link to `/unbind/<id>` |

## 9 · Admin (`app/admin/page.tsx`)

**Gate:** render the cockpit iff `account == WordBank.owner()`; everyone
else gets the designed forbidden state (`Forbidden` component). Scenario →
real state: "mid-launch"/"live" are just where the checklist actually is;
"renounced" = `WordToken.owner() == address(0)`.

Launch checklist — each step's `wiring` field in `lib/mocks/admin.ts` is the
exact call; statuses derive from: `slotsLocked`, `slotsWritten`, `phase`,
`offsetSet`, `registrySynced()`, `liquidityMinted`, `LPLocker.locked`,
`WordToken.burner`, `mintingSealed`, `tradingEnabledAt`, `WordToken.owner()`.

| Panel element | Wire to | Bound shown |
|---|---|---|
| Sale config save | `WordBank.setSaleConfig(…)` | sum == 10,000 (contract-enforced); `ADMIN_RESERVE` fixed 200 |
| Phase advance / pause | `openPublicSale()` / `pausePublicSale()` (+ `openEarlyBird()`, `closeEarlyBird()`) | — |
| Reserve mint | `adminMint(count, to)` | `adminMinted` ≤ 200 |
| Withdraw proceeds | `withdrawProceeds(to)` | contract balance |
| Offset / re-arm / registry | `revealOffset()` / `rearmOffset()` / `buildRegistry(maxCount)` — all permissionless | SPEC-3 banner ← `registrySynced()` |
| Fee rate slider | `FeeHook.setFeeBps(bps)` | 1–`MAX_FEE_BPS` (200) |
| Burn-phase split | `FeeHook.setBurnPhaseSplit(r, b, u)` | r 4000–6000, b 1500–3500, u 1500–3500, sum 10,000 (SPEC-4) |
| Post-burn split | `FeeHook.setPostBurnSplit(r, b)` | r 5000–8000, b 2000–5000, sum 10,000 |
| Royalty | `WordBank.setRoyalty(receiver, bps)` | ≤ `MAX_ROYALTY_BPS` (1000) |
| Buyback slippage | `BurnEngine.setMaxSlippageBps(bps)` | ≤ `MAX_SLIPPAGE_BPS` (500) |
| 🔒 Enable trading | `FeeHook.enableTrading()` | one-time; records `tradingEnabledAt` |
| Guard countdown | `tradingEnabledAt + GUARD_DURATION` (1h) vs now; `guardActive()` | — |
| 🔒 Sunset guard | `FeeHook.sunsetGuard()` | one-time, only while guard active |
| Lock / extend | `LPLocker.lock(id, until)` / `extendLock(newUntil)` | ≥ `MIN_LOCK_DURATION` (365d); extend = later only |
| 🔒 Make permanent | `LPLocker.makePermanent()` | one-way |
| Collect LP fees | `LPLocker.collectFees(to)` | fees only, never principal |
| Templates add/remove | `BountyEngine.addTemplate(slots[], fragments[])` / `removeTemplate(id)` | ≤ `MAX_SLOTS` (7) slots, ≤ `MAX_TEMPLATES` (32); read via `templateCount()` + `getTemplate(id)` |
| Tier menu | `BountyEngine.setTiers(tiers[])` | each in `MIN_TIER_VALUE`–`MAX_TIER_VALUE` (0.05–0.5 ETH), ≤ `MAX_TIERS` (16) |
| 🔒 Lock slots / seal minting | `WordBank.lockSlots(hash)` / `WordToken.sealMinting()` | one-time (in checklist) |
| 🔒 Renounce | `WordToken.renounceOwnership()` | post-state: render the `panelDead` treatment when `owner() == address(0)` |

Every 🔒 uses `components/Irreversible.tsx` — keep its three states
(blocked / available-with-type-to-confirm / done-receipt) exactly; the
"done" state is how spent one-time actions must read forever.

## 10 · Docs (`app/docs/page.tsx`)

Static copy, expanded from `WHITEPAPER-PUBLIC.md` (owner change order
2026-06-13; the former "Accepted trade-offs" section was removed by that
order — do not reintroduce it). The honest-limits section is **required**
copy: edit wording only with overseer sign-off.

**The Etherscan link seam — `lib/mocks/contracts.ts`.** One edit per
contract at deployment: fill the `address` field in the `CONTRACTS` array
(currently `null` — now **9 contracts**, RoyaltySplitter included). The Docs
contracts section then renders a live `https://etherscan.io/address/<addr>`
link automatically (built by `etherscanUrl()`, base `ETHERSCAN_BASE`); while
`address` is null it shows the designed "Etherscan — pending" state and the
"addresses publish at deployment" note. No JSX changes needed — addresses
only.

## 12 · Royalties (RoyaltySplitter — new)

Mock seam: **`lib/mocks/royalty.ts`** (`ROYALTY` object + `receiverIsSplitter`).
The split (1/3 burn · 1/3 bounty · 1/3 team) is **frozen at deploy, ownerless —
nothing to wire for it**; only the ERC-2981 rate/receiver and the splitter's
plumbing are live. Surfaces: Docs §5 royalties subsection (static copy), the
admin **Royalties panel**, and the **royalties-to-date** readout on the token
page.

| Element / slot | Wire to | Bound / note |
|---|---|---|
| Rate slider + save (admin) | `WordBank.setRoyalty(receiver, bps)` | `bps ≤ MAX_ROYALTY_BPS` (1000 = 10%); launch 300 (3%) |
| Receiver field (admin) | same `setRoyalty(receiver, bps)` — rate+receiver set together | default/lock to RoyaltySplitter address; warn if changed (abandons trustless split). Mock compares against `ROYALTY.splitterAddress` → fill with `CONTRACTS[RoyaltySplitter].address` |
| Distribute trigger (admin + anyone) | `RoyaltySplitter.distribute()` | permissionless; reverts if nothing distributable (`NothingToDistribute`) |
| Pending distribution | `RoyaltySplitter.pendingDistribution()` | balance net of `pendingAdmin` |
| Withdraw admin slice | `RoyaltySplitter.withdrawAdmin()` | **show only when** `pendingAdmin() > 0`; reverts `NothingPending` otherwise |
| Rescue token (admin) | `RoyaltySplitter.rescueToken(token)` | admin-only; **reverts on WETH** (`CannotRescueWeth`) |
| Royalties-to-date totals | sum `Distributed(caller, toBurn, toBounty, toAdmin)` events | **no onchain lifetime counter** — event-derived / indexer aggregate (equal thirds, so the three totals match) |
| Live awaiting-flush stat | `RoyaltySplitter.pendingDistribution()` | — |

Other royalty events for the indexer: `AdminSlicePending(amount, totalPending)`,
`AdminWithdrawn(amount)`, `TokenRescued(token, amount)`.

## 13 · WORD swap (the WORD page's buy/sell panel)

Mock seam: **`lib/mocks/swap.ts`** (`quoteSwap`, `SWAP_STATES`, `SWAP_CONSTANTS`);
UI: **`components/SwapPanel.tsx`** on `app/token/page.tsx`. **This is the one
surface that talks to CANONICAL Uniswap deployments, not our contracts** — only
the two FeeHook reads and the pool's identity come from us. No protocol or
interface change.

The pool: canonical Uniswap **V4 WORD/ETH** pool, `currency0 = ETH` (native,
`address(0)`), `currency1 = WORD`, with our **FeeHook** as the hook (the 1%
skim). Build the `PoolKey` from `{ currency0: ETH, currency1: WORD, fee,
tickSpacing, hooks: FeeHook }` — WORD address + FeeHook address come from
`lib/mocks/contracts.ts`; `fee`/`tickSpacing` are the pool's launch params
(publish at deploy).

| Element / slot | Wire to | Note |
|---|---|---|
| Estimated output, rate, price impact (`quoteSwap`) | canonical **V4 Quoter** `quoteExactInputSingle(PoolKey, zeroForOne, exactAmount)` | quote already nets the FeeHook 1% + pool curve; exact-input default |
| Buy execute (ETH→WORD) | canonical **V4-capable router** (UniversalRouter `execute` w/ a `V4_SWAP`) — `value` = ETH in | no approval needed for native ETH in |
| Sell execute (WORD→ETH) | same router via **Permit2** | needs the approval step below |
| Approve step (sell side) | **Permit2** `approve(WORD, router, amount, expiry)` (after a one-time ERC-20 `WORD.approve(Permit2, max)`) | drives the "needs approval → ready" two-step; buying ETH skips it |
| Balances + MAX | wallet ETH balance / `WordToken.balanceOf(account)` | — |
| Slippage → min received / max sold | client-side off the quote (default 50 bps) | passed as `amountOutMinimum` / `amountInMaximum` to the router |
| **Trading-not-enabled state** | **`FeeHook` trading gate** — swaps revert until the one-time `enableTrading()` (`tradingEnabledAt == 0`) | pre-launch banner; disable the button |
| **Launch-window cap** | **`FeeHook.guardActive()`** + the **10,000 WORD** per-buy cap (`FeeHook.BUY_CAP = 10_000e18`) | a buy whose quoted WORD-out exceeds the cap reverts in `afterSwap` during the ≤1h window; block client-side with the "max 10,000 WORD per buy" warning |
| Wrong-network / insufficient / slippage-exceeded / pending-confirmed-failed | wallet `chainId` (mainnet) · balance check · decode router revert | decode `V4TooLittleReceived`/`TooMuchRequested` → "slippage exceeded"; surface guard/gate reverts with the copy above |

`SWAP_CONSTANTS` mirrors the contracts: `feeBps 100`, `launchBuyCapWord 10_000`,
`slippageDefaultBps 50`. The `quoteSwap` mock is float-based for live typing —
**replace with the wei-based V4 quoter**; everything else (scenarios, flags,
balances) is a direct read.

## 14 · Permissionless public triggers (the "no dependence on the team" guarantee)

**Hard rule for Agent 9: gate every UI control by the function's ACTUAL
on-chain permission. A permissionless function must be reachable from a
surface a non-owner can see — never assume "maintenance action = admin-only."**
The admin dashboard MAY also show these; it must not be the only place.

| Public trigger | Surface (non-owner visible) | Wire to | Visibility / enable gate (on-chain read) |
|---|---|---|---|
| `executeBuyback()` | WORD page (already public) | `BurnEngine.executeBuyback(maxEthToSpend)` | `burnableExcess() > 0` && `pendingEth() ≥ MIN_BUYBACK_ETH` && `lastBuybackBlock != block.number` |
| **`flush()`** | WORD page — fee-routing note | `FeeHook.flush()` | enable when `FeeHook.pendingFees() > 0` (mock: `BURN_STATES[].pendingFeesWei`) |
| **`distribute()`** | WORD page — royalties readout | `RoyaltySplitter.distribute()` | enable when `pendingDistribution() > 0` (mock: `ROYALTY.pendingDistributionWei`) |
| **`revealOffset()`** | Mint page — Launch status panel | `WordBank.revealOffset()` | show when `offsetTargetBlock != 0` (armed at 9,800 sellout) && `!offsetSet` && inside the 256-block window |
| **`rearmOffset()`** | Mint page — Launch status panel | `WordBank.rearmOffset()` | show when armed && `!offsetSet` && the reveal window has lapsed |
| **`buildRegistry(maxCount)`** | Mint page — Launch status panel | `WordBank.buildRegistry(maxCount)` | show when `offsetSet` && `!registrySynced()`; progress from `registryCursor` / `MAX_SUPPLY` |

Mock seams: `lib/mocks/launch.ts` (`LAUNCH_STATES`, phase flags) backs the
`LaunchStatus` panel; `lib/mocks/burn.ts` adds `pendingFeesWei`; `distribute()`
reads `ROYALTY.pendingDistributionWei`.

**Admin note:** the same triggers may remain in the admin dashboard for the
owner's convenience. `withdrawAdmin()` is deliberately **admin-only in the UI**
— it's permissionless but only ever pays the immutable admin, so a non-admin
has no reason to call it (the panel says so rather than duplicating a button).

## 11 · Gaps filed / accepted approximations

- **No on-chain enumeration of owned tokens or per-account lifetime claims** —
  by design (gas); use Transfer/`Claimed`/`BountyClaimed` logs or a light
  indexer. Not an interface gap; no contract change requested.
- **Current-event discovery**: the live event id = `nextEventId - 1` after a
  reveal; rely on `SentenceGenerated` logs for history. Sufficient as-is.
- No missing views were found that require interface changes — everything
  the mock displays maps to an existing member above.
