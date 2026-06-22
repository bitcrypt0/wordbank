// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WordStaking} from "../../src/WordStaking.sol";
import {WordTokenV2} from "../../src/WordTokenV2.sol";

/// @notice Unit suite for WordStaking — stake WORD, earn ETH from the fee, accumulator math,
///         deferral when nothing is staked, and dust-free precision.
contract WordStakingTest is Test {
    WordTokenV2 token;
    WordStaking staking;

    address treasury = makeAddr("treasury"); // holds the full supply at deploy
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper"); // permissionless depositor

    function setUp() public {
        token = new WordTokenV2(treasury);
        staking = new WordStaking(address(token));

        // Seed alice/bob with WORD and pre-approve the staking contract.
        vm.startPrank(treasury);
        token.transfer(alice, 100_000e18);
        token.transfer(bob, 300_000e18);
        vm.stopPrank();
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);

        vm.deal(keeper, 100 ether);
    }

    function _stake(address who, uint256 amt) internal {
        vm.prank(who);
        staking.stake(amt);
    }

    function _deposit(uint256 amt) internal {
        vm.prank(keeper);
        staking.deposit{value: amt}();
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(WordStaking.ZeroAddress.selector);
        new WordStaking(address(0));
    }

    function test_stakePullsTokensAndTracks() public {
        _stake(alice, 100_000e18);
        assertEq(staking.stakedOf(alice), 100_000e18);
        assertEq(staking.totalStaked(), 100_000e18);
        assertEq(token.balanceOf(address(staking)), 100_000e18);
    }

    function test_singleStakerGetsWholeDeposit() public {
        _stake(alice, 100_000e18);
        _deposit(1 ether);
        assertEq(staking.pendingRewards(alice), 1 ether);
    }

    function test_proRataSplitAcrossStakers() public {
        _stake(alice, 100_000e18); // 25%
        _stake(bob, 300_000e18); //   75%
        _deposit(4 ether);
        assertEq(staking.pendingRewards(alice), 1 ether);
        assertEq(staking.pendingRewards(bob), 3 ether);
    }

    function test_claimPaysEthAndZeroesPending() public {
        _stake(alice, 100_000e18);
        _deposit(1 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        staking.claim();
        assertEq(alice.balance - before, 1 ether);
        assertEq(staking.pendingRewards(alice), 0);
    }

    function test_lateStakerEarnsNothingFromEarlierDeposit() public {
        _stake(alice, 100_000e18);
        _deposit(1 ether); // only alice staked
        _stake(bob, 100_000e18); // joins after
        assertEq(staking.pendingRewards(alice), 1 ether);
        assertEq(staking.pendingRewards(bob), 0);

        _deposit(2 ether); // now split 50/50
        assertEq(staking.pendingRewards(alice), 1 ether + 1 ether);
        assertEq(staking.pendingRewards(bob), 1 ether);
    }

    function test_unstakeSettlesAndReturnsTokens() public {
        _stake(alice, 100_000e18);
        _deposit(1 ether);
        vm.prank(alice);
        staking.unstake(40_000e18);
        // Pending preserved across the unstake; tokens returned.
        assertEq(staking.pendingRewards(alice), 1 ether);
        assertEq(staking.stakedOf(alice), 60_000e18);
        assertEq(token.balanceOf(alice), 40_000e18);

        // Future deposits accrue only on the remaining stake. With a 120k denominator the
        // per-share value floors, so the split is exact to within accumulator dust (the
        // remainder is carried in pendingUndistributed — see test_precision).
        _stake(bob, 60_000e18); // now alice 60k, bob 60k → 50/50
        _deposit(2 ether);
        assertApproxEqAbs(staking.pendingRewards(alice), 1 ether + 1 ether, 1e5);
        assertApproxEqAbs(staking.pendingRewards(bob), 1 ether, 1e5);
    }

    function test_depositWhileNothingStakedDefersThenFolds() public {
        _deposit(1 ether); // nobody staked → deferred
        assertEq(staking.pendingUndistributed(), 1 ether);
        assertEq(staking.accRewardPerShare(), 0);

        _stake(alice, 100_000e18);
        // A zero-value kick distributes the buffer to the now-present staker.
        vm.prank(keeper);
        staking.deposit{value: 0}();
        assertEq(staking.pendingUndistributed(), 0);
        assertEq(staking.pendingRewards(alice), 1 ether);
    }

    function test_reverts() public {
        vm.prank(alice);
        vm.expectRevert(WordStaking.ZeroAmount.selector);
        staking.stake(0);

        _stake(alice, 100_000e18);
        vm.prank(alice);
        vm.expectRevert(WordStaking.InsufficientStake.selector);
        staking.unstake(100_001e18);

        // deposit with no value and no buffer.
        vm.prank(keeper);
        vm.expectRevert(WordStaking.ZeroDeposit.selector);
        staking.deposit{value: 0}();
    }

    /// @dev Precision: many tiny deposits eventually pay out in full (sub-wei remainder is
    ///      retained on the deposit side via pendingUndistributed and on the user side via
    ///      accruedScaled), and the contract never strands more than dust.
    function test_precision_noMeaningfulStranding() public {
        _stake(alice, 100_000e18);
        _stake(bob, 300_000e18);
        uint256 total;
        for (uint256 i = 0; i < 50; i++) {
            _deposit(0.013371337 ether);
            total += 0.013371337 ether;
        }
        uint256 aPending = staking.pendingRewards(alice);
        uint256 bPending = staking.pendingRewards(bob);
        uint256 buffer = staking.pendingUndistributed();
        // Everything deposited is accounted for: pending(alice)+pending(bob)+carry == total,
        // within at most a couple wei of accumulator flooring.
        assertApproxEqAbs(aPending + bPending + buffer, total, 3);
        // Contract holds exactly what it owes + the carry (no leak).
        assertEq(address(staking).balance, total);
    }

    function test_sweepRecoversForceSentEthToStakers() public {
        _stake(alice, 100_000e18);
        // Force ETH in via selfdestruct, bypassing deposit() (no receive() exists).
        new ForceSend{value: 1 ether}(payable(address(staking)));
        assertEq(address(staking).balance, 1 ether);
        assertEq(staking.pendingRewards(alice), 0, "not distributed until swept");

        staking.sweep(); // permissionless
        assertEq(staking.pendingUndistributed(), 1 ether, "folded into the buffer");

        // A zero-value kick distributes the recovered ETH to stakers.
        vm.prank(keeper);
        staking.deposit{value: 0}();
        assertEq(staking.pendingRewards(alice), 1 ether);
    }

    function test_sweepRevertsWithNoStrandedEth() public {
        _stake(alice, 100_000e18);
        _deposit(1 ether); // all accounted — nothing stranded
        vm.expectRevert(WordStaking.NoStrandedEth.selector);
        staking.sweep();
    }
}

/// @dev Force-sends its entire balance to `target` via selfdestruct (bypasses receive/deposit).
contract ForceSend {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}
