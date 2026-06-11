// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BountyEngine} from "../../src/BountyEngine.sol";
import {Category} from "../../src/interfaces/Types.sol";

/// @title  Scenario: the daily game cycle against the real registry (agent 6)
/// @notice Charter scenario 3: commit → roll 15 blocks → reveal draws a sentence from the
///         REAL alive registry → claims at claim-time ownership → partial claims → sweep.
///         Lapse path via expireCommit at the exact blockhash-window boundary. A word
///         unbound between reveal and claim falls through to the sweep. Treasury exactly at
///         the minimum-tier commit gate. Category drained to zero → infeasible templates
///         are skipped / reveal aborts cleanly.
///
///         The treasury is funded through the REAL pipeline at least once (swap → skim →
///         flush → bounty slice); later cycles top up via direct deposit() (also a real,
///         permissionless path) to keep the suite fast.
contract DailyGameTest is IntegrationBase {
    function setUp() public {
        _deployProtocol();
        _mintOutCollection();
        _syncRegistry(); // SPEC-3: the registry MUST be synced before any commit
        _seedPool();
        _seal();
        _enableTrading();
        _expireGuard();
        _addLaunchTemplates();
    }

    // ─────────────────────────────── the happy cycle ───────────────────────────────────

    /// @dev Full cycle with the treasury funded by real swap fees: commit → reveal →
    ///      sentence structurally valid against the real registry → claims → sweep.
    function test_dailyCycle_swapFunded_commitRevealClaimSweep() public {
        // Fund the treasury through the real pipeline: 45 ETH of buys skim 0.45 ETH;
        // the 25% bounty slice (0.1125 ETH) covers the 0.102 ETH commit gate.
        _buyExactIn(bob, 15 ether);
        _buyExactIn(bob, 15 ether);
        _buyExactIn(bob, 15 ether);
        vm.prank(keeper);
        hook.flush();
        assertGe(bounty.freeTreasury(), 0.102 ether, "swap-fed treasury covers the commit gate");

        // Commit (alice holds words; exact bond).
        vm.prank(alice);
        bounty.commit{value: BOND}();
        (address committer, uint64 targetBlock, uint256 eventId) = bounty.currentCommit();
        assertEq(committer, alice);
        assertEq(targetBlock, block.number + 15);

        // Reveal too early at the target block itself.
        vm.roll(targetBlock);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.RevealTooEarly.selector, targetBlock));
        bounty.reveal();

        // Anyone reveals one block later; the revealer earns 2% of the drawn tier and the
        // committer's bond returns.
        vm.roll(uint256(targetBlock) + 1);
        uint256 aliceBefore = alice.balance;
        uint256 keeperBefore = keeper.balance;
        uint256 lockedBefore = bounty.lockedFunds();
        vm.prank(keeper);
        bounty.reveal();

        (uint256[] memory tokenIds, uint256 sharePerWord, uint256 deadline,) = bounty.eventInfo(eventId);
        uint256 n = tokenIds.length;
        assertGt(n, 0, "a sentence was drawn");
        assertEq(alice.balance - aliceBefore, BOND, "bond refunded");
        uint256 tier = sharePerWord * n; // locked amount (sub-n remainder stays free)
        assertEq(bounty.lockedFunds() - lockedBefore, tier, "exactly the prize locked");
        assertGe(keeper.balance - keeperBefore, tier * 200 / 10_000, "revealer reward ~2%");
        assertEq(deadline, block.timestamp + 7 days);

        // The 24h cycle gate bites immediately after a successful reveal (checked before
        // the treasury gate, so it is the binding constraint here).
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(BountyEngine.CycleActive.selector, bounty.lastEventTimestamp() + 24 hours)
        );
        bounty.commit{value: BOND}();

        // The sentence is structurally sound against the REAL registry: alive ids, correct
        // categories per the drawn template, no duplicates.
        for (uint256 i = 0; i < n; ++i) {
            assertTrue(bank.isAlive(tokenIds[i]), "drawn word is alive");
            for (uint256 j = i + 1; j < n; ++j) {
                assertTrue(tokenIds[i] != tokenIds[j], "no duplicate words in a sentence");
            }
        }

        // Claims at claim-time ownership: each drawn word's CURRENT owner claims its share.
        uint256 claimedCount;
        for (uint256 i = 0; i < n; ++i) {
            address owner_ = bank.ownerOf(tokenIds[i]);
            assertTrue(bounty.isClaimable(eventId, tokenIds[i]));
            uint256 before = owner_.balance;
            vm.prank(owner_);
            bounty.claim(eventId, tokenIds[i]);
            assertEq(owner_.balance - before, sharePerWord, "exact share per word");
            assertFalse(bounty.isClaimable(eventId, tokenIds[i]));
            claimedCount++;
            if (claimedCount == n - 1) break; // leave exactly one unclaimed
        }

        // Double-claim reverts; non-owner claim reverts.
        vm.prank(bank.ownerOf(tokenIds[0]));
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.AlreadyClaimed.selector, eventId, tokenIds[0]));
        bounty.claim(eventId, tokenIds[0]);

        // Sweep before the deadline reverts; after it, the partial remainder returns.
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.DeadlineNotPassed.selector, deadline));
        bounty.sweep(eventId);

        vm.warp(deadline + 1);
        uint256 freeBefore = bounty.freeTreasury();
        bounty.sweep(eventId);
        assertEq(bounty.freeTreasury() - freeBefore, sharePerWord, "one unclaimed share swept back");
        assertEq(bounty.lockedFunds(), 0, "nothing stays locked after sweep");

        // Idempotence: the second sweep reverts.
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.AlreadySwept.selector, eventId));
        bounty.sweep(eventId);

        // Well past the cycle now (deadline was +7 days): a fresh commit goes through once
        // the treasury is topped back up (the first event's payouts spent it down).
        bounty.deposit{value: 0.2 ether}();
        vm.prank(alice);
        bounty.commit{value: BOND}();
    }

    // ────────────────────────────────── SPEC-3 gate ────────────────────────────────────

    /// @dev The architecture's on-chain game-start gate, asserted against the real WordBank
    ///      in all three regimes: pre-reveal, mid-build, and synced.
    function test_spec3_commitGatedUntilRegistrySynced() public {
        // A second, independent deployment that is NOT synced (the suite fixture is).
        // Stage it manually to hold at each regime.
        DailyGameSpec3Harness harness = new DailyGameSpec3Harness();
        harness.stageToPreReveal();
        harness.assertCommitRevertsPreReveal();
        harness.stageToMidBuild();
        harness.assertCommitRevertsMidBuild();
        harness.stageToSynced();
        harness.assertCommitSucceedsOnceSynced();
    }

    // ───────────────────────────────── lapse / expiry ──────────────────────────────────

    /// @dev The reveal window is the natural 256-block blockhash remainder; expireCommit
    ///      forfeits the bond at the exact boundary and immediately frees a fresh commit.
    function test_lapse_expireCommitAtWindowBoundary() public {
        vm.deal(address(bounty), 1 ether); // donation-funded treasury (real path)

        vm.prank(alice);
        bounty.commit{value: BOND}();
        (, uint64 targetBlock, uint256 eventId) = bounty.currentCommit();
        uint256 lastRevealBlock = uint256(targetBlock) + 256;

        // At the boundary the window is still open: reveal works, expire does not.
        vm.roll(lastRevealBlock);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.RevealWindowStillOpen.selector, lastRevealBlock));
        bounty.expireCommit();

        // One block past: reveal is dead, expiry is live.
        vm.roll(lastRevealBlock + 1);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.RevealWindowExpired.selector, lastRevealBlock));
        bounty.reveal();

        uint256 freeBefore = bounty.freeTreasury();
        bounty.expireCommit(); // anyone
        assertEq(bounty.freeTreasury() - freeBefore, BOND, "bond forfeits to the free treasury");
        (address committer,,) = bounty.currentCommit();
        assertEq(committer, address(0));

        // The cycle was NOT consumed: a fresh commit is allowed immediately.
        vm.prank(bob);
        bounty.commit{value: BOND}();
        (,, uint256 newEventId) = bounty.currentCommit();
        assertGt(newEventId, eventId, "fresh eventId after a lapse");
    }

    // ─────────────────────── burned word between reveal and claim ──────────────────────

    /// @dev A word unbound after generation but before claiming: its share is permanently
    ///      unclaimable (ownerOf reverts at claim) and falls through to the sweep — share
    ///      math is never redistributed.
    function test_burnedWord_shareFallsThroughToSweep() public {
        vm.deal(address(bounty), 1 ether);
        uint256 eventId = _commitAndReveal(alice, keeper);
        (uint256[] memory tokenIds, uint256 sharePerWord, uint256 deadline,) = bounty.eventInfo(eventId);

        // The first drawn word's owner unbinds it before claiming.
        uint256 burnedId = tokenIds[0];
        address owner_ = bank.ownerOf(burnedId);
        vm.prank(owner_);
        bank.unbind(burnedId);

        assertFalse(bounty.isClaimable(eventId, burnedId), "burned word reads unclaimable");
        vm.prank(owner_);
        vm.expectRevert(); // ownerOf reverts for a burned id — claim-time ownership
        bounty.claim(eventId, burnedId);

        // Everyone else still claims their exact, unchanged share (no redistribution).
        for (uint256 i = 1; i < tokenIds.length; ++i) {
            address o = bank.ownerOf(tokenIds[i]);
            uint256 before = o.balance;
            vm.prank(o);
            bounty.claim(eventId, tokenIds[i]);
            assertEq(o.balance - before, sharePerWord);
        }

        // The burned word's share is exactly what the sweep returns.
        vm.warp(deadline + 1);
        uint256 freeBefore = bounty.freeTreasury();
        bounty.sweep(eventId);
        assertEq(bounty.freeTreasury() - freeBefore, sharePerWord, "burned share falls to the sweep");
    }

    // ─────────────────────────── treasury boundary / tiers ─────────────────────────────

    /// @dev Commit gate at exactly the cheapest full event cost (0.05 ETH floor tier + 2%
    ///      reward — owner tier-floor change, 2026-06-13): one wei short reverts, exact
    ///      passes. [Value-only update by agent 4 under that change order; agent 6 review.]
    function test_treasuryExactlyAtMinimumTierBoundary() public {
        uint256 minCost = 0.05 ether + (0.05 ether * 200) / 10_000; // 0.051 ETH

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.InsufficientTreasury.selector, 0, minCost));
        bounty.commit{value: BOND}();

        bounty.deposit{value: minCost - 1}();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.InsufficientTreasury.selector, minCost - 1, minCost));
        bounty.commit{value: BOND}();

        bounty.deposit{value: 1}();
        vm.prank(alice);
        bounty.commit{value: BOND}(); // exactly at the gate

        // With only the minimum affordable, the reveal must draw the 0.05 floor tier.
        (, uint64 targetBlock, uint256 eventId) = bounty.currentCommit();
        vm.roll(uint256(targetBlock) + 1);
        bounty.reveal();
        (uint256[] memory ids, uint256 sharePerWord,,) = bounty.eventInfo(eventId);
        assertEq(sharePerWord, 0.05 ether / ids.length, "only the affordable tier is drawable");
    }

    // ─────────────────────────── category drained mid-game ─────────────────────────────

    /// @dev Drains ADV below a 7-slot template's needs: the reveal SKIPS the infeasible
    ///      template (still succeeding via the 3-slot one), then — with every template
    ///      infeasible — aborts cleanly: bond back, nothing locked, cycle unconsumed.
    function test_categoryDrained_templateSkipped_thenCleanAbort() public {
        vm.deal(address(bounty), 1 ether);

        // Drain ADV to exactly 1 alive (the 7-slot template needs 2 ADV; the 3-slot needs
        // none). The fixture owner of each ADV word unbinds it.
        _drainCategory(Category.ADV, 1);

        uint256 eventId = _commitAndReveal(alice, keeper);
        (uint256[] memory tokenIds,,,) = bounty.eventInfo(eventId);
        assertEq(tokenIds.length, 3, "infeasible 7-slot template skipped; 3-slot drawn");
        for (uint256 i = 0; i < 3; ++i) {
            assertTrue(uint8(bank.categoryOf(tokenIds[i])) != uint8(Category.ADV) || bank.aliveCount(Category.ADV) >= 1);
        }

        // Now drain NOUN to zero: BOTH templates need a NOUN → reveal must abort cleanly.
        _drainCategory(Category.NOUN, 0);
        vm.warp(block.timestamp + 24 hours);

        vm.prank(alice);
        bounty.commit{value: BOND}();
        (, uint64 targetBlock, uint256 abortId) = bounty.currentCommit();
        uint256 aliceBefore = alice.balance;
        uint256 lockedBefore = bounty.lockedFunds();
        vm.roll(uint256(targetBlock) + 1);
        vm.expectEmit(true, true, false, false);
        emit BountyEngine.RevealAborted(abortId, alice);
        vm.prank(keeper);
        bounty.reveal();

        assertEq(alice.balance - aliceBefore, BOND, "abort refunds the bond");
        assertEq(bounty.lockedFunds(), lockedBefore, "abort locks nothing");
        (uint256[] memory noIds,, uint256 noDeadline,) = bounty.eventInfo(abortId);
        assertEq(noIds.length, 0);
        assertEq(noDeadline, 0, "aborted eventId never gets a record");

        // Cycle unconsumed: an immediate fresh commit is allowed.
        vm.prank(alice);
        bounty.commit{value: BOND}();
    }

    /// @dev Unbinds alive words of `cat` until exactly `target` remain. Each unbind is by
    ///      that word's real owner — pure protocol usage, no shortcuts.
    function _drainCategory(Category cat, uint256 target) internal {
        while (bank.aliveCount(cat) > target) {
            uint256 id = bank.aliveAt(cat, bank.aliveCount(cat) - 1);
            address owner_ = bank.ownerOf(id);
            vm.prank(owner_);
            bank.unbind(id);
        }
    }
}

