# Agent 6 — Integration & Invariant Report

**Last updated:** 2026-06-14 · **Status:** Integration complete — dynamic burn floor
(interfaces-v3), RoyaltySplitter coverage, the interfaces-v4 pre-reveal placeholder, **and the
UniversalRouter production-swap fork path**. All nine system invariants, every scenario, the
equal-thirds royalty split, the pre-reveal placeholder → revealed-art flow, and both mainnet-fork
suites green.

## Plain-English summary (for the owner)

These test suites prove the WORDBANK contracts keep their promises **when used together as
one live system**, not just one contract at a time. The protocol recently changed how the
buy-and-burn floor works — instead of a fixed 10,000,000-token floor that, once reached, ends
burning forever, the floor is now **dynamic**: it always equals the backing of the
still-living NFTs (`alive count × 1,000`). When someone cashes an NFT back into tokens (an
"unbind"), the living count drops, the floor drops with it, and the freed tokens become
burnable — so burning **pauses at the floor and automatically resumes after each unbind**,
with no permanent end. The test suites have been migrated to this new model, and the proof is
complete again:

- **The whole user journey works end to end** against the real contracts: minting all
  10,000 word NFTs, the daily word-game (commit → reveal → claim → sweep), trading on a
  Uniswap pool that skims the 1% fee, paying holder rewards, the dynamic buy-and-burn, and
  cashing an NFT back into tokens.
- **The system's nine core safety promises are machine-checked** by fuzzing — thousands of
  randomized sequences of real actions, re-verifying after every step that backing, supply,
  the word registry, the treasury, the per-flush fee split, and the **dynamic floor** all
  hold.
- **A dedicated new test proves the headline behaviour** — burn down to the floor, confirm
  burning pauses, then unbind some NFTs and confirm burning resumes down to the new, lower
  floor.
- **The "mainnet fork" run still passes** against the *real, live* Uniswap V4 contracts on a
  copy of Ethereum mainnet, now exercising the dynamic-floor burn-and-resume arc.

**New this round — the RoyaltySplitter.** A new contract now receives marketplace royalties
(3% of each sale) and forwards them in **trustless equal thirds**: 1/3 to buy-and-burn, 1/3 to
the bounty prize treasury, 1/3 to the admin (holders get no royalty cut — that's intentional,
the 1% swap fee already feeds them). Coverage proves, against the real contracts: the 3% wiring,
the exact equal-thirds split for ETH, WETH (auto-unwrapped), mixed, and dust; that royalty
income actually *feeds* the protocol (a bigger buy-and-burn and a higher affordable prize tier);
that a broken/griefing admin can never block the burn and bounty shares and never strands ETH;
the stray-token rescue; and a fuzz invariant on every split. The mainnet-fork run now also pays
a royalty in **real WETH** and splits it.

**No open findings** (one INFO observation, OBS-RS1, logged below — a 1–2 wei royalty balance
makes `distribute()` revert; harmless and self-clearing). The earlier INT-1 rounding issue was
**fixed by Agent 5** and remains a passing regression check. Nothing needs the owner's
attention.

## What is delivered

### Milestone 1 — core invariant harness (accepted 2026-06-12)

| File | What it does |
|------|--------------|
| `test/invariant/handlers/CoreHandler.sol` | World model for WordToken/WordBank/RewardsDistributor: 6 actors + admin + burn authority, revert-free by construction. |
| `test/invariant/CoreInvariantBase.sol` | Real-contract fixture + executable invariants 1–4. |
| `test/invariant/CoreLifecycle.invariant.t.sol` | Fuzzes the whole arc from zero + a deterministic guided full-lifecycle walk. |
| `test/invariant/CoreSteadyState.invariant.t.sol` | Fuzzes the sealed post-launch economy deeply + the deterministic dynamic-floor burn→pause→resume scenario (real WordToken+WordBank, no pool). |

### Milestones 2–4 — scenarios, pool-backed invariants, fork (this session)

