// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {CoreInvariantBase} from "./CoreInvariantBase.sol";
import {CoreHandler} from "./handlers/CoreHandler.sol";
import {WordBank} from "../../src/WordBank.sol";

/// @title  Core lifecycle invariant suite (agent 6)
/// @notice Starts at the Setup phase with slots locked and dependencies wired, and lets the
///         handler drive the ENTIRE protocol arc inside each run: sale configuration, both
///         mint phases (with pauses and reconfiguration), the 9,800-sellout offset arming,
///         reveal — including deliberately lapsed windows and re-arms — the permissionless
///         registry build, deposits (including the zero-alive deferral before the first
///         mint), claims, transfers, unbinds, the liquidity allotment, the supply seal, and
///         buy-and-burn down to the floor. All system invariants are checked after every
///         single action, in every regime the protocol can be in.
/// @dev    fail-on-revert is ON (stricter than the repo-wide default): the handler is
///         revert-free by construction, so any revert is a real finding.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract CoreLifecycleInvariantTest is CoreInvariantBase {
    function setUp() public {
        _deployCore();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = CoreHandler.actOpenSale.selector;
        selectors[1] = CoreHandler.actReconfigure.selector;
        selectors[2] = CoreHandler.actAdvancePhase.selector;
        selectors[3] = CoreHandler.actEarlyBirdMint.selector;
        selectors[4] = CoreHandler.actPublicMint.selector;
        selectors[5] = CoreHandler.actAdminMint.selector;
        selectors[6] = CoreHandler.actRevealOffset.selector;
        selectors[7] = CoreHandler.actLapseAndRearm.selector;
        selectors[8] = CoreHandler.actBuildRegistry.selector;
        selectors[9] = CoreHandler.actDeposit.selector;
        selectors[10] = CoreHandler.actClaim.selector;
        selectors[11] = CoreHandler.actTransfer.selector;
        selectors[12] = CoreHandler.actUnbind.selector;
        selectors[13] = CoreHandler.actUnbindMany.selector;
        selectors[14] = CoreHandler.actSweepDust.selector;
        selectors[15] = CoreHandler.actMintLiquidity.selector;
        selectors[16] = CoreHandler.actSealMinting.selector;
        selectors[17] = CoreHandler.actBurn.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Fixture smoke test: the suite really does start at Setup with a locked slot
    ///      list, wired dependencies, and nothing minted.
    function test_lifecycleFixture() public view {
        assertTrue(bank.slotsLocked());
        assertEq(uint8(bank.phase()), uint8(WordBank.SalePhase.Setup));
        assertEq(bank.totalMinted(), 0);
        assertEq(token.totalSupply(), 0);
        assertEq(token.burner(), address(handler));
        assertFalse(bank.offsetSet());
    }

    /// @notice Deterministic guided walk through the FULL lifecycle, re-checking every
    ///         invariant after each step. The fuzzed runs above explore interleavings but
    ///         cannot guarantee any single run reaches the terminal regime; this test
    ///         guarantees the whole arc — deferred zero-alive deposit, early bird sellout
    ///         auto-advance, public sellout arming the offset, a lapsed reveal window with
    ///         permissionless re-arm, registry build, reserve mint, transfers/unbinds/
    ///         claims, liquidity, seal, and buy-and-burn landing exactly on the floor — is
    ///         exercised under the invariants on every CI run.
    function test_guidedFullLifecycle() public {
        // Deposit before any mint exists: must defer, not revert (SPEC-2 regime).
        handler.actDeposit(0, 1 ether);
        assertEq(distributor.pendingUndistributed(), 1 ether, "zero-alive deposit not deferred");
        _checkAllInvariants();

        // Open: 3,000 early bird / 6,800 public, wallet cap 700.
        handler.actOpenSale(3_000, 700);

        // Five actors x 600 sell out early bird exactly -> auto-advance to PublicSale;
        // the sixth call must no-op against the advanced phase.
        for (uint256 i = 0; i < 6; ++i) {
            handler.actEarlyBirdMint(i, 600, 1);
        }
        assertEq(uint8(bank.phase()), uint8(WordBank.SalePhase.PublicSale), "early bird sellout did not auto-advance");
        assertEq(bank.earlyBirdMinted(), 3_000);
        _checkAllInvariants();

        // Mid-mint economy: the deferred buffer folds into this deposit; claims pay.
        handler.actDeposit(1, 10 ether);
        assertEq(distributor.pendingUndistributed(), 0, "deferred buffer did not fold");
        handler.actClaim(0, 7);
        _checkAllInvariants();

        // Public sellout in one stroke (seed % 3 == 0 -> full remaining) arms the offset.
        handler.actPublicMint(2, 1, 3);
        assertEq(bank.totalMinted(), 9_800);
        assertTrue(bank.offsetTargetBlock() != 0, "offset not armed at public sellout");
        _checkAllInvariants();

        // Let the 256-block reveal window lapse, re-arm permissionlessly, then reveal.
        handler.actLapseAndRearm();
        assertFalse(bank.offsetSet());
        handler.actRevealOffset();
        assertTrue(bank.offsetSet(), "offset not revealed after re-arm");
        _checkAllInvariants();

        // Build the registry in two chunks; invariants hold in the half-built state.
        handler.actBuildRegistry(3_000, 1);
        assertFalse(bank.registrySynced());
        _checkAllInvariants();
        handler.actBuildRegistry(0, 0);
        assertTrue(bank.registrySynced(), "registry not synced after full build");
        _checkAllInvariants();

        // Admin reserve (registers eagerly post-reveal), then live-economy churn.
        handler.actAdminMint(0, 1, 0);
        assertEq(bank.totalMinted(), 10_000);
        handler.actDeposit(2, 25 ether);
        handler.actTransfer(0, 1, 12_345);
        handler.actUnbind(1, 999);
        handler.actUnbindMany(2, 4);
        handler.actClaim(1, 3);
        handler.actSweepDust();
        _checkAllInvariants();

        // Liquidity allotment + permissionless seal at exactly 11M.
        handler.actMintLiquidity(0, 0);
        handler.actSealMinting();
        assertTrue(token.mintingSealed(), "seal preconditions met but not sealed");
        _checkAllInvariants();

        // Dynamic floor: burning descends supply toward the LIVE floor (totalAlive×1000e18),
        // never below it, and there is no permanent completion.
        uint256 floorAtSeal = bank.totalAlive() * BACKING;
        assertEq(token.burnableExcess(), token.totalSupply() - floorAtSeal, "excess = supply - live floor");
        handler.actBurn(400_000e18, 1);
        assertEq(token.burnedTotal(), 400_000e18);
        assertGe(token.totalSupply(), bank.totalAlive() * BACKING, "never below the live floor");
        _checkAllInvariants();

        // Burn the rest of the handler's liquidity balance; burning simply pauses once the
        // balance (or the current excess) is exhausted — no burnComplete latch.
        handler.actBurn(0, 5); // seed % 5 == 0 -> burn the full burnable-or-balance amount
        assertGe(token.totalSupply(), bank.totalAlive() * BACKING, "supply rests at/above the floor");
        _checkAllInvariants();

        // Resume condition: an unbind lowers totalAlive, so the live floor descends and fresh
        // burnable excess appears — the whole point of the dynamic floor. Actor 2 holds the
        // bulk of the public mint, so this unbind fires.
        uint256 floorBefore = token.currentBurnFloor();
        uint256 excessBefore = token.burnableExcess();
        uint256 aliveBefore = bank.totalAlive();
        handler.actUnbind(2, 77);
        uint256 freed = aliveBefore - bank.totalAlive();
        assertGt(freed, 0, "resume unbind must actually burn an NFT");
        assertEq(token.currentBurnFloor(), floorBefore - freed * BACKING, "floor descends by freed backing");
        assertEq(token.burnableExcess(), excessBefore + freed * BACKING, "freed backing became burnable excess");
        _checkAllInvariants();

        // Economy keeps running afterward.
        handler.actDeposit(3, 5 ether);
        handler.actClaim(2, 9);
        _checkAllInvariants();
    }

    /// @dev Runs every invariant function as a plain assertion battery.
    function _checkAllInvariants() internal view {
        invariant_backingCoversAliveExactly();
        invariant_supplyAccounting();
        invariant_dynamicFloor();
        invariant_registryCountsSum();
        invariant_registrySampled();
        invariant_unboundStayDeadSampled();
        invariant_distributorSolvency();
        invariant_distributorEthConservation();
    }
}
