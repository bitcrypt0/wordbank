// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {IntegrationBase} from "./IntegrationBase.sol";
import {Category} from "../../src/interfaces/Types.sol";

/// @title  Gas bench — hot-path metering for the integration report (agent 6)
/// @notice Measures the charter's named hot paths against the real, fully-wired stack:
///         swap-with-hook (buy + sell), claimRewards at several batch sizes, unbind /
///         unbindMany, reveal, and executeBuyback. Numbers are logged and copied into
///         test/integration/REPORT.md; regressions > 5% are flagged there. These are
///         `gasleft()` deltas around the external call (call overhead included), so they
///         track real user cost, not just the function body.
contract GasBenchTest is IntegrationBase {
    function setUp() public {
        _deployProtocol();
        _mintOutCollection();
        _syncRegistry();
        _seedPool();
        _seal();
        _enableTrading();
        _expireGuard();
        _addLaunchTemplates();
    }

    function test_gas_hotPaths() public {
        console2.log("=== WORDBANK hot-path gas (real stack, local V4) ===");

        // ── swap with hook: exact-in buy (skim in beforeSwap). ──
        uint256 g = gasleft();
        _buyExactIn(bob, 1 ether);
        console2.log("swap buy (exact-in, hook skim) ", g - gasleft());

        // ── swap with hook: exact-in sell (skim in afterSwap). ──
        g = gasleft();
        _sellExactIn(bob, 500e18);
        console2.log("swap sell (exact-in, hook skim)", g - gasleft());

        // ── flush: route the three-way split. ──
        g = gasleft();
        hook.flush();
        console2.log("flush (three-way route)        ", g - gasleft());

        // ── claimRewards at batch sizes 1 / 5 / 20. ──
        _buyExactIn(bob, 5 ether);
        hook.flush();
        _benchClaim(1);
        _benchClaim(5);
        _benchClaim(20);

        // ── reveal: draw a sentence from the real registry. ──
        bounty.deposit{value: 1 ether}();
        vm.prank(alice);
        bounty.commit{value: BOND}();
        (, uint64 targetBlock,) = bounty.currentCommit();
        vm.roll(uint256(targetBlock) + 1);
        g = gasleft();
        vm.prank(keeper);
        bounty.reveal();
        console2.log("reveal (commit-reveal draw)    ", g - gasleft());

        // ── unbind (single) and unbindMany (10). ──
        uint256 id = _firstOwnedToken(carol);
        g = gasleft();
        vm.prank(carol);
        bank.unbind(id);
        console2.log("unbind (single, force-settle)  ", g - gasleft());

        uint256[] memory ids = _ownedSlice(carol, 10);
        g = gasleft();
        vm.prank(carol);
        bank.unbindMany(ids);
        console2.log("unbindMany (10)                ", g - gasleft());

        // ── executeBuyback on the real pool. ──
        burnEngine.deposit{value: 1 ether}();
        vm.roll(block.number + 1);
        g = gasleft();
        vm.prank(keeper);
        burnEngine.executeBuyback(1 ether);
        console2.log("executeBuyback (swap + burn)   ", g - gasleft());

        // ── distribute: royalty equal-thirds split (ETH path, EOA admin). ──
        vm.deal(address(this), 9 ether);
        (bool ok,) = address(royaltySplitter).call{value: 9 ether}("");
        assertTrue(ok);
        g = gasleft();
        royaltySplitter.distribute();
        console2.log("royalty distribute (3-way)     ", g - gasleft());
    }

    function _benchClaim(uint256 n) internal {
        uint256[] memory ids = _ownedSlice(alice, n);
        uint256 g = gasleft();
        vm.prank(alice);
        distributor.claimRewards(ids);
        console2.log(string.concat("claimRewards (batch ", vm.toString(n), ")"), g - gasleft());
    }

    /// @dev First `n` alive tokenIds owned by `owner_`.
    function _ownedSlice(address owner_, uint256 n) internal view returns (uint256[] memory ids) {
        ids = new uint256[](n);
        uint256 found;
        uint256 minted = bank.totalMinted();
        for (uint256 id = 1; id <= minted && found < n; ++id) {
            if (bank.isAlive(id) && bank.ownerOf(id) == owner_) ids[found++] = id;
        }
        require(found == n, "not enough owned tokens");
    }
}
