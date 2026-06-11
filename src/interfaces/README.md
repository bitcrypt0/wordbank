# src/interfaces — FROZEN at `interfaces-v4`

The contract-of-contracts. Every agent compiles against these files; **nobody edits them unilaterally** (root AGENTS.md, "Interface protocol").

## Files

| File | Implemented by | Consumed by |
|------|---------------|-------------|
| `Types.sol` (`Category`, `WordData`) | — (shared) | agents 1, 2, 4 |
| `IWordToken.sol` | agent 1 | WordBank, BurnEngine (5), deploy scripts (5) |
| `IWordBank.sol` | agent 1 | BountyEngine (4), RewardsDistributor (3) |
| `IRenderer.sol` | agent 2 | WordBank (1) |
| `IRewardsDistributor.sol` | agent 3 | WordBank (1), FeeHook (5), BurnEngine (5), frontend (9) |
| `IBountyEngine.sol` | agent 4 | FeeHook (5), RewardsDistributor dust sweep (3), frontend (9) |
| `IBurnEngine.sol` | agent 5 | FeeHook (5), frontend (9) |

FeeHook, LPLocker, and RoyaltySplitter have no interface here on purpose: no other protocol contract calls into them, so their shape stays in agent 5's discretion. (BurnEngine *does* get one — the FeeHook deposits the burn slice to it and the frontend surfaces burn progress. As of v3 the FeeHook picks its per-flush split from `WordToken.burnableExcess()`, not from the engine.) The RoyaltySplitter is the *caller* of the already-frozen `IBurnEngine.deposit()` / `IBountyEngine.deposit()` and is wired in via the existing `WordBank.setRoyalty()` — so it added **no** interface surface (see version history). The frontend consumes full ABIs from `out/`, not these files.

## Version history

- **v1** — initial freeze: Types, IWordToken, IWordBank, IRenderer, IRewardsDistributor, IBountyEngine.
- **v2** (2026-06-12) — buy-and-burn added. `IWordToken` gains the burn surface (`burn`, `BURN_FLOOR`, `burner`, `burnedTotal`, `burnComplete`, + `Burned`/`BurnComplete` events); new `IBurnEngine`. No breaking changes to existing members — purely additive, so already-built WordToken/WordBank need only implement the new WordToken burn surface (Agent 1 change order); nothing implemented against v1 breaks.
- **v3** (2026-06-13) — **dynamic burn floor.** The fixed 10M floor became a live floor `WordBank.totalAlive() × 1000e18` (burn the excess above the live backing, forever; no permanent completion). A **subtractive** change, so the interface edits landed *together with* the contracts to keep the build green (Agent 1 first — WordToken/IWordToken; Agent 5 second — BurnEngine + FeeHook). Deltas:
  - **`IWordToken`**: removed `BURN_FLOOR()`, `burnComplete()`, the `BurnComplete` event. Added `currentBurnFloor()` (= `totalAlive × 1000e18`) and `burnableExcess()` (= `totalSupply − currentBurnFloor`, 0 when none). `burn` enforces the dynamic floor (reads WordBank). Kept `burn`, `burner`, `burnedTotal`, `Burned`.
  - **`IBurnEngine`**: removed `burnComplete()` and `BurnEngineRetired` (no permanent retirement). Kept `deposit`, `executeBuyback`, `pendingEth`, `Deposited`, `BuybackExecuted`, `MaxSlippageSet`. The FeeHook now reads `WordToken.burnableExcess()` directly to pick the per-flush fee split (Option B), instead of a `burnComplete` flag.
  - Agent 1's TEMP build-compat shims (`WordToken.BURN_FLOOR()`/`burnComplete()` + their IWordToken declarations) were deleted by Agent 5 with this rewire.
- **v3 (no bump) — royalty split (2026-06-13).** The RoyaltySplitter feature (new contract, agent 5; ERC-2981 receiver forwarding equal thirds to BurnEngine / BountyEngine / admin) required **no interface change**: it reuses the frozen `IBurnEngine.deposit()` and `IBountyEngine.deposit()` and the existing `WordBank.setRoyalty()`. Recorded here for traceability; the freeze stays at `interfaces-v3`.
- **v4 (LANDED 2026-06-13) — pre-reveal placeholder art.** Pre-reveal, `WordBank.tokenURI` returned text-only metadata with **no image**; Agent 2's Renderer was never invoked until after the offset reveal. Fixed: the Renderer now renders an onchain **"unrevealed" placeholder SVG**. **Additive** delta — `IRenderer` gained:
  - `function unrevealedTokenURI(uint256 tokenId) external view returns (string memory uri);` — full self-contained data URI (Base64 JSON whose `image` is an onchain SVG) for the pre-reveal window. Takes **only `tokenId`** (no `WordData`) so it is structurally incapable of leaking the eventual word/traits — the snipe-proof guarantee. Identical for every token except the displayed `#id`. Existing `tokenURI(tokenId, WordData)` is unchanged.
  Consumer: WordBank (agent 1) calls it from `tokenURI` while `!offsetSet`. Landed coordinated: Agent 2 applied the `IRenderer.sol` edit + the Renderer implementation together (header now `interfaces-v4`), then Agent 1 wired `WordBank.tokenURI` to it and deleted the old text-only `_unrevealedURI`. **Verified (overseer): full suite 385/0/1, slither clean (no new findings), deploy dry-run clean; zero trait leakage confirmed structurally (Agent 7 `audit/02-renderer.md` v4 section; the pre-reveal builders are `pure`) and against the real Renderer (Agent 6 `test/integration/PrerevealPlaceholder.t.sol`).** Freeze is now `interfaces-v4`; the owner creates the git tag.

## Scope rule

These interfaces contain only the **cross-contract** surface plus events frontends need. Admin functions, mint paths, and internal config setters are intentionally absent — their shape belongs to the owning agent, constrained by the architecture doc, not by this freeze.

## Change procedure

1. Write a short proposal (what, why, which consumers break) and send it to the overseer.
2. Overseer approves → the edit lands in one commit together with all consumer/mocks updates → tag bumps (`interfaces-v2`, …).
3. Until then, code against the frozen version and adapt on your side (wrappers, mocks).

Appending members to `Category` is the expected change; **reordering enum members or struct fields is never acceptable** (ABI/storage hazards).