| File | What it covers |
|------|----------------|
| `test/integration/IntegrationBase.sol` | Full-stack fixture: all seven contracts on a real local V4 pool, staged in runbook order. No mocks. |
| `test/integration/FullMintLifecycle.t.sol` | Sale config → both phases (with pause/reconfigure) → 9,800 sellout arms provenance → reveal → registry build → late reserve → seal at exactly 11M; provenance unknowable until reveal. |
| `test/integration/TradeAndEarn.t.sol` | Seed → enableTrading → swaps skim → flush 50/25/25 → equal per-NFT accrual → transfer-with-pending → buyer claims → unbind force-settles → survivor rate rises. Edge: last NFT unbound, zero-alive deposit defers (SPEC-2). |
| `test/integration/DailyGame.t.sol` | Commit→reveal→claim→sweep on the real registry; **SPEC-3 gate asserted in all three regimes** (pre-reveal, mid-build, synced); lapse via `expireCommit` at the window boundary; burned-word share falls to sweep; treasury exactly at the minimum-tier gate; category drained → template skip then clean abort. |
| `test/integration/LaunchWindow.t.sol` | Gate-vs-seed ordering; whale-cap boundary on the real pool (exactly 10,000e18 passes, +1 reverts); guard auto-expiry at +1h with no admin; admin sunset path; BurnEngine buyback exempt from the guard. |
| `test/integration/BuybackAdversarial.t.sol` | Sandwich loss-bounded & unprofitable; real buyback burns excess + 3-way flush routing; **resume-after-real-unbind** (a real WordBank unbind lowers the live floor and frees excess; the next buyback resumes). Dynamic-floor model. |
| `test/integration/TraitAndStructure.t.sol` | **Invariant 6** (draw recompute proof + rarity-flat rewards); **invariant 9 structural** (flush never swaps, buyback is its own tx). |
| `test/integration/PrerevealPlaceholder.t.sol` | **interfaces-v4 pre-reveal placeholder**, end to end against the REAL sealed Renderer: pre-reveal `WordBank.tokenURI` == `renderer.unrevealedTokenURI` (well-formed JSON + embedded SVG image, `#id`+"Unrevealed" name, byte-identical-except-`#id` zero-leakage across two ids), then the full provenance path (sellout → reveal → buildRegistry) flips the **same tokens** to trait-bearing art. Edge: unsealed Renderer → `tokenURI` reverts `NotSealed` (launch-ordering precondition). |
| `test/integration/RoyaltyIntegration.t.sol` | **RoyaltySplitter** wired to the real protocol: ERC-2981 3% wiring; equal-thirds (ETH / WETH-unwrap / mixed / dust) into the real BurnEngine + BountyEngine + admin with the RewardsDistributor untouched; OBS-RS1 sub-3-wei revert pinned; griefing contract-admin (sinks paid, slice accrues, no double-count, recovered, no stranding); stray-ERC20 rescue + WETH-rescue-block; **downstream** (royalty feeds a bigger buyback + a higher affordable bounty tier). |
| `test/invariant/handlers/SystemHandler.sol` + `test/invariant/FullSystem.invariant.t.sol` | Full-economy fuzzer (swap/flush/game/buyback/unbind/claim/transfer + **royalty distribute**) encoding **invariants 5, 8, 9** + 1/2 with the REAL burner; per-flush 3-way↔2-way routing by live excess; the **RoyaltySplitter equal-thirds invariant** asserted on every distribute. |
| `test/integration/GasBench.t.sol` | Hot-path gas metering, incl. `distribute()` (table below). |
| `test/fork/ForkLifecycle.t.sol` | **Mainnet-fork full lifecycle against real Uniswap V4** (SYS-2), dynamic-floor burn-and-resume arc **+ a real-WETH9 royalty split**. RPC-gated; **verified green** against live V4 PoolManager + PositionManager + WETH9. |
| `test/fork/UniversalRouterSwap.t.sol` | **Production-router swap path** (2026-06-14): the dApp's exact `V4_SWAP`(`SWAP_EXACT_IN_SINGLE→SETTLE_ALL→TAKE_ALL`) calldata run through the real mainnet UniversalRouter against our pool+hook — buy (≥minOut, ≈quote, 1% skim), sell (full Permit2 path), and the three reverts the dApp pre-blocks (`BuyExceedsLaunchCap`, `TradingNotEnabled`, `V4TooLittleReceived`). RPC-gated; compiles + skips offline (overseer runs it on a live fork). |

**Result: 393 tests — 387 green offline + 6 RPC-gated fork tests (1 ForkLifecycle + 5
UniversalRouter swap; run with `FORK_URL`/`MAINNET_RPC_URL` set). `forge fmt --check` clean.
Gas snapshot refreshed.**

## System invariant coverage (all nine — root AGENTS.md numbering)

