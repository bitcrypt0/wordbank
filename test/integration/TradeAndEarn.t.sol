// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IntegrationBase} from "./IntegrationBase.sol";

/// @title  Scenario: trade-and-earn — real swaps feed real holder rewards (agent 6)
/// @notice Charter scenario 2: seed pool → enableTrading → swaps skim 1% of the ETH side →
///         permissionless flush routes 50/25/25 → rewards accrue equally per alive NFT →
///         an NFT transfers WITH its pending rewards → the buyer claims them → unbind
///         force-settles in the same transaction → the survivors' per-NFT rate rises.
///         Also the charter edge sweep: totalAlive driven to 1 and then 0 (terminal state,
///         deposits defer rather than brick).
contract TradeAndEarnTest is IntegrationBase {
    uint256 internal aliceId;

    function setUp() public {
        _deployProtocol();
        _mintOutCollection();
        _syncRegistry();
        _seedPool();
        _seal();
        _enableTrading();
        _expireGuard(); // launch-window behavior has its own scenario suite
        aliceId = _firstOwnedToken(alice);
    }

    /// @dev The full earn loop with exact accounting at every hop.
    function test_tradeAndEarn_swap_flush_accrue_transfer_claim() public {
        // ── Swaps skim exactly 1% of the ETH side, accruing in the hook. ──
        uint256 ethIn = 10 ether;
        _buyExactIn(bob, ethIn);
        uint256 skimBuy = ethIn * 100 / 10_000;
        assertEq(hook.pendingFees(), skimBuy, "buy skim exact");

        uint256 wordIn = 5_000e18;
        // bob sells some of the WORD he just bought; the skim comes off his ETH output.
        _sellExactIn(bob, wordIn);
        uint256 accrued = hook.pendingFees();
        assertGt(accrued, skimBuy, "sell skimmed on top");

        // ── Permissionless flush routes exactly 50/25/25 (remainder to burn). ──
        uint256 toRewards = accrued * 5000 / 10_000;
        uint256 toBounty = accrued * 2500 / 10_000;
        uint256 toBurn = accrued - toRewards - toBounty;
        vm.prank(keeper); // anyone
        hook.flush();
        assertEq(hook.pendingFees(), 0);
        assertEq(address(distributor).balance, toRewards, "rewards slice exact");
        assertEq(address(bounty).balance, toBounty, "bounty slice exact");
        assertEq(address(burnEngine).balance, toBurn, "burn slice exact");
        assertEq(toRewards + toBounty + toBurn, accrued, "slices sum to 100% of the skim");

        // ── Equal per-NFT accrual across all 10,000 alive words. ──
        uint256 perNft = toRewards / MAX_NFT_SUPPLY;
        assertEq(distributor.pendingRewards(aliceId), perNft, "1/totalAlive share each");

        // ── Rewards travel with the NFT: transfer with pending, buyer claims. ──
        vm.prank(alice);
        bank.transferFrom(alice, carol, aliceId);
        assertEq(distributor.pendingRewards(aliceId), perNft, "transfer must not touch reward state");

        uint256 carolBefore = carol.balance;
        uint256[] memory ids = new uint256[](1);
        ids[0] = aliceId;
        vm.prank(alice);
        vm.expectRevert(); // the seller can no longer claim
        distributor.claimRewards(ids);
        vm.prank(carol);
        distributor.claimRewards(ids);
        assertEq(carol.balance - carolBefore, perNft, "buyer collects the full pending");
        assertEq(distributor.pendingRewards(aliceId), 0);

        // ── Unbind force-settles, then the survivors' rate rises. ──
        // Round 2: an identically sized swap (skim is exact-in on the ETH side, so the fee
        // is exactly 0.1 ETH again) with all 10,000 alive — the pre-burn rate baseline.
        uint256 bobId = _firstOwnedToken(bob);
        _buyExactIn(bob, 10 ether);
        hook.flush();
        uint256 rate2 = distributor.pendingRewards(aliceId); // carol claimed to zero above
        uint256 pendingAtBurn = distributor.pendingRewards(bobId);
        assertGt(pendingAtBurn, 0);

        uint256 bobEthBefore = bob.balance;
        uint256 bobWordBefore = token.balanceOf(bob);
        vm.prank(bob);
        bank.unbind(bobId);
        // Same transaction: pending rewards settled to the burner + 1,000 WORD released.
        assertEq(bob.balance - bobEthBefore, pendingAtBurn, "force-settle pays exactly pending");
        assertEq(token.balanceOf(bob) - bobWordBefore, BACKING, "backing released");
        assertEq(bank.totalAlive(), MAX_NFT_SUPPLY - 1);

        // Round 3: the same swap again, now split among 9,999 — the rate strictly rises.
        _buyExactIn(bob, 10 ether);
        hook.flush();
        uint256 rate3 = distributor.pendingRewards(aliceId) - rate2;
        assertGt(rate3, rate2, "survivor rate rises after a burn");
        // And the burned token accrues nothing ever again.
        assertEq(distributor.pendingRewards(bobId), 0);
    }
}

/// @title  Edge sweep: totalAlive → 1 → 0 (own contract: the hook's deployCodeTo address is
///         deterministic, so a mid-test redeploy would inherit stale storage — each fixture
///         variant needs its own setUp).
contract TradeAndEarnZeroAliveTest is IntegrationBase {
    function setUp() public {
        _deployProtocol();
        _mintOutCollectionTo(alice);
        _syncRegistry();
        _seedPool();
        _seal();
        _enableTrading();
        _expireGuard();
    }

    /// @dev Charter edge sweep: drive totalAlive to 1, then 0. The last word earns 100% of
    ///      the stream; at zero alive the permissionless fee path defers instead of bricking.
    function test_edge_lastNftUnbound_zeroAliveDefers() public {
        // Unbind 9,999 of the 10,000 in batches.
        uint256[] memory batch = new uint256[](500);
        uint256 next = 1;
        for (uint256 b = 0; b < 20; ++b) {
            uint256 n = b == 19 ? 499 : 500;
            uint256 k;
            while (k < n) {
                if (bank.isAlive(next)) batch[k++] = next;
                ++next;
            }
            uint256[] memory ids = new uint256[](n);
            for (uint256 i = 0; i < n; ++i) {
                ids[i] = batch[i];
            }
            vm.prank(alice);
            bank.unbindMany(ids);
        }
        assertEq(bank.totalAlive(), 1, "one survivor");
        uint256 survivor = 10_000; // ids unbound in order: the last id survives
        assertTrue(bank.isAlive(survivor));

        // The survivor takes 100% of the next rewards slice.
        _buyExactIn(bob, 10 ether);
        hook.flush();
        uint256 rewardsSlice = address(distributor).balance;
        assertEq(distributor.pendingRewards(survivor), rewardsSlice, "last word earns the whole stream");

        // Unbind the last word: settle pays out everything; collection is terminally empty.
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        bank.unbind(survivor);
        assertEq(alice.balance - aliceBefore, rewardsSlice);
        assertEq(bank.totalAlive(), 0);
        assertEq(token.balanceOf(address(bank)), 0, "all backing released");

        // Zero-alive: the fee pipeline must keep flowing — deposits defer, flush succeeds.
        _buyExactIn(bob, 4 ether);
        vm.prank(keeper);
        hook.flush(); // would brick here if deposit() reverted at zero alive (SPEC-2)
        assertGt(distributor.pendingUndistributed(), 0, "zero-alive deposit deferred, not reverted");
    }
}
