// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {LPLocker} from "../../src/LPLocker.sol";
import {MockPositionManager} from "../mocks/MockPositionManager.sol";

/// @notice Unit suite for the LPLocker. The PositionManager is a STRICT mock that decodes
///         and validates the locker's `modifyLiquidities` calldata (zero-liquidity decrease +
///         TAKE_PAIR only — see MockPositionManager for why the real implementation can't
///         compile against the repo's v4-core pin). Lock-state mechanics run against real
///         OZ ERC-721 transfer semantics.
contract LPLockerTest is Test {
    uint256 constant TOKEN_ID = 7;
    uint128 constant PRINCIPAL = 1_000e18;

    MockPositionManager posm;
    MockERC20 word;
    LPLocker locker;
    PoolKey key;
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");

    function setUp() public {
        posm = new MockPositionManager();
        word = new MockERC20("Word", "WORD", 18);

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(word)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        posm.mint(admin, TOKEN_ID, key, PRINCIPAL);

        locker = new LPLocker(IPositionManager(address(posm)), admin);
    }

    function _lock(uint256 until) internal {
        vm.startPrank(admin);
        posm.approve(address(locker), TOKEN_ID);
        locker.lock(TOKEN_ID, until);
        vm.stopPrank();
    }

    function _accrueFees(uint256 eth, uint256 tokens) internal {
        vm.deal(address(posm), address(posm).balance + eth);
        word.mint(address(posm), tokens);
        posm.setPendingFees(eth, tokens);
    }

    // ──────────────────────────────────── locking ──────────────────────────────────────

    function test_lock_pullsNftAndSetsTerms() public {
        uint256 until = block.timestamp + 365 days;
        vm.startPrank(admin);
        posm.approve(address(locker), TOKEN_ID);
        vm.expectEmit(true, false, false, true);
        emit LPLocker.PositionLocked(TOKEN_ID, until);
        locker.lock(TOKEN_ID, until);
        vm.stopPrank();

        assertEq(posm.ownerOf(TOKEN_ID), address(locker));
        assertTrue(locker.locked());
        assertEq(locker.tokenId(), TOKEN_ID);
        assertEq(locker.lockedUntil(), until);
    }

    function test_lock_rejectsShortLock() public {
        vm.startPrank(admin);
        posm.approve(address(locker), TOKEN_ID);
        vm.expectRevert(LPLocker.LockTooShort.selector);
        locker.lock(TOKEN_ID, block.timestamp + 365 days - 1);
        vm.stopPrank();
    }

    function test_lock_onlyAdmin_onlyOnce() public {
        vm.expectRevert();
        locker.lock(TOKEN_ID, block.timestamp + 365 days); // not admin

        _lock(block.timestamp + 365 days);
        vm.prank(admin);
        vm.expectRevert(LPLocker.AlreadyLocked.selector);
        locker.lock(TOKEN_ID, block.timestamp + 730 days);
    }

    // ─────────────────────────────────── withdrawal ────────────────────────────────────

    function test_withdraw_blockedUntilExpiry_thenReturnsToAdmin() public {
        uint256 until = block.timestamp + 365 days;
        _lock(until);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LPLocker.StillLocked.selector, until));
        locker.withdraw();

        vm.warp(until - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LPLocker.StillLocked.selector, until));
        locker.withdraw();

        vm.warp(until);
        vm.prank(admin);
        locker.withdraw();
        assertEq(posm.ownerOf(TOKEN_ID), admin, "position returned to admin at expiry");
        assertFalse(locker.locked());
    }

    function test_withdraw_onlyAdmin() public {
        _lock(block.timestamp + 365 days);
        vm.warp(block.timestamp + 366 days);
        vm.expectRevert();
        locker.withdraw();
    }

    function test_errorsWhenNothingLocked() public {
        vm.startPrank(admin);
        vm.expectRevert(LPLocker.NothingLocked.selector);
        locker.withdraw();
        vm.expectRevert(LPLocker.NothingLocked.selector);
        locker.extendLock(block.timestamp + 999 days);
        vm.expectRevert(LPLocker.NothingLocked.selector);
        locker.makePermanent();
        vm.expectRevert(LPLocker.NothingLocked.selector);
        locker.collectFees(admin);
        vm.stopPrank();
    }

    // ─────────────────────────────────── extension ─────────────────────────────────────

    function test_extendLock_monotonicOnly() public {
        uint256 until = block.timestamp + 365 days;
        _lock(until);

        vm.startPrank(admin);
        vm.expectRevert(LPLocker.LockNotExtended.selector);
        locker.extendLock(until); // equal is not an extension
        vm.expectRevert(LPLocker.LockNotExtended.selector);
        locker.extendLock(until - 1 days);

        vm.expectEmit(true, false, false, true);
        emit LPLocker.LockExtended(TOKEN_ID, until, until + 365 days);
        locker.extendLock(until + 365 days);
        assertEq(locker.lockedUntil(), until + 365 days);
        vm.stopPrank();

        // Withdrawal honors the extension.
        vm.warp(until);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LPLocker.StillLocked.selector, until + 365 days));
        locker.withdraw();
    }

    function testFuzz_extendLock_neverShortens(uint256 newUntil) public {
        uint256 until = block.timestamp + 365 days;
        _lock(until);
        newUntil = bound(newUntil, 0, until);
        vm.prank(admin);
        vm.expectRevert(LPLocker.LockNotExtended.selector);
        locker.extendLock(newUntil);
    }

    // ────────────────────────────────── permanence ─────────────────────────────────────

    function test_makePermanent_irreversible() public {
        _lock(block.timestamp + 365 days);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit LPLocker.LockMadePermanent(TOKEN_ID);
        locker.makePermanent();
        assertEq(locker.lockedUntil(), type(uint256).max);

        vm.startPrank(admin);
        vm.expectRevert(LPLocker.LockIsPermanent.selector);
        locker.makePermanent(); // not re-callable
        vm.expectRevert(LPLocker.LockIsPermanent.selector);
        locker.extendLock(type(uint256).max); // nothing extends past forever
        vm.stopPrank();
    }

    /// @dev Fuzz: under a permanent lock, withdrawal is impossible at ANY future time.
    function testFuzz_makePermanent_unwithdrawableForever(uint64 warpTo) public {
        _lock(block.timestamp + 365 days);
        vm.prank(admin);
        locker.makePermanent();

        vm.warp(block.timestamp + uint256(warpTo));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LPLocker.StillLocked.selector, type(uint256).max));
        locker.withdraw();
        assertEq(posm.ownerOf(TOKEN_ID), address(locker), "position never leaves");
    }

    // ───────────────────────────────── fee collection ──────────────────────────────────

    function test_collectFees_sendsFeesToRecipient_strictCalldata() public {
        _lock(block.timestamp + 365 days);
        _accrueFees(1 ether, 500e18);

        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit LPLocker.FeesCollected(TOKEN_ID, treasury);
        locker.collectFees(treasury);

        // The strict mock reverts on anything but a zero-liquidity decrease + TAKE_PAIR,
        // so reaching here proves the calldata shape; now prove the routing and principal.
        assertEq(treasury.balance, 1 ether, "ETH fees to recipient");
        assertEq(word.balanceOf(treasury), 500e18, "token fees to recipient");
        assertEq(posm.getPositionLiquidity(TOKEN_ID), PRINCIPAL, "principal liquidity untouched");
        assertEq(posm.ownerOf(TOKEN_ID), address(locker), "position stays locked");
        assertEq(posm.collectCalls(), 1);
    }

    function test_collectFees_worksDuringLockAfterExpiryAndWhenPermanent() public {
        _lock(block.timestamp + 365 days);

        _accrueFees(1 ether, 0);
        vm.prank(admin);
        locker.collectFees(treasury); // during lock

        vm.warp(block.timestamp + 400 days);
        _accrueFees(1 ether, 0);
        vm.prank(admin);
        locker.collectFees(treasury); // after expiry (not yet withdrawn)

        vm.prank(admin);
        locker.makePermanent();
        _accrueFees(1 ether, 0);
        vm.prank(admin);
        locker.collectFees(treasury); // under permanent lock
        assertEq(treasury.balance, 3 ether, "fee revenue continues forever");
    }

    function test_collectFees_onlyAdmin_andValidRecipient() public {
        _lock(block.timestamp + 365 days);
        vm.expectRevert();
        locker.collectFees(treasury); // not admin

        vm.prank(admin);
        vm.expectRevert(LPLocker.ZeroAddress.selector);
        locker.collectFees(address(0));
    }

    /// @dev Repeated collections never move principal — the only mutating surface the
    ///      locker exposes against the position is fee collection.
    function testFuzz_collectFees_principalInvariant(uint8 rounds) public {
        _lock(block.timestamp + 365 days);
        rounds = uint8(bound(rounds, 1, 10));
        for (uint256 i; i < rounds; i++) {
            _accrueFees(0.1 ether, 1e18);
            vm.prank(admin);
            locker.collectFees(treasury);
            assertEq(posm.getPositionLiquidity(TOKEN_ID), PRINCIPAL, "principal constant across collections");
        }
    }
}