| # | System invariant | Encoded as | Status |
|---|------------------|------------|--------|
| 1 | 1,000e18 bond per live NFT; vault balance exact | `invariant_backingCoversAliveExactly` (core + full-system, real burner) + per-id bond spot-checks | ✅ green |
| 2 | supply ≤ 11M; supply ≥ the **dynamic floor** `totalAlive×1000e18` (descends only via unbind); `burnableExcess == supply − floor` | `invariant_supplyAccounting` + `invariant_dynamicFloor` (core) + `invariant_burnFloorAndLedger` (full-system, real burner). *(No `burnComplete` in v3 — the old `sealFloorAndBurnComplete` was rewritten to the dynamic form.)* | ✅ green |
| 3 | settle before `totalAlive` decrement | Surfaces as exact distributor ETH conservation + solvency across unbinds; call-ordering unit-tested by agents 1/3 with recording mocks | ✅ green |
| 4 | category arrays ⇄ `indexInCategory`; counts sum to totalAlive | `invariant_registryCountsSum` (exact incl. half-built regime) + `invariant_registrySampled` (round-trip) | ✅ green |
| 5 | BountyEngine `lockedFunds` ≤ balance, share math immutable | `invariant_lockedFundsCoveredByBalance` + `invariant_lockedFundsEqualSumOfRemainders` (exact: lockedFunds == Σ remainders across commit/reveal/claim/sweep/expire) | ✅ green |
| 6 | visual rarity NEVER influences gameplay | `test_invariant6_drawIsTraitIndependent_recompute` (re-derives every draw from seed + categories alone — no trait inputs) + `test_invariant6_rewardsFlatAcrossRarity`. **Method documented in the test NatSpec.** | ✅ green |
| 7 | bounded admin | Exercised throughout (handlers reconfigure only within bounds; negative paths in the owners' unit suites). The one unbounded lever found earlier (template count) was closed as finding 04-1. | ✅ green |
| 8 | fee slices sum to 100%; routing chosen **per flush** by live excess (3-way↔2-way); burn slice never routed when `burnableExcess()==0` | Asserted **inside `actFlush` on every single flush** (`dR+dB+dE == routed`, mode by `burnableExcess()`), + `invariant_routingPerFlushClean` (burn slice never routed at zero excess). Pure 3-way↔2-way flip unit-tested by Agent 5's FeeHook suite (`setBurnableExcess(0)`). | ✅ green |
| 9 | BurnEngine never crosses the **dynamic floor**; burns 100% bought; buyback only in its own tx; no permanent retirement (resumes after each unbind) | `invariant_burnFloorAndLedger` (dynamic) + `invariant_burnEngineHoldsNoWord` + `test_invariant9_flushNeverSwaps_buybackIsOwnTx` + the resume-after-unbind scenarios (core no-pool + pooled + fork) | ✅ green |

## Scenario coverage (charter mandate)

| Scenario | Status |
|----------|--------|
| Full mint lifecycle (batch writes → early bird w/ cap → phase transition → public → 9,800 sellout → provenance → late reserve → seal at 11M) | ✅ |
| Trade-and-earn (seed → enableTrading → skim → flush → accrue → transfer-with-pending → claim → unbind → survivor rate rises) | ✅ |
| Daily game (commit → reveal → claim → partial claims → sweep) | ✅ |
| SPEC-3 gate (`commit` reverts `RegistryNotSynced` pre-sync; asserted pre-reveal, mid-build, and synced) | ✅ |
| Lapse path (`expireCommit` at the blockhash-window boundary; cycle not consumed) | ✅ |
| Word unbound between reveal and claim → share falls to sweep | ✅ |
| Launch window (whale buys revert at the boundary; guard dies at +1h no-admin; gate-vs-seed ordering) | ✅ |
| Buy-and-burn arc (swaps accrue burn slice → real `executeBuyback` burns excess → 3-way flush routing) | ✅ (integration + fork) |
| **Dynamic floor: burn to the floor → burning pauses (no excess) → unbind lowers the floor → excess reappears → buyback resumes down to the new floor** | ✅ (core no-pool + pooled + fork) |
| **RoyaltySplitter (NEW): ERC-2981 3% wiring; equal-thirds ETH/WETH/mixed/dust into real BurnEngine + BountyEngine + admin; RewardsDistributor untouched; downstream (bigger buyback + higher affordable tier); griefing-admin (slice accrues, no double-count, recovered, no stranding); stray-ERC20 rescue + WETH-rescue-block; fork real-WETH9 split** | ✅ (integration + invariant + fork) |
| **Pre-reveal placeholder (interfaces-v4): real sealed Renderer; pre-reveal `tokenURI` == `unrevealedTokenURI` (JSON+SVG, `#id`+Unrevealed, byte-identical-except-`#id` zero-leakage); full provenance path flips the same tokens to trait-bearing art; unsealed Renderer → `NotSealed`** | ✅ (integration) |
| Edge sweep (last NFT unbound → totalAlive→1→0; category drained to zero; treasury exactly at minimum tier; blockhash window boundary) | ✅ |

## Fork suite (SYS-2 — the catch-all)

`test/fork/ForkLifecycle.t.sol` deploys the entire protocol against the **real Uniswap V4**
and drives deploy → seed (via the **real PositionManager**, full-range position locked in
the LPLocker) → `enableTrading` → real swaps skimming the 1% fee → `flush` three-way →
holder reward claim → real `executeBuyback` on the forked pool → unbind force-settle →
**dynamic-floor resume: a real unbind lowers the live floor, frees burnable excess, and the
next buyback resumes burning** (no permanent completion).

- **Verified green** against live mainnet V4 (PoolManager `0x0000…8A90`, PositionManager
  `0xbD21…ee9e`, Permit2 `0x0000…8BA3`) — pool initialize, position mint, swaps, fee skim,
  buyback, and the seal/renounce sequence all execute on the real contracts.
- **RPC-gated** (`FORK_URL` or `MAINNET_RPC_URL`): without an RPC it skips cleanly, so the
  default offline `forge test` stays green. Addresses are env-overridable for other chains.
- The deploy **sequence mirrors `script/01→02→02b→03` exactly** (same constructors, wiring
  order, hook-salt mining, MINT_POSITION actions, seal/renounce). The scripts log their
  CREATE/CREATE2 addresses to the console for manual phase-to-phase handoff and the FeeHook
  lands at a CREATE2-mined salt they do not return, so the self-contained fork test
  reproduces the sequence to hold the references — the on-chain wiring exercised is
  identical to what the scripts produce.

### `test/fork/UniversalRouterSwap.t.sol` — production-router swap path (2026-06-14)

Proves the **on-chain** half of Agent 9's frontend WORD swap: the dApp
(`app/lib/swap/execute.ts`) encodes one **`V4_SWAP`** command of
`SWAP_EXACT_IN_SINGLE → SETTLE_ALL → TAKE_ALL` and calls the canonical mainnet
**UniversalRouter**. This test encodes the byte-identical command/action shape in Solidity and
runs it against our seeded pool + FeeHook on a mainnet fork (real UniversalRouter, Permit2, and
V4 Quoter at the `app/lib/contracts/addresses.ts` UNISWAP addresses).

- **Buy (ETH→WORD):** `execute{value: ethIn}(…)`, no approval → WORD received ≥ minOut and
  ≈ the V4-Quoter quote (≤ 0.1%); the FeeHook took its exact 1% ETH-side skim.
- **Sell (WORD→ETH):** the full Permit2 path — `WORD.approve(Permit2)` →
  `Permit2.approve(WORD, router, amount, expiry)` → `execute(…)` → ETH received ≥ minOut.
- **Reverts the dApp pre-blocks:** a buy whose WORD-out > BUY_CAP (10,000e18) during the guard
  → `FeeHook.BuyExceedsLaunchCap`; a swap before `enableTrading()` → `FeeHook.TradingNotEnabled`;
  an impossible `amountOutMinimum` → the V4 slippage revert `V4TooLittleReceived`.
- **Revert wrapping (live-fork finding, 2026-06-14 — useful downstream):** the deployed mainnet
  UniversalRouter does NOT surface inner hook reverts bare. Both hook reverts come back **wrapped**
  in v4's `CustomRevert.WrappedError(target, selector, reason, details)` (`0x90bfb865`) — `target`
  is our FeeHook, and the inner `reason` selector is the real error (`BuyExceedsLaunchCap`
  `0xe85dda22` / `TradingNotEnabled` `0x12f1f923`). The tests decode the wrapper and assert the
  inner selector. The **router-level** slippage error (`V4TooLittleReceived`) surfaces
  **unwrapped** — the deployed mainnet V4Router emits the `(uint256,uint256)` form (`0x8b063d73`),
  confirmed against the overseer's live-fork run, so the test matches that selector. Frontend
  takeaway for Agent 9: error-decode/UX should unwrap `WrappedError.reason` to recover the
  actionable inner error for the wrapped hook reverts, not match the top-level selector.
- **Calldata-shape note:** params are encoded with the **5-field** `ExactInputSingleParams`
  (poolKey, zeroForOne, amountIn, amountOutMinimum, hookData) that the deployed mainnet V4 router
  and the frontend SDK use — NOT this repo's newer 6-field v4-periphery pin (which adds
  `minHopPriceX36`); the mainnet router decodes the 5-field shape, so the local struct mirrors
  exactly what the dApp emits.
