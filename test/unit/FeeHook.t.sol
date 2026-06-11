// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {BountyEngine} from "../../src/BountyEngine.sol";
import {BurnEngine} from "../../src/BurnEngine.sol";
import {FeeHook} from "../../src/FeeHook.sol";
import {RewardsDistributor} from "../../src/RewardsDistributor.sol";
import {WordToken} from "../../src/WordToken.sol";
import {IBountyEngine} from "../../src/interfaces/IBountyEngine.sol";
import {IBurnEngine} from "../../src/interfaces/IBurnEngine.sol";
import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";
import {IWordToken} from "../../src/interfaces/IWordToken.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {MockBurnSink} from "../mocks/MockBurnSink.sol";
import {MockEthSink} from "../mocks/MockEthSink.sol";
import {MockReenteringSink} from "../mocks/MockReenteringSink.sol";
import {MockWordBank} from "../mocks/MockWordBank.sol";
import {MockWordToken} from "../mocks/MockWordToken.sol";

/// @notice Unit suite for the FeeHook against a real local V4 PoolManager (v4-core test
///         utilities). Pool: native ETH (currency0) / WORD (currency1) — native ETH is
///         address(0) and always sorts first, so "both token orderings" is a non-case for
///         the canonical pool by construction (asserted in test_poolOrdering).
contract FeeHookTest is Test, Deployers {
    uint256 constant FEE_BPS = 100; // launch fee, 1%
    uint256 constant BPS = 10_000;
    int24 constant TICK_SPACING = 60;
    uint24 constant LP_FEE = 3000;

    // beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta
    uint160 constant HOOK_FLAGS = uint160((1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    MockWordToken word;
    FeeHook hook;
    MockEthSink rewards;
    MockEthSink bounty;
    MockBurnSink burnSink;
    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");

    function setUp() public {
        deployFreshManagerAndRouters();

        word = new MockWordToken();
        // Default: burnable excess present → the hook routes three-way (50/25/25). Tests that
        // need the no-excess two-way mode set word.setBurnableExcess(0).
        word.setBurnableExcess(1_000_000e18);
        rewards = new MockEthSink();
        bounty = new MockEthSink();
        burnSink = new MockBurnSink();

        address hookAddr = address(uint160((0x4444 << 144)) | HOOK_FLAGS);
        deployCodeTo(
            "FeeHook.sol:FeeHook",
            abi.encode(
                manager,
                address(word),
                LP_FEE,
                TICK_SPACING,
                address(rewards),
                address(bounty),
                address(burnSink),
                admin
            ),
            hookAddr
        );
        hook = FeeHook(payable(hookAddr));

        (key,) = initPool(
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(word)),
            IHooks(hookAddr),
            LP_FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );

        // Deep full-range liquidity so 10k-WORD buys have low impact: ~2M ETH + ~2M WORD.
        word.mint(address(this), 5_000_000e18);
        word.approve(address(modifyLiquidityRouter), type(uint256).max);
        word.approve(address(swapRouter), type(uint256).max);
        vm.deal(address(this), 5_000_000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 2_100_000 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 2_000_000e18, salt: 0
            }),
            ZERO_BYTES
        );
    }

    function _enableTrading() internal {
        vm.prank(admin);
        hook.enableTrading();
    }

    /// @dev Buys WORD with exact ETH input via the native-input helper.
    function _buyExactIn(uint256 ethIn) internal returns (BalanceDelta) {
        return swapNativeInput(key, true, -int256(ethIn), ZERO_BYTES, ethIn);
    }

    /// @dev Buys an exact WORD output; over-funds the router and ignores the excess.
    function _buyExactOut(uint256 wordOut, uint256 maxEth) internal returns (BalanceDelta) {
        return swapRouter.swap{value: maxEth}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: int256(wordOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    // ─────────────────────────────── address & wiring ──────────────────────────────────

    function test_poolOrdering_ethIsAlwaysCurrency0() public view {
        assertTrue(key.currency0.isAddressZero(), "ETH must be currency0");
        assertEq(Currency.unwrap(key.currency1), address(word));
    }

    function test_hookAddressEncodesExactlyTheFourFlags() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
        assertTrue(Hooks.isValidHookAddress(IHooks(address(hook)), LP_FEE));
    }

    /// @dev End-to-end mining check: HookMiner finds a salt for THIS deployer, an actual
    ///      CREATE2 deployment with that salt lands on the mined address, and the hook's
    ///      constructor flag validation passes there.
    function test_hookMiner_minedSaltDeploysAtPredictedAddress() public {
        bytes memory args = abi.encode(
            manager, address(word), LP_FEE, TICK_SPACING, address(rewards), address(bounty), address(burnSink), admin
        );
        (address mined, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, type(FeeHook).creationCode, args);

        FeeHook deployed = new FeeHook{salt: salt}(
            manager,
            address(word),
            LP_FEE,
            TICK_SPACING,
            rewardsDistributorOf(),
            bountyEngineOf(),
            burnEngineOf(),
            admin
        );
        assertEq(address(deployed), mined, "CREATE2 address matches the mined prediction");
        assertEq(uint160(address(deployed)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "mined address encodes the flags");
    }

    function rewardsDistributorOf() internal view returns (IRewardsDistributor) {
        return IRewardsDistributor(address(rewards));
    }

    function bountyEngineOf() internal view returns (IBountyEngine) {
        return IBountyEngine(address(bounty));
    }

    function burnEngineOf() internal view returns (IBurnEngine) {
        return IBurnEngine(address(burnSink));
    }

    function test_constructorRevertsAtWrongFlagAddress() public {
        // Same args, address with an extra flag bit set — constructor must reject.
        address bad = address(uint160(0x5555 << 144) | HOOK_FLAGS | uint160(1 << 5));
        vm.expectRevert(); // HookAddressNotValid
        deployCodeTo(
            "FeeHook.sol:FeeHook",
            abi.encode(
                manager,
                address(word),
                LP_FEE,
                TICK_SPACING,
                address(rewards),
                address(bounty),
                address(burnSink),
                admin
            ),
            bad
        );
    }

    // ─────────────────────────────────── trading gate ──────────────────────────────────

    function test_swapsRevertBeforeEnableTrading() public {
        vm.expectRevert();
        _buyExactIn(1 ether);
    }

    function test_beforeSwapDirect_revertsTradingNotEnabled() public {
        vm.prank(address(manager));
        vm.expectRevert(FeeHook.TradingNotEnabled.selector);
        hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ZERO_BYTES
        );
    }

    function test_enableTrading_onlyAdmin_onlyOnce() public {
        vm.expectRevert();
        hook.enableTrading(); // not admin

        vm.expectEmit(false, false, false, true);
        emit FeeHook.TradingEnabled(block.timestamp);
        _enableTrading();
        assertEq(hook.tradingEnabledAt(), uint64(block.timestamp));

        vm.prank(admin);
        vm.expectRevert(FeeHook.TradingAlreadyEnabled.selector);
        hook.enableTrading();
    }

    function test_swapsWorkAfterEnable() public {
        _enableTrading();
        BalanceDelta delta = _buyExactIn(1 ether);
        assertGt(delta.amount1(), 0, "received WORD");
    }

    function test_onlyCanonicalPoolServed() public {
        _enableTrading();
        // A second pool (different LP fee) attached to the same hook must be unusable.
        (PoolKey memory otherKey,) = initPool(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(word)), IHooks(address(hook)), 500, 10, SQRT_PRICE_1_1
        );
        vm.expectRevert();
        swapRouter.swap{value: 1 ether}(
            otherKey,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    // ─────────────────────────────── skim exactness ────────────────────────────────────

    /// @dev Exact-input buy: ETH is specified; fee = |amountSpecified| × feeBps / 10000,
    ///      taken in beforeSwap. The user's total ETH outflow is exactly amountSpecified.
    function test_skim_buyExactIn() public {
        _enableTrading();
        uint256 ethIn = 1 ether;
        uint256 expectedFee = ethIn * FEE_BPS / BPS;

        BalanceDelta delta = _buyExactIn(ethIn);

        assertEq(address(hook).balance, expectedFee, "skim exact");
        assertEq(uint256(uint128(-delta.amount0())), ethIn, "user pays exactly ethIn");
        assertGt(delta.amount1(), 0);
    }

    /// @dev Exact-output buy: ETH is unspecified; fee = pool ETH input × feeBps / 10000,
    ///      taken in afterSwap and charged on top to the swapper.
    function test_skim_buyExactOut() public {
        _enableTrading();
        uint256 wordOut = 1_000e18;

        BalanceDelta delta = _buyExactOut(wordOut, 1_100 ether);

        uint256 fee = address(hook).balance;
        uint256 totalEthPaid = uint256(uint128(-delta.amount0()));
        uint256 poolEthIn = totalEthPaid - fee;
        assertEq(fee, poolEthIn * FEE_BPS / BPS, "fee exact on pool ETH input");
        assertEq(uint256(uint128(delta.amount1())), wordOut, "exact output delivered");
    }

    /// @dev Exact-input sell: ETH is unspecified; fee = pool ETH output × feeBps / 10000,
    ///      taken in afterSwap out of the user's proceeds.
    function test_skim_sellExactIn() public {
        _enableTrading();
        uint256 wordIn = 1_000e18;

        BalanceDelta delta = swap(key, false, -int256(wordIn), ZERO_BYTES);

        uint256 fee = address(hook).balance;
        uint256 userEthOut = uint256(uint128(delta.amount0()));
        uint256 poolEthOut = userEthOut + fee;
        assertEq(fee, poolEthOut * FEE_BPS / BPS, "fee exact on pool ETH output");
    }

    /// @dev Exact-output sell: ETH is specified; fee = |amountSpecified| × feeBps / 10000,
    ///      taken in beforeSwap; the user still receives exactly the requested ETH.
    function test_skim_sellExactOut() public {
        _enableTrading();
        uint256 ethOut = 1 ether;
        uint256 expectedFee = ethOut * FEE_BPS / BPS;

        BalanceDelta delta = swap(key, false, int256(ethOut), ZERO_BYTES);

        assertEq(address(hook).balance, expectedFee, "skim exact");
        assertEq(uint256(uint128(delta.amount0())), ethOut, "user receives exactly ethOut");
    }

    function test_skim_accruesAcrossSwaps_pendingFeesView() public {
        _enableTrading();
        _buyExactIn(1 ether);
        _buyExactIn(2 ether);
        swap(key, false, int256(1 ether), ZERO_BYTES);
        assertEq(hook.pendingFees(), (1 ether + 2 ether + 1 ether) * FEE_BPS / BPS);
        assertEq(hook.pendingFees(), address(hook).balance);
    }

    function test_skim_atMaxFeeBps() public {
        vm.prank(admin);
        hook.setFeeBps(200);
        _enableTrading();
        _buyExactIn(1 ether);
        assertEq(address(hook).balance, 1 ether * 200 / BPS);
    }

    // ─────────────────────────────── anti-whale guard ──────────────────────────────────

    function test_guard_buyExactlyAtCapPasses() public {
        _enableTrading();
        assertTrue(hook.guardActive());
        BalanceDelta delta = _buyExactOut(10_000e18, 11_000 ether);
        assertEq(uint256(uint128(delta.amount1())), 10_000e18);
    }

    function test_guard_buyOneWeiOverCapReverts() public {
        _enableTrading();
        vm.expectRevert();
        _buyExactOut(10_000e18 + 1, 11_000 ether);
    }

    function test_guard_bigExactInBuyReverts() public {
        _enableTrading();
        vm.expectRevert();
        _buyExactIn(11_000 ether); // would output > 10,000 WORD on a ~1:1 pool
    }

    function test_guard_sellsUnaffected() public {
        _enableTrading();
        BalanceDelta delta = swap(key, false, -int256(50_000e18), ZERO_BYTES);
        assertGt(delta.amount0(), 0, "large sell passes during guard");
    }

    function test_guard_afterSwapDirect_boundaryAndExemption() public {
        _enableTrading();
        IPoolManager.SwapParams memory buyParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: int256(1), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        // Exactly at cap: passes (zero ETH delta so no take is attempted).
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, buyParams, toBalanceDelta(0, int128(uint128(10_000e18))), ZERO_BYTES);

        // One wei over: reverts.
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(FeeHook.BuyExceedsLaunchCap.selector, 10_000e18 + 1));
        hook.afterSwap(address(this), key, buyParams, toBalanceDelta(0, int128(uint128(10_000e18 + 1))), ZERO_BYTES);

        // Same over-cap buy from the BurnEngine (the wired burn sink): exempt, passes.
        vm.prank(address(manager));
        hook.afterSwap(address(burnSink), key, buyParams, toBalanceDelta(0, int128(uint128(10_000e18 + 1))), ZERO_BYTES);
    }

    function test_guard_adminSunset() public {
        _enableTrading();
        assertTrue(hook.guardActive());

        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit FeeHook.GuardSunset(block.timestamp);
        hook.sunsetGuard();

        assertFalse(hook.guardActive());
        BalanceDelta delta = _buyExactOut(50_000e18, 60_000 ether);
        assertEq(uint256(uint128(delta.amount1())), 50_000e18, "cap dead after sunset");

        // Not re-enableable / not re-callable.
        vm.prank(admin);
        vm.expectRevert(FeeHook.GuardAlreadySunset.selector);
        hook.sunsetGuard();
        assertFalse(hook.guardActive());
    }

    function test_guard_autoExpiryAfterOneHour() public {
        _enableTrading();
        assertTrue(hook.guardActive());

        vm.warp(block.timestamp + 1 hours - 1);
        assertTrue(hook.guardActive(), "still active 1s before expiry");

        vm.warp(block.timestamp + 1);
        assertFalse(hook.guardActive(), "dead exactly at +1 hour");

        BalanceDelta delta = _buyExactOut(50_000e18, 60_000 ether);
        assertEq(uint256(uint128(delta.amount1())), 50_000e18, "cap dead after auto-expiry");
    }

    function test_guard_sunsetRequiresTradingEnabled_andIsAdminOnly() public {
        vm.prank(admin);
        vm.expectRevert(FeeHook.TradingNotEnabled.selector);
        hook.sunsetGuard();

        _enableTrading();
        vm.expectRevert();
        hook.sunsetGuard(); // not admin
    }

    // ─────────────────────────────────── param bounds ──────────────────────────────────

    function test_setFeeBps_bounds() public {
        vm.startPrank(admin);
        vm.expectRevert(FeeHook.FeeOutOfBounds.selector);
        hook.setFeeBps(0);
        vm.expectRevert(FeeHook.FeeOutOfBounds.selector);
        hook.setFeeBps(201);
        hook.setFeeBps(200);
        assertEq(hook.feeBps(), 200);
        vm.stopPrank();

        vm.expectRevert();
        hook.setFeeBps(150); // not admin
    }

    function test_setBurnPhaseSplit_boundsAndSum() public {
        vm.startPrank(admin);
        // Out-of-bound shares.
        vm.expectRevert(FeeHook.SplitOutOfBounds.selector);
        hook.setBurnPhaseSplit(3900, 3000, 3100); // rewards < 4000
        vm.expectRevert(FeeHook.SplitOutOfBounds.selector);
        hook.setBurnPhaseSplit(6100, 1900, 2000); // rewards > 6000
        vm.expectRevert(FeeHook.SplitOutOfBounds.selector);
        hook.setBurnPhaseSplit(5000, 1400, 3600); // bounty < 1500, burn > 3500
        // Sum != 100%.
        vm.expectRevert(FeeHook.SplitOutOfBounds.selector);
        hook.setBurnPhaseSplit(5000, 2500, 2400);
        // Valid edges.
        hook.setBurnPhaseSplit(6000, 2000, 2000);
        hook.setBurnPhaseSplit(4000, 3500, 2500);
        assertEq(hook.rewardsBps(), 4000);
        assertEq(hook.bountyBps(), 3500);
        assertEq(hook.burnBps(), 2500);
        vm.stopPrank();
    }

    /// @dev Both split configs are permanently live now (no mode latch): setPostBurnSplit
    ///      works at any time, bounds enforced (rewards 5000–8000, bounty 2000–5000, sum 100%).
    function test_setPostBurnSplit_boundsAndSum() public {
        vm.startPrank(admin);
        vm.expectRevert(FeeHook.SplitOutOfBounds.selector);
        hook.setPostBurnSplit(8100, 1900); // rewards > 8000
        vm.expectRevert(FeeHook.SplitOutOfBounds.selector);
        hook.setPostBurnSplit(4900, 5100); // rewards < 5000
        vm.expectRevert(FeeHook.SplitOutOfBounds.selector);
        hook.setPostBurnSplit(7000, 2900); // sum != 100%
        // Valid edges.
        hook.setPostBurnSplit(8000, 2000);
        assertEq(hook.postRewardsBps(), 8000);
        assertEq(hook.postBountyBps(), 2000);
        hook.setPostBurnSplit(5000, 5000);
        assertEq(hook.postRewardsBps(), 5000);
        assertEq(hook.postBountyBps(), 5000);
        vm.stopPrank();

        vm.expectRevert();
        hook.setPostBurnSplit(7000, 3000); // not admin
    }

    // ──────────────────────────────────── routing ──────────────────────────────────────

    function test_flush_exactThreeWaySplit_byArbitraryCaller() public {
        _enableTrading();
        _buyExactIn(100 ether);
        uint256 accrued = address(hook).balance;
        assertEq(accrued, 1 ether);

        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit FeeHook.Flushed(
            keeper, accrued * 5000 / BPS, accrued * 2500 / BPS, accrued - accrued * 5000 / BPS - accrued * 2500 / BPS
        );
        hook.flush();

        assertEq(rewards.received(), accrued * 5000 / BPS);
        assertEq(bounty.received(), accrued * 2500 / BPS);
        assertEq(burnSink.received(), accrued - rewards.received() - bounty.received());
        assertEq(rewards.received() + bounty.received() + burnSink.received(), accrued, "slices sum to 100%");
        assertEq(address(hook).balance, 0, "hook drained");
    }

    function test_flush_oddWeiRemainderGoesToBurn() public {
        // 10,001 wei at 50/25/25: 5000 + 2500 + 2501.
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 10_001}("");
        assertTrue(ok);
        hook.flush();
        assertEq(rewards.received(), 5000);
        assertEq(bounty.received(), 2500);
        assertEq(burnSink.received(), 2501);
    }

    function test_flush_zeroBalanceIsQuietNoop() public {
        hook.flush();
        assertEq(rewards.received(), 0);
    }

    function test_flush_respectsConfiguredSplit() public {
        vm.prank(admin);
        hook.setBurnPhaseSplit(6000, 1500, 2500);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertTrue(ok);
        hook.flush();
        assertEq(rewards.received(), 0.6 ether);
        assertEq(bounty.received(), 0.15 ether);
        assertEq(burnSink.received(), 0.25 ether);
    }

    function test_flush_reentrancyLocked() public {
        // Wire a second hook whose rewards sink re-enters flush().
        MockReenteringSink reenterer = new MockReenteringSink();
        address hookAddr2 = address(uint160(0x7777 << 144) | HOOK_FLAGS);
        deployCodeTo(
            "FeeHook.sol:FeeHook",
            abi.encode(
                manager,
                address(word),
                LP_FEE,
                TICK_SPACING,
                address(reenterer),
                address(bounty),
                address(burnSink),
                admin
            ),
            hookAddr2
        );
        FeeHook hook2 = FeeHook(payable(hookAddr2));
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook2).call{value: 1 ether}("");
        assertTrue(ok);
        vm.expectRevert(FeeHook.FlushReentered.selector);
        hook2.flush();
    }

    // ──────────────────── dynamic per-flush routing (3-way ⇄ 2-way) ─────────────────────

    /// @dev No burnable excess → two-way flush: the burn slice folds into rewards/bounty at
    ///      the default 70/30, and the BurnEngine receives nothing.
    function test_flush_noExcess_routesTwoWay() public {
        word.setBurnableExcess(0);
        _enableTrading();
        _buyExactIn(100 ether); // 1 ether accrued

        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit FeeHook.Flushed(keeper, 0.7 ether, 0.3 ether, 0);
        hook.flush();

        assertEq(rewards.received(), 0.7 ether, "70% to holders");
        assertEq(bounty.received(), 0.3 ether, "30% to bounty");
        assertEq(burnSink.received(), 0, "no excess - BurnEngine gets nothing");
        assertEq(rewards.received() + bounty.received(), 1 ether, "two slices sum to 100%");
    }

    /// @dev The mode is chosen PER FLUSH and is fully reversible: excess present → three-way;
    ///      excess gone → two-way; excess back (an unbind freed WORD) → three-way again. No
    ///      one-way latch.
    function test_flush_modeTogglesPerFlushByExcess() public {
        _enableTrading();

        // 1) excess present → three-way.
        _buyExactIn(100 ether);
        hook.flush();
        assertEq(burnSink.received(), 0.25 ether, "three-way while excess present");

        // 2) excess drained to 0 → next flush is two-way.
        word.setBurnableExcess(0);
        _buyExactIn(100 ether);
        hook.flush();
        assertEq(burnSink.received(), 0.25 ether, "BurnEngine unchanged - two-way this flush");
        assertEq(rewards.received(), 0.5 ether + 0.7 ether, "50% then 70%");

        // 3) an unbind frees excess again → back to three-way (no latch blocks it).
        word.setBurnableExcess(500e18);
        _buyExactIn(100 ether);
        hook.flush();
        assertEq(burnSink.received(), 0.5 ether, "three-way resumed: +0.25 ether to burn");
    }

    /// @dev Both configs apply in their own mode: a customised three-way config is used only
    ///      when excess exists, a customised two-way config only when it doesn't.
    function test_flush_bothConfigsApplyInTheirMode() public {
        vm.startPrank(admin);
        hook.setBurnPhaseSplit(6000, 1500, 2500); // three-way
        hook.setPostBurnSplit(8000, 2000); // two-way
        vm.stopPrank();
        _enableTrading();

        // Excess present → three-way 60/15/25.
        _buyExactIn(100 ether);
        hook.flush();
        assertEq(rewards.received(), 0.6 ether);
        assertEq(bounty.received(), 0.15 ether);
        assertEq(burnSink.received(), 0.25 ether);

        // No excess → two-way 80/20.
        word.setBurnableExcess(0);
        _buyExactIn(100 ether);
        hook.flush();
        assertEq(rewards.received(), 0.6 ether + 0.8 ether);
        assertEq(bounty.received(), 0.15 ether + 0.2 ether);
        assertEq(burnSink.received(), 0.25 ether, "no further burn routing without excess");
    }

    function test_settersFlushPendingAtOldSplitFirst() public {
        _enableTrading();
        _buyExactIn(100 ether); // 1 ether pending at 50/25/25 (excess present)
        vm.prank(admin);
        hook.setBurnPhaseSplit(6000, 2000, 2000);
        // The pending ether was routed at the OLD three-way split.
        assertEq(rewards.received(), 0.5 ether);
        assertEq(bounty.received(), 0.25 ether);
        assertEq(burnSink.received(), 0.25 ether);
    }

    // ─────────────────────────────── full flow smoke ───────────────────────────────────

    /// @dev Checklist item: the full fee → split → deposit flow into the REAL
    ///      RewardsDistributor, REAL BountyEngine, and REAL BurnEngine (not sinks). A
    ///      MockWordBank backs the distributor's alive-count; everything else is production
    ///      code. Verifies each recipient's actual ETH balance and that the rewards
    ///      accumulator spread the deposit over the alive NFTs.
    function test_flush_intoRealRecipients() public {
        // Real recipient stack.
        MockWordBank bank = new MockWordBank();
        BountyEngine realBounty = new BountyEngine(address(bank), admin);
        RewardsDistributor realRewards = new RewardsDistributor(address(bank), address(realBounty));
        bank.setDistributor(address(realRewards));
        bank.mint(1, address(this));
        bank.mint(2, address(this)); // two alive NFTs share the rewards slice
        WordToken realToken = new WordToken(admin);
        BurnEngine realBurn =
            new BurnEngine(manager, IWordToken(address(realToken)), IRewardsDistributor(address(realRewards)), admin);

        // Fresh hook + pool wired to the real recipients.
        address hookAddr2 = address(uint160(0x6666 << 144) | HOOK_FLAGS);
        deployCodeTo(
            "FeeHook.sol:FeeHook",
            abi.encode(
                manager,
                address(word),
                LP_FEE,
                TICK_SPACING,
                address(realRewards),
                address(realBounty),
                address(realBurn),
                admin
            ),
            hookAddr2
        );
        FeeHook hook2 = FeeHook(payable(hookAddr2));
        (PoolKey memory key2,) = initPool(
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(word)),
            IHooks(hookAddr2),
            LP_FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );
        modifyLiquidityRouter.modifyLiquidity{value: 110_000 ether}(
            key2,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 100_000e18, salt: 0
            }),
            ZERO_BYTES
        );
        vm.prank(admin);
        hook2.enableTrading();

        // Swap → skim → flush.
        swapNativeInput(key2, true, -100 ether, ZERO_BYTES, 100 ether);
        uint256 accrued = address(hook2).balance;
        assertEq(accrued, 1 ether);
        hook2.flush();

        // Real recipients hold the exact slices.
        assertEq(address(realRewards).balance, 0.5 ether, "RewardsDistributor got 50%");
        assertEq(address(realBounty).balance, 0.25 ether, "BountyEngine got 25%");
        assertEq(address(realBurn).balance, 0.25 ether, "BurnEngine got 25%");
        assertEq(realBurn.pendingEth(), 0.25 ether);

        // And the distributor spread its slice over the two alive NFTs.
        assertEq(realRewards.pendingRewards(1), 0.25 ether);
        assertEq(realRewards.pendingRewards(2), 0.25 ether);
    }

    function test_fullFlow_swapAccrueFlushRepeatedly() public {
        _enableTrading();
        vm.prank(admin);
        hook.sunsetGuard();

        uint256 totalSkimmed;
        for (uint256 i = 1; i <= 5; i++) {
            _buyExactIn(i * 10 ether);
            swap(key, false, -int256(i * 5_000e18), ZERO_BYTES);
            uint256 bal = address(hook).balance;
            totalSkimmed += bal;
            hook.flush();
        }
        assertEq(address(hook).balance, 0);
        assertEq(rewards.received() + bounty.received() + burnSink.received(), totalSkimmed, "nothing lost or stuck");
        assertApproxEqRel(rewards.received(), totalSkimmed / 2, 0.001e18);
    }
}
