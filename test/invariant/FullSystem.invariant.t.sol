// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2} from "forge-std/console2.sol";

import {IntegrationBase} from "../integration/IntegrationBase.sol";
import {SystemHandler} from "./handlers/SystemHandler.sol";

/// @title  Full-system invariant suite: pool + fees + game + burn together (agent 6)
/// @notice Seeds the complete post-launch protocol — collection minted and synced, pool
///         seeded and trading, supply sealed at 11M, real BurnEngine as the wired burner —
///         then fuzzes the whole economy at once: swaps (paying the real skim), flushes,
///         the daily game cycle (commit/reveal/abort/expire/claim/sweep), buy-and-burn
///         buybacks through the real pool, unbinds, reward claims, and NFT transfers, with
///         time and blocks advancing.
///
///         Encodes the remaining system invariants (root AGENTS.md numbering, dynamic-floor
///         model — interfaces-v3):
///         - 5: lockedFunds ≤ balance, and lockedFunds == Σ remainingLocked(event) exactly
///         - 8: every flush splits to exactly 100% (asserted inside actFlush, per flush);
///              routing is chosen PER FLUSH by live burnable excess (3-way ↔ 2-way), and the
///              burn slice is never routed when burnableExcess() == 0 — no permanent collapse
///         - 9: supply never below the DYNAMIC floor (totalAlive×1000e18); burnedTotal ledger
///              exact; the engine holds zero WORD outside a transaction (burns 100% of what it
///              buys); never permanently retires (burning resumes after each unbind); the
///              own-transaction property is structural (the hook holds no swap logic — see
///              TraitAndStructure.t.sol for the executable check)
///         - 1/2 re-checked here with the REAL burner wired (the core suites used a
///           handler-as-burner stand-in; this suite closes that gap).
///
/// forge-config: default.invariant.runs = 16
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract FullSystemInvariantTest is IntegrationBase {
    SystemHandler internal sys;

    function setUp() public {
        _deployProtocol();
        _mintOutCollection();
        _syncRegistry();
        _seedPool();
        _seal();
        _enableTrading();
        _expireGuard();
        _addLaunchTemplates();

        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = admin;
        sys = new SystemHandler(
            bank, distributor, bounty, burnEngine, hook, royaltySplitter, swapRouter, poolKey, actors
        );

        targetContract(address(sys));
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = SystemHandler.actWarp.selector;
        selectors[1] = SystemHandler.actBuy.selector;
        selectors[2] = SystemHandler.actSell.selector;
        selectors[3] = SystemHandler.actFlush.selector;
        selectors[4] = SystemHandler.actDonateTreasury.selector;
        selectors[5] = SystemHandler.actCommit.selector;
        selectors[6] = SystemHandler.actReveal.selector;
        selectors[7] = SystemHandler.actLapseCommit.selector;
        selectors[8] = SystemHandler.actClaimBounty.selector;
        selectors[9] = SystemHandler.actSweepEvent.selector;
        selectors[10] = SystemHandler.actBuyback.selector;
        selectors[11] = SystemHandler.actUnbind.selector;
        selectors[12] = SystemHandler.actClaimRewards.selector;
        selectors[13] = SystemHandler.actTransferNft.selector;
        selectors[14] = SystemHandler.actRoyaltyDistribute.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(sys), selectors: selectors}));
    }

    // ─────────────────────────── system invariant 5: treasury ──────────────────────────

    /// @notice The treasury can always pay what it locked, with the pending bond on top.
    function invariant_lockedFundsCoveredByBalance() public view {
        uint256 reserved = bounty.lockedFunds();
        (address pending,,) = bounty.currentCommit();
        if (pending != address(0)) reserved += 0.01 ether;
        assertGe(address(bounty).balance, reserved, "INV-5: lockedFunds (+bond) exceed treasury balance");
    }

    /// @notice Exact conservation: lockedFunds is precisely the sum of every revealed
    ///         event's still-locked remainder — claims and sweeps release exactly what
    ///         reveal locked, never more, never less.
    function invariant_lockedFundsEqualSumOfRemainders() public view {
        uint256 sum;
        uint256 n = sys.revealedCount();
        for (uint256 i = 0; i < n; ++i) {
            sum += bounty.remainingLocked(sys.revealedEvents(i));
        }
        assertEq(bounty.lockedFunds(), sum, "INV-5: lockedFunds != sum of event remainders");
    }

    // ──────────────────────────── system invariant 8: routing ──────────────────────────
    // The per-flush 100% split is asserted inside SystemHandler.actFlush on every flush.

    /// @notice Per-flush routing is clean: the burn slice is NEVER routed to the BurnEngine
    ///         on a flush where there was no burnable excess (the burn slice folds into
    ///         rewards/bounty). Accumulated over every flush by the handler — must stay 0.
    ///         There is no one-way collapse; routing flips back to 3-way whenever an unbind
    ///         frees fresh excess.
    function invariant_routingPerFlushClean() public view {
        assertEq(sys.ghostBurnSliceWhileNoExcess(), 0, "INV-8: burn slice routed while burnableExcess() == 0");
    }

    // ──────────────────────────── system invariant 9: the burn ─────────────────────────

    /// @notice Dynamic floor and ledger with the REAL BurnEngine buying on the REAL pool:
    ///         supply never below the LIVE floor (totalAlive×1000e18), burnedTotal ledger
    ///         exact, burnableExcess() == supply − floor. No permanent completion.
    function invariant_burnFloorAndLedger() public view {
        uint256 supply = token.totalSupply();
        uint256 floor = bank.totalAlive() * 1_000e18;
        assertGe(supply, floor, "INV-9: supply below the live backing floor");
        assertLe(supply, 11_000_000e18, "INV-2: supply above 11M");
        assertEq(token.burnedTotal(), 11_000_000e18 - supply, "INV-9: burnedTotal ledger broken");
        assertLe(token.burnedTotal(), 1_000_000e18, "INV-9: burned more than the liquidity allotment");
        assertEq(token.currentBurnFloor(), floor, "INV-9: currentBurnFloor != live floor");
        assertEq(token.burnableExcess(), supply - floor, "INV-9: burnableExcess != supply - floor");
    }

    /// @notice The engine burns 100% of what it buys within the same call — it never sits
    ///         on WORD between transactions.
    function invariant_burnEngineHoldsNoWord() public view {
        assertEq(token.balanceOf(address(burnEngine)), 0, "INV-9: BurnEngine retained WORD");
    }

    // ──────────────────────── RoyaltySplitter (equal-thirds, trustless) ─────────────────

    /// @notice The splitter never holds more than its stuck-admin slice: `pendingAdmin` ≤
    ///         balance always (with the EOA admin here, pendingAdmin stays 0 — the admin
    ///         third always sends). The per-distribute equal-thirds split (toBurn == toBounty,
    ///         |toAdmin − toBurn| ≤ 2, conservation, RewardsDistributor untouched) is asserted
    ///         on every call inside `SystemHandler.actRoyaltyDistribute`.
    function invariant_royaltySplitterSolvent() public view {
        assertLe(royaltySplitter.pendingAdmin(), address(royaltySplitter).balance, "RS: pendingAdmin > balance");
    }

    // ───────────────────────── invariants 1/2 with the real burner ─────────────────────

    /// @notice Backing equality with the REAL burner wired. Exact equality is valid here
    ///         because no handler donates WORD to the vault; the live-chain/monitoring form
    ///         is `>=` (OBS-1: a third-party ERC-20 donation to the WordBank address can
    ///         raise the left side; it can never lower it).
    function invariant_backingCoversAliveExactly() public view {
        assertEq(token.balanceOf(address(bank)), bank.totalAlive() * 1_000e18, "INV-1: vault balance != alive x 1000");
    }

    /// @notice Distributor solvency under the full economy (game + fees + unbinds).
    function invariant_rewardsSolvency() public view {
        uint256 reserved = distributor.pendingUndistributed() + (distributor.owedScaled() + 1e18 - 1) / 1e18;
        assertGe(address(distributor).balance, reserved, "rewards: balance below reserved entitlements");
    }

    // ────────────────────────────────── reporting ──────────────────────────────────────

    function afterInvariant() public view {
        console2.log("-- system handler coverage --");
        console2.log("warp", sys.calls("warp"));
        console2.log("buy", sys.calls("buy"));
        console2.log("sell", sys.calls("sell"));
        console2.log("flush", sys.calls("flush"));
        console2.log("donateTreasury", sys.calls("donateTreasury"));
        console2.log("commit", sys.calls("commit"));
        console2.log("reveal", sys.calls("reveal"));
        console2.log("expireCommit", sys.calls("expireCommit"));
        console2.log("lapseCommit", sys.calls("lapseCommit"));
        console2.log("claimBounty", sys.calls("claimBounty"));
        console2.log("sweepEvent", sys.calls("sweepEvent"));
        console2.log("buyback", sys.calls("buyback"));
        console2.log("unbind", sys.calls("unbind"));
        console2.log("claimRewards", sys.calls("claimRewards"));
        console2.log("transferNft", sys.calls("transferNft"));
        console2.log("royaltyDistribute", sys.calls("royaltyDistribute"));
        console2.log("revealedEvents", sys.revealedCount());
        console2.log("burnedTotal", token.burnedTotal());
    }
}