- **RPC-gated** like ForkLifecycle (skips offline; the overseer runs it on a live fork). Reaches
  a tradeable state via a lean deploy → seed pool → `enableTrading()` (no NFT mint-out/seal —
  user swaps are live the moment trading is enabled; the buyback is out of scope here).
- **What this does NOT cover (still needs the wallet-driven testnet rehearsal):** the dApp's
  TypeScript SDK encoding (`V4Planner`/`RoutePlanner`), the React write/confirm flow, wallet
  signing, and the two-tx ERC-20→Permit2→router approval UX. This test proves the *production
  router executes the calldata shape the dApp emits against our pool+hook* — it complements,
  not replaces, the frontend rehearsal.

## Gas — hot paths (real stack, local V4)

`gasleft()` deltas around each external call (call overhead included → real user cost).
Source: `test/integration/GasBench.t.sol` (`forge test --match-test test_gas_hotPaths -vv`).

| Hot path | Gas | Δ vs prior baseline |
|----------|-----|---------------------|
| swap buy (exact-in, hook skim) | 165,822 | −0.1% |
| swap sell (exact-in, hook skim) | 127,252 | −0.1% |
| flush (per-flush routing) | 96,279 | −0.1% |
| claimRewards (batch 1) | 40,477 | 0% |
| claimRewards (batch 5) | 126,468 | 0% |
| claimRewards (batch 20) | 450,355 | 0% |
| reveal (commit-reveal draw) | 413,767 | +0.7% |
| unbind (single, force-settle) | 127,389 | ~0% |
| unbindMany (10) | 832,998 | ~0% |
| executeBuyback (swap + burn) | 163,910 | −0.1% |
| royalty distribute (3-way) | 67,703 | new |
| pre-reveal tokenURI (unrevealed placeholder, view) | 1,974,085 | new |
| post-reveal tokenURI (trait-bearing art, view) | 1,798,454 | new |
| UniversalRouter buy (ETH→WORD, full router path) | fork-only* | new |