/// @notice SPEC-3 staging harness: an independent protocol deployment held at each registry
///         regime so the gate can be asserted exactly where it bites. Lives in its own
///         contract because the FeeHook's deterministic deployCodeTo address cannot be
///         redeployed mid-test — and SPEC-3 needs no pool at all.
contract DailyGameSpec3Harness is IntegrationBase {
    constructor() {
        _deployProtocol();
        _addLaunchTemplates();
        vm.deal(address(bounty), 1 ether); // treasury is NOT the gate under test
    }

    function stageToPreReveal() external {
        _mintOutCollection(); // arms the offset; nothing revealed, nothing registered
    }

    function assertCommitRevertsPreReveal() external {
        assertFalse(bank.registrySynced());
        vm.prank(alice);
        vm.expectRevert(BountyEngine.RegistryNotSynced.selector);
        bounty.commit{value: 0.01 ether}();
    }

    function stageToMidBuild() external {
        vm.roll(bank.offsetTargetBlock() + 1);
        bank.revealOffset();
        bank.buildRegistry(4_000); // 4,000 of 9,800 — mid-build
    }

    function assertCommitRevertsMidBuild() external {
        assertTrue(bank.offsetSet());
        assertFalse(bank.registrySynced());
        vm.prank(alice);
        vm.expectRevert(BountyEngine.RegistryNotSynced.selector);
        bounty.commit{value: 0.01 ether}();
    }

    function stageToSynced() external {
        while (!bank.registrySynced()) {
            bank.buildRegistry(2_500);
        }
    }

    function assertCommitSucceedsOnceSynced() external {
        assertTrue(bank.registrySynced());
        vm.prank(alice);
        bounty.commit{value: 0.01 ether}();
        (address committer,,) = bounty.currentCommit();
        assertEq(committer, alice, "gate opens exactly at sync");
    }
}
