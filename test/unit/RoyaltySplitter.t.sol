// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {WETH} from "solmate/src/tokens/WETH.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RoyaltySplitter} from "../../src/RoyaltySplitter.sol";
import {MockEthSink} from "../mocks/MockEthSink.sol";

/// @dev Admin recipient that can be toggled to (a) revert on ETH receipt (griefing) and/or
///      (b) re-enter `distribute()` on receipt (reentrancy attack). Defaults to a plain
///      accepting receiver so it can stand in for a well-behaved admin too.
contract AdminRecipient {
    RoyaltySplitter public splitter;
    bool public blockEth;
    bool public reenter;
    uint256 public received;

    function wire(RoyaltySplitter s) external {
        splitter = s;
    }

    function setBlock(bool b) external {
        blockEth = b;
    }

    function setReenter(bool r) external {
        reenter = r;
    }

    receive() external payable {
        if (reenter) splitter.distribute(); // must be stopped by nonReentrant
        if (blockEth) revert("admin rejects ETH");
        received += msg.value;
    }
}

/// @notice Unit suite for the trustless RoyaltySplitter (agent 5). The two protocol sinks are
///         MockEthSink (records `received` — proves each `deposit()` lands with the right
///         value); WETH is solmate's canonical WETH; the admin is a togglable recipient used
///         to exercise the griefing + reentrancy paths. Real BurnEngine/BountyEngine
///         integration is Agent 6's.
contract RoyaltySplitterTest is Test {
    MockEthSink burnSink;
    MockEthSink bountySink;
    AdminRecipient admin;
    WETH weth;
    RoyaltySplitter splitter;

    function setUp() public {
        burnSink = new MockEthSink();
        bountySink = new MockEthSink();
        admin = new AdminRecipient();
        weth = new WETH();
        splitter = new RoyaltySplitter(address(burnSink), address(bountySink), address(admin), address(weth));
        admin.wire(splitter);
    }

    function _fundEth(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(splitter).call{value: amount}("");
        assertTrue(ok);
    }

    // ───────────────────────────────── construction ────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(address(splitter.burnEngine()), address(burnSink));
        assertEq(address(splitter.bountyEngine()), address(bountySink));
        assertEq(splitter.admin(), address(admin));
        assertEq(address(splitter.weth()), address(weth));
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(RoyaltySplitter.ZeroAddress.selector);
        new RoyaltySplitter(address(0), address(bountySink), address(admin), address(weth));
        vm.expectRevert(RoyaltySplitter.ZeroAddress.selector);
        new RoyaltySplitter(address(burnSink), address(0), address(admin), address(weth));
        vm.expectRevert(RoyaltySplitter.ZeroAddress.selector);
        new RoyaltySplitter(address(burnSink), address(bountySink), address(0), address(weth));
        vm.expectRevert(RoyaltySplitter.ZeroAddress.selector);
        new RoyaltySplitter(address(burnSink), address(bountySink), address(admin), address(0));
    }

    // ──────────────────────────────── receive (pull-based) ─────────────────────────────

    function test_receive_acceptsEthAndDoesNotSplit() public {
        _fundEth(3 ether);
        assertEq(address(splitter).balance, 3 ether, "ETH accrued, not split on receipt");
        assertEq(burnSink.received(), 0);
        assertEq(bountySink.received(), 0);
        assertEq(admin.received(), 0);
    }

    // ─────────────────────────────── equal-thirds split ────────────────────────────────

    function test_distribute_equalThirds_evenlyDivisible() public {
        _fundEth(9 ether);

        vm.expectEmit(true, false, false, true);
        emit RoyaltySplitter.Distributed(address(this), 3 ether, 3 ether, 3 ether);
        splitter.distribute();

        assertEq(burnSink.received(), 3 ether, "burn 1/3");
        assertEq(bountySink.received(), 3 ether, "bounty 1/3");
        assertEq(admin.received(), 3 ether, "admin 1/3");
        assertEq(address(splitter).balance, 0, "fully distributed");
    }

    /// @dev Remainder (1e18 not divisible by 3) lands on the admin slice; slices sum exactly.
    function test_distribute_remainderGoesToAdmin() public {
        _fundEth(1 ether);
        uint256 third = uint256(1 ether) / 3; // 333333333333333333
        uint256 adminSlice = uint256(1 ether) - third - third; // 333333333333333334

        splitter.distribute();

        assertEq(burnSink.received(), third);
        assertEq(bountySink.received(), third);
        assertEq(admin.received(), adminSlice);
        assertEq(third + third + adminSlice, 1 ether, "slices sum to exactly the balance");
        assertGt(adminSlice, third, "remainder wei landed on admin");
    }

    function test_distribute_tinyDust_threeWei() public {
        _fundEth(3); // 1/1/1
        splitter.distribute();
        assertEq(burnSink.received(), 1);
        assertEq(bountySink.received(), 1);
        assertEq(admin.received(), 1);
    }

    function test_distribute_revertsWhenNothing() public {
        vm.expectRevert(RoyaltySplitter.NothingToDistribute.selector);
        splitter.distribute();
    }

    function test_distribute_permissionless() public {
        _fundEth(9 ether);
        vm.prank(makeAddr("randomKeeper"));
        splitter.distribute();
        assertEq(burnSink.received(), 3 ether);
    }

    function test_pendingDistribution_view() public {
        _fundEth(6 ether);
        assertEq(splitter.pendingDistribution(), 6 ether);
    }

    // ────────────────────────────────── WETH unwrap ────────────────────────────────────

    function test_distribute_unwrapsWeth() public {
        // Give the splitter 9 WETH (a WETH-denominated royalty).
        vm.deal(address(this), 9 ether);
        weth.deposit{value: 9 ether}();
        weth.transfer(address(splitter), 9 ether);
        assertEq(weth.balanceOf(address(splitter)), 9 ether);
        assertEq(address(splitter).balance, 0);

        splitter.distribute();

        assertEq(weth.balanceOf(address(splitter)), 0, "WETH unwrapped");
        assertEq(burnSink.received(), 3 ether);
        assertEq(bountySink.received(), 3 ether);
        assertEq(admin.received(), 3 ether);
    }

    function test_distribute_mixedEthAndWeth() public {
        _fundEth(3 ether); // native
        vm.deal(address(this), 6 ether);
        weth.deposit{value: 6 ether}();
        weth.transfer(address(splitter), 6 ether); // WETH
        // Total distributable after unwrap = 9 ETH.
        splitter.distribute();
        assertEq(burnSink.received(), 3 ether);
        assertEq(bountySink.received(), 3 ether);
        assertEq(admin.received(), 3 ether);
    }

    // ─────────────────────────── griefing / reentrancy (admin) ─────────────────────────

    /// @dev A griefing admin that reverts on ETH receipt must NOT block the two protocol
    ///      sinks; its slice accrues to pendingAdmin for a later pull.
    function test_distribute_grieferAdmin_sinksPaid_sliceAccrues() public {
        admin.setBlock(true);
        _fundEth(9 ether);

        vm.expectEmit(false, false, false, true);
        emit RoyaltySplitter.AdminSlicePending(3 ether, 3 ether);
        splitter.distribute();

        assertEq(burnSink.received(), 3 ether, "burn paid despite griefing admin");
        assertEq(bountySink.received(), 3 ether, "bounty paid despite griefing admin");
        assertEq(splitter.pendingAdmin(), 3 ether, "admin slice held for pull");
        assertEq(admin.received(), 0);
    }

    /// @dev A stuck admin slice is excluded from the next distribution (never re-split into
    ///      the protocol sinks — no double-count, no leak).
    function test_distribute_pendingAdminExcludedFromNextSplit() public {
        admin.setBlock(true);
        _fundEth(9 ether);
        splitter.distribute(); // pendingAdmin = 3 ether, 3 ether stuck in contract

        _fundEth(9 ether); // new royalties; balance now 12 ETH (9 new + 3 stuck)
        splitter.distribute(); // must split only the new 9, not the stuck 3

        assertEq(burnSink.received(), 6 ether, "second round split only the new 9 ETH");
        assertEq(bountySink.received(), 6 ether);
        assertEq(splitter.pendingAdmin(), 6 ether, "two stuck admin slices accrued");
        assertEq(address(splitter).balance, 6 ether, "exactly the two stuck slices remain");
    }

    /// @dev A reentrant admin (re-enters distribute() on receipt) is stopped by nonReentrant;
    ///      the reentry reverts, the outer admin send fails, the slice accrues — and the two
    ///      protocol sinks are still paid exactly once.
    function test_distribute_reentrantAdmin_blockedByGuard() public {
        admin.setReenter(true);
        _fundEth(9 ether);

        splitter.distribute();

        assertEq(burnSink.received(), 3 ether, "burn paid exactly once");
        assertEq(bountySink.received(), 3 ether, "bounty paid exactly once");
        assertEq(splitter.pendingAdmin(), 3 ether, "reentrant admin slice accrued, not double-paid");
    }

    /// @dev Once the admin can receive again, withdrawAdmin() pays out the held slice.
    function test_withdrawAdmin_recoversPendingSlice() public {
        admin.setBlock(true);
        _fundEth(9 ether);
        splitter.distribute();
        assertEq(splitter.pendingAdmin(), 3 ether);

        // While still blocking, withdraw reverts (retryable).
        vm.expectRevert(RoyaltySplitter.EthTransferFailed.selector);
        splitter.withdrawAdmin();

        // Admin recovers; withdraw succeeds.
        admin.setBlock(false);
        vm.expectEmit(false, false, false, true);
        emit RoyaltySplitter.AdminWithdrawn(3 ether);
        splitter.withdrawAdmin();

        assertEq(admin.received(), 3 ether, "admin paid on retry");
        assertEq(splitter.pendingAdmin(), 0);
        assertEq(address(splitter).balance, 0, "nothing stranded");
    }

    function test_withdrawAdmin_revertsWhenNothingPending() public {
        vm.expectRevert(RoyaltySplitter.NothingPending.selector);
        splitter.withdrawAdmin();
    }

    // ───────────────────────────────────── rescue ──────────────────────────────────────

    function test_rescueToken_adminOnly_transfersToAdmin() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(address(splitter), 1_000e6);

        // Non-admin cannot rescue.
        vm.expectRevert(RoyaltySplitter.NotAdmin.selector);
        splitter.rescueToken(IERC20(address(usdc)));

        vm.prank(address(admin));
        vm.expectEmit(true, false, false, true);
        emit RoyaltySplitter.TokenRescued(address(usdc), 1_000e6);
        splitter.rescueToken(IERC20(address(usdc)));

        assertEq(usdc.balanceOf(address(admin)), 1_000e6, "rescued to admin");
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    /// @dev WETH may NOT be rescued — that would let the admin bypass the trustless WETH split.
    function test_rescueToken_cannotRescueWeth() public {
        vm.deal(address(this), 1 ether);
        weth.deposit{value: 1 ether}();
        weth.transfer(address(splitter), 1 ether);

        vm.prank(address(admin));
        vm.expectRevert(RoyaltySplitter.CannotRescueWeth.selector);
        splitter.rescueToken(IERC20(address(weth)));

        // It still splits trustlessly via distribute().
        splitter.distribute();
        assertEq(weth.balanceOf(address(splitter)), 0);
        assertGt(burnSink.received(), 0);
    }
}