*The UniversalRouter buy gas is logged by `test/fork/UniversalRouterSwap.t.sol`
(`console2` in `test_router_buy_ethForWord`) but that test is RPC-gated and skips offline, so
the number is captured on the overseer's live-fork run, not in the offline `.gas-snapshot`.

Baseline refreshed 2026-06-13 (dynamic-floor model + RoyaltySplitter + interfaces-v4 placeholder).
All prior hot paths are within ±1% of the prior fixed-floor baseline — the dynamic floor adds
only a live `totalAlive` read to the burn/flush path, no material gas change. The two
`tokenURI` rows (source: `PrerevealPlaceholder.t.sol`) are **view-only** — soft gas paid by an
offchain `eth_call`, never an on-chain tx — and sit well under the IRenderer ~30M node-compat
bound. Regressions > 5% on any row will be flagged here. `.gas-snapshot` (full per-test
snapshot, fork suite excluded) is refreshed alongside.

## Fuzzing configuration

| Suite | runs × depth | fail-on-revert |
|-------|--------------|----------------|
| `CoreLifecycle` | 24 × 96 | true |
| `CoreSteadyState` | 24 × 128 | true |
| `FullSystem` | 16 × 96 | true |

`fail-on-revert = true` everywhere (stricter than the repo default) — handlers are
revert-free by construction, so any revert reaching the contracts is a real finding.
`afterInvariant()` logs per-action coverage so a vacuously-green run is visible.

## Issue log

