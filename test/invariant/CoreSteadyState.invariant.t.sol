// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {CoreInvariantBase} from "./CoreInvariantBase.sol";
import {CoreHandler} from "./handlers/CoreHandler.sol";
import {Category} from "../../src/interfaces/Types.sol";
import {WordToken} from "../../src/WordToken.sol";

/// @title  Core steady-state invariant suite (agent 6)
/// @notice Seeds the post-launch world — all 10,000 NFTs minted across six actors, offset
///         revealed, registry fully synced, 1M liquidity minted, supply sealed at 11M —
///         then fuzzes the live economy deeply: deposits, claims, NFT transfers with
///         pending rewards, unbinds (single and batched, with force-settles), dust sweeps,
///         and buy-and-burn against the dynamic floor (totalAlive×1000e18) — which descends
///         as NFTs unbind, so burning pauses at the floor and resumes after each unbind, with
///         no permanent completion. This is the regime the protocol spends its life in; the
///         lifecycle suite covers how it gets here.
/// @dev    fail-on-revert is ON: any revert reaching the contracts is a real finding.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract CoreSteadyStateInvariantTest is CoreInvariantBase {
    function setUp() public {
        _deployCore();
        handler.seedSteadyState();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = CoreHandler.actDeposit.selector;
        selectors[1] = CoreHandler.actClaim.selector;
        selectors[2] = CoreHandler.actTransfer.selector;
        selectors[3] = CoreHandler.actUnbind.selector;
        selectors[4] = CoreHandler.actUnbindMany.selector;
        selectors[5] = CoreHandler.actSweepDust.selector;
        selectors[6] = CoreHandler.actBurn.selector;
        selectors[7] = CoreHandler.actAdminMint.selector; // exhausted in seed — must stay a no-op
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Fixture smoke test: the seeded world is exactly the post-launch steady state.
    function test_steadyStateFixture() public view {
        assertEq(bank.totalMinted(), 10_000);
        assertEq(bank.totalAlive(), 10_000);
        assertTrue(bank.offsetSet());
        assertTrue(bank.registrySynced());
        assertTrue(token.mintingSealed());
        assertEq(token.totalSupply(), 11_000_000e18);
        assertEq(token.balanceOf(address(bank)), 10_000_000e18);
        assertEq(token.balanceOf(address(handler)), 1_000_000e18);
        assertEq(token.burner(), address(handler));
        // Dynamic floor at full collection: floor == 10M, supply == 11M, excess == 1M.
        assertEq(token.currentBurnFloor(), 10_000_000e18);
        assertEq(token.burnableExcess(), 1_000_000e18);

        uint256 sum;
        for (uint8 c = 0; c < 4; ++c) {
            sum += bank.aliveCount(_cat(c));
        }
        assertEq(sum, 10_000);
    }

    function _cat(uint8 c) internal pure returns (Category) {
        return Category(c);
    }

    /// @notice THE dynamic-floor scenario, proven against the REAL WordToken + WordBank (no
    ///         pool — the handler is the wired burner and holds the full 1M liquidity, so the
    ///         entire burnable excess is reachable; the pooled cross-contract version lives in
    ///         BuybackAdversarial). Burn the excess to the live floor → burning pauses (a
    ///         further burn reverts `BurnFloorBreached`) → a REAL unbind lowers `totalAlive`
    ///         and the floor, freeing fresh excess → burning resumes down to the new, lower
    ///         floor. There is no `burnComplete` and no permanent retirement.
    function test_dynamicFloor_burnToFloor_pauseAndResume() public {
        // Start: 10,000 alive → floor 10M, supply 11M, excess 1M (the liquidity allotment,
        // held entirely by the handler/burner here).
        assertEq(token.currentBurnFloor(), 10_000_000e18);
        assertEq(token.burnableExcess(), 1_000_000e18);
        assertEq(token.balanceOf(address(handler)), 1_000_000e18);

        // Burn the entire current excess (burner-path) → supply rests EXACTLY on the floor.
        // (Compute the amount first: a call in the argument position would otherwise consume
        // the prank meant for burn().)
        uint256 excess = token.burnableExcess();
        vm.prank(address(handler));
        token.burn(excess);
        assertEq(token.burnableExcess(), 0, "excess consumed: supply at the live floor");
        assertEq(token.totalSupply(), token.currentBurnFloor(), "supply == floor");
        assertEq(token.totalSupply(), 10_000_000e18);

        // At the floor burning pauses: any further burn reverts (no permanent completion flag,
        // just the live floor check).
        vm.prank(address(handler));
        vm.expectRevert(WordToken.BurnFloorBreached.selector);
        token.burn(1);

        // A REAL unbind lowers totalAlive by 1, dropping the floor by 1,000e18 and freeing
        // exactly that NFT's released backing as new burnable excess (supply is unchanged —
        // the 1,000 WORD is released to the unbinder, not burned).
        (address unbinder, uint256 freedId) = _anyAliveOwned();
        uint256 floorBefore = token.currentBurnFloor();
        uint256 supplyBefore = token.totalSupply();
        vm.prank(unbinder);
        bank.unbind(freedId);
        assertEq(token.currentBurnFloor(), floorBefore - BACKING, "floor dropped one NFT's backing");
        assertEq(token.totalSupply(), supplyBefore, "unbind does not change supply");
        assertEq(token.burnableExcess(), BACKING, "freed backing is now burnable excess");

        // Burning RESUMES: the unbinder funds the burner with the freed WORD and the engine
        // burns it down to the new, lower floor. Excess back to 0; no completion latch.
        vm.prank(unbinder);
        token.transfer(address(handler), BACKING);
        vm.prank(address(handler));
        token.burn(BACKING);
        assertEq(token.burnableExcess(), 0, "freed excess fully consumed");
        assertEq(token.totalSupply(), token.currentBurnFloor(), "supply rests on the new lower floor");
        assertEq(token.currentBurnFloor(), 9_999_000e18, "new floor = 9,999 x 1000e18");

        // And it can resume again after the next unbind — no permanent end.
        (address u2, uint256 id2) = _anyAliveOwned();
        vm.prank(u2);
        bank.unbind(id2);
        assertEq(token.burnableExcess(), BACKING, "excess reappears after the next unbind");
    }

    /// @dev Returns any (owner, tokenId) that is alive and registered (unbindable).
    function _anyAliveOwned() internal view returns (address owner_, uint256 tokenId) {
        uint256 minted = bank.totalMinted();
        for (uint256 id = 1; id <= minted; ++id) {
            if (bank.isAlive(id) && bank.indexInCategory(id) != 0) {
                return (bank.ownerOf(id), id);
            }
        }
        revert("no alive token");
    }
}
