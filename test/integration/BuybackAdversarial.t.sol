// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IntegrationBase} from "./IntegrationBase.sol";

/// @title  Scenario: buy-and-burn under adversarial ordering + the dynamic-floor resume arc
/// @notice System invariant 9 made executable on the real pool (interfaces-v3, dynamic floor):
///         a sandwich around `executeBuyback` is loss-bounded by the slippage guard and
///         unprofitable at launch economics; a real buyback burns burnable excess and a flush
///         routes the burn slice three-way while excess exists; and — THE behaviour the
///         dynamic floor exists for — a real WordBank unbind lowers `totalAlive`, dropping the
///         live floor and freeing fresh burnable excess, so the next buyback resumes burning.
///
///         The exact excess→0 / pause / `NoBurnableExcess` boundary is proven against the real
///         WordToken+WordBank (no pool) in CoreSteadyState's
///         `test_dynamicFloor_burnToFloor_pauseAndResume`, and at the unit level by Agent 5's
///         BurnEngine suite; here the value-add is the cross-contract path with a REAL unbind
///         and the REAL FeeHook routing on a live pool. (A pool always holds WORD, so live
///         `burnableExcess()` is bounded below by the pool's WORD and never reaches exactly 0
///         in a pooled fixture — hence the boundary lives in the no-pool suite.)
contract BuybackAdversarialTest is IntegrationBase {
    function setUp() public {
        _deployProtocol();
        _mintOutCollection();
        _syncRegistry();
        _seedPool();
        _seal(); // SYS-1: buybacks are live only from the seal
        _enableTrading();
        _expireGuard();
    }

    // ───────────────────────────── sandwich economics ──────────────────────────────────

    /// @dev A sandwicher frontruns the buyback (pumping spot), lets the keeper execute, then
    ///      backruns. The engine sizes against the manipulated spot (documented residual
    ///      exposure) but its per-call spend is hard-capped at 1 ETH, and the attacker pays
    ///      the 1% hook skim plus the 0.3% LP fee TWICE on the attack volume, so the round
    ///      trip loses money at launch economics. The buyback never drives supply below the
    ///      live floor.
    function test_sandwich_lossBoundedAndUnprofitable() public {
        burnEngine.deposit{value: 5 ether}();

        for (uint256 attackEth = 5 ether; attackEth <= 45 ether; attackEth += 20 ether) {
            uint256 attackerStart = bob.balance;

            // Frontrun: pump WORD spot with a big buy.
            _buyExactIn(bob, attackEth);
            uint256 wordGot = token.balanceOf(bob);

            // The buyback executes against the manipulated spot; spend hard-capped at 1 ETH.
            uint256 engineBefore = address(burnEngine).balance;
            vm.roll(block.number + 1);
            vm.prank(keeper);
            burnEngine.executeBuyback(1 ether);
            assertLe(engineBefore - address(burnEngine).balance, 1 ether, "per-call spend hard cap");

            // Backrun: dump everything bought.
            _sellExactIn(bob, wordGot);

            assertLt(bob.balance, attackerStart, "sandwich round trip loses money at launch economics");
        }

        assertGe(token.totalSupply(), bank.totalAlive() * BACKING, "floor untouched under adversarial ordering");
    }

    // ─────────────────── real buyback + 3-way routing while excess exists ───────────────

    /// @dev A real pool buyback burns burnable excess (100% of what it buys), and a flush
    ///      while excess exists routes the burn slice three-way (50/25/25) to the engine.
    function test_realBuybackBurnsExcess_flushRoutesThreeWay() public {
        // Full collection: floor 10M, supply 11M, excess 1M.
        assertEq(token.currentBurnFloor(), 10_000_000e18);
        assertEq(token.burnableExcess(), 1_000_000e18);

        // A real buyback burns 100% of what it buys and reduces excess by exactly that.
        burnEngine.deposit{value: 2 ether}();
        uint256 excessBefore = token.burnableExcess();
        uint256 supplyBefore = token.totalSupply();
        vm.roll(block.number + 1);
        vm.prank(keeper);
        burnEngine.executeBuyback(1 ether);
        uint256 burned = supplyBefore - token.totalSupply();
        assertGt(burned, 0, "buyback burned real WORD");
        assertEq(token.burnableExcess(), excessBefore - burned, "excess fell by exactly what burned");
        assertEq(token.balanceOf(address(burnEngine)), 0, "burned 100% of what it bought");

        // A flush while excess > 0 routes three-way: the burn slice reaches the engine.
        _buyExactIn(bob, 10 ether);
        uint256 accrued = hook.pendingFees();
        uint256 rBefore = address(distributor).balance;
        uint256 btyBefore = address(bounty).balance;
        uint256 eBefore = address(burnEngine).balance;
        hook.flush();
        uint256 dR = address(distributor).balance - rBefore;
        uint256 dB = address(bounty).balance - btyBefore;
        uint256 dE = address(burnEngine).balance - eBefore;
        assertEq(dR, accrued * 5000 / 10_000, "3-way: 50% rewards");
        assertEq(dB, accrued * 2500 / 10_000, "3-way: 25% bounty");
        assertEq(dE, accrued - dR - dB, "3-way: remainder to burn (~25%)");
        assertGt(dE, 0, "burn slice routed while excess exists");
        assertEq(dR + dB + dE, accrued, "slices sum to 100%");
    }

    // ───────────────────── resume after a REAL unbind lowers the floor ──────────────────

    /// @dev THE dynamic-floor behaviour, cross-contract: a real WordBank unbind lowers
    ///      `totalAlive`, which lowers the live floor and frees that backing as new burnable
    ///      excess — so a buyback that had less to do now has more, and burning resumes down
    ///      to the new, lower floor.
    function test_resumeAfterRealUnbindLowersFloor() public {
        burnEngine.deposit{value: 5 ether}();

        // Burn some current excess first (real buyback).
        vm.roll(block.number + 1);
        vm.prank(keeper);
        burnEngine.executeBuyback(1 ether);
        uint256 burnedTotalBefore = token.burnedTotal();

        // A real unbind of 100 NFTs lowers the floor by 100×1000e18 and frees exactly that
        // much new burnable excess (supply is unchanged by unbind — backing is released, not
        // burned).
        uint256 floorBefore = token.currentBurnFloor();
        uint256 excessBefore = token.burnableExcess();
        _unbindOwned(alice, 100);
        assertEq(token.currentBurnFloor(), floorBefore - 100 * BACKING, "floor dropped by freed backing");
        assertEq(token.burnableExcess(), excessBefore + 100 * BACKING, "freed backing became burnable excess");
        assertEq(token.totalSupply(), 11_000_000e18 - token.burnedTotal(), "unbind did not change supply");

        // Burning resumes: another real buyback burns more, still never below the new floor.
        vm.roll(block.number + 1);
        vm.prank(keeper);
        burnEngine.executeBuyback(1 ether);
        assertGt(token.burnedTotal(), burnedTotalBefore, "burning resumed after the unbind");
        assertGe(token.totalSupply(), bank.totalAlive() * BACKING, "never below the live (lowered) floor");
    }

    /// @dev Unbinds the first `n` alive tokenIds owned by `owner_`, in batches of 50.
    function _unbindOwned(address owner_, uint256 n) internal {
        uint256 minted = bank.totalMinted();
        uint256 remaining = n;
        while (remaining > 0) {
            uint256 take = remaining < 50 ? remaining : 50;
            uint256[] memory ids = new uint256[](take);
            uint256 k;
            uint256 id = 1;
            while (k < take && id <= minted) {
                if (bank.isAlive(id) && bank.ownerOf(id) == owner_ && bank.indexInCategory(id) != 0) {
                    ids[k++] = id;
                }
                ++id;
            }
            require(k == take, "owner lacks enough alive tokens");
            vm.prank(owner_);
            bank.unbindMany(ids);
            remaining -= take;
        }
    }
}