| ID | Severity | Owner | Description | Status |
|----|----------|-------|-------------|--------|
| INT-1 | Low | Agent 5 (BurnEngine) | Original (fixed-floor) bug: when burnable dust shrank to wei-scale, `_sizeTarget`'s floor-rounded `maxEthCost` could sit 1–2 wei below the pool's rounded-up charge, reverting the final buyback `SlippageExceeded`. **FIXED by Agent 5 (2026-06-13):** `_sizeTarget` now rounds the guard-ceiling side UP (`mulDivRoundingUp` on the spot-cost mulDivs + both multiplicative margins), so integer rounding can never place the ceiling under the pool's charge. Verified: my dynamic-floor suites burn cleanly to the live floor (excess → 0) with no slippage stall; Agent 5's BurnEngine unit suite carries the floor-landing regression. The migrated `SystemHandler.actBuyback` no longer needs the dust-tolerance shim (removed). | **fixed & verified** |
| OBS-1 | Info | overseer / Agent 7 | Invariant-1's literal equality `balanceOf(wordBank) == totalAlive × 1000e18` is donation-falsifiable (anyone can ERC-20-transfer WORD to the WordBank; the equality only holds absent donations — `bondedBalance` and unbind payouts are untouched). Live monitoring should assert `>=`. The suites encode `==` and never donate; the inequality direction is annotated in `FullSystem.invariant.t.sol::invariant_backingCoversAliveExactly`. Disposition (overseer): no code change; rides with the doc-disclosure items. | acknowledged |
| OBS-RS1 | Info | overseer / Agent 5 (RoyaltySplitter) | A **1–2 wei** distributable balance makes `RoyaltySplitter.distribute()` revert: the burn/bounty thirds round to 0 and `BountyEngine.deposit{value:0}()` reverts `ZeroDeposit`, so distribute surfaces a `ZeroDeposit` rather than a clean splitter-level signal. **Harmless** — affects only a 1–2 wei balance and self-clears the instant any further royalty tops the balance to ≥ 3 wei (then it splits 1/1/1 cleanly). Pinned by `RoyaltyIntegrationTest::test_weiDust_belowThreeReverts`. No fund risk, no stranding. Disposition suggestion: accept as-is (royalties at this scale are economically irrelevant), or — if a cleaner signal is wanted — `distribute()` could early-return/`NothingToDistribute` when `bal < 3`. Not a fix request; flagged for awareness. | open (info) |

## Definition of done — checklist

- [x] All scenarios implemented and green against real contracts
- [x] All nine system invariants encoded executably (runs/depth documented above)
- [x] Fork suite green using the real V4 deploy sequence (verified against live mainnet V4)
- [x] REPORT.md current: gas table, every finding → owner, status, linked failing test
- [x] Edge-case sweep: last NFT unbound, category drained to zero, treasury at minimum tier, blockhash window boundary
- [x] Migrated to the dynamic burn floor (interfaces-v3): invariant 2 dynamic-floor form, invariants 8/9 per-flush routing + no permanent retirement, the burn→pause→resume scenario added, all fixed-floor symbols (`burnComplete`/`BURN_FLOOR`/`retired`/one-time collapse) removed from the suites
- [x] RoyaltySplitter coverage: ERC-2981 3% wiring, equal-thirds (ETH/WETH/mixed/dust) into the real engines + admin with RewardsDistributor untouched, downstream buyback/tier effect, griefing-admin (accrue/no-double-count/recover/no-strand), rescue (+WETH block), a fuzz invariant on every distribute, fork real-WETH9 split, and `distribute()` in the gas table
- [x] Pre-reveal placeholder (interfaces-v4): pre-reveal `tokenURI` == real Renderer `unrevealedTokenURI` (JSON+SVG, byte-identical-except-`#id` zero-leakage), full provenance path flips the same tokens to trait-bearing art, unsealed-Renderer `NotSealed` edge + launch-ordering note, both `tokenURI` paths in the gas table
- [x] UniversalRouter swap fork test (2026-06-14): dApp's exact `V4_SWAP` calldata shape vs the real mainnet router on our pool+hook — buy/sell + the three pre-blocked reverts; compiles + skips clean offline; REPORT notes what it proves vs. the wallet-rehearsal gap; router-swap gas logged on the fork run
- [x] Fix (2026-06-14, overseer live run): buy+sell passed live; corrected the 3 revert assertions for the mainnet router's `CustomRevert.WrappedError` wrapping of inner hook reverts (decode wrapper → assert `target`==FeeHook + inner selector) and the live `V4TooLittleReceived(uint128,uint128)` selector — file is 5/5 against the live fork (overseer re-runs to confirm); wrapping documented in REPORT for Agent 9
- [x] Full project suite green (`forge test`: 387 green + 6 RPC-gated fork) · `forge fmt --check` clean · snapshot refreshed
