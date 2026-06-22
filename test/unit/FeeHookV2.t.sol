// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {FeeHookV2} from "../../src/FeeHookV2.sol";
import {IBountyEngine} from "../../src/interfaces/IBountyEngine.sol";
import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";
import {IWordStaking} from "../../src/interfaces/IWordStaking.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {MockEthSink} from "../mocks/MockEthSink.sol";
import {MockWordToken} from "../mocks/MockWordToken.sol";

/// @notice Unit suite for FeeHookV2 against a real local V4 PoolManager. Validates the 1%
///         ETH-side skim (identical to the original), the FIXED 25/25/50 router, the launch
///         gate + anti-whale guard, and the bounded fee rate. Pool: native ETH (currency0) /
///         WORD (currency1).
contract FeeHookV2Test is Test, Deployers {
    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant BPS = 10_000;
    int24 constant TICK_SPACING = 60;
    uint24 constant LP_FEE = 3000;

    // beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta
    uint160 constant HOOK_FLAGS = uint160((1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    MockWordToken word;
    FeeHookV2 hook;
    MockEthSink rewards;
    MockEthSink bounty;
    MockEthSink staking;
    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");

    function setUp() public {
        deployFreshManagerAndRouters();

        word = new MockWordToken();
        rewards = new MockEthSink();
        bounty = new MockEthSink();
        staking = new MockEthSink();

        address hookAddr = address(uint160((0x4444 << 144)) | HOOK_FLAGS);
        deployCodeTo(
            "FeeHookV2.sol:FeeHookV2",
            abi.encode(
                manager, address(word), LP_FEE, TICK_SPACING, address(rewards), address(bounty), address(staking), admin
            ),
            hookAddr
        );
        hook = FeeHookV2(payable(hookAddr));

        (key,) = initPool(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(word)), IHooks(hookAddr), LP_FEE, TICK_SPACING, SQRT_PRICE_1_1
        );

        // Deep full-range liquidity so 10k-WORD buys have low impact.
        word.mint(address(this), 5_000_000e18);
        word.approve(address(modifyLiquidityRouter), type(uint256).max);
        word.approve(address(swapRouter), type(uint256).max);
        vm.deal(address(this), 5_000_000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 2_100_000 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 2_000_000e18, salt: 0}),
            ZERO_BYTES
        );
    }

    function _enableTrading() internal {
        vm.prank(admin);
        hook.enableTrading();
    }

    function _buyExactIn(uint256 ethIn) internal returns (BalanceDelta) {
        return swapNativeInput(key, true, -int256(ethIn), ZERO_BYTES, ethIn);
    }

    function _buyExactOut(uint256 wordOut, uint256 maxEth) internal returns (BalanceDelta) {
        return swapRouter.swap{value: maxEth}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: int256(wordOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    // ───────────────────────────── wiring & address ────────────────────────────────────

    function test_splitConstantsAreFixed_25_25_50() public view {
        assertEq(hook.REWARDS_BPS(), 2500);
        assertEq(hook.BOUNTY_BPS(), 2500);
        assertEq(hook.STAKING_BPS(), 5000);
        assertEq(uint256(hook.REWARDS_BPS()) + hook.BOUNTY_BPS() + hook.STAKING_BPS(), BPS);
    }

    function test_hookAddressEncodesExactlyTheFourFlags() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
        assertTrue(Hooks.isValidHookAddress(IHooks(address(hook)), LP_FEE));
    }

    function test_hookMiner_minedSaltDeploysAtPredictedAddress() public {
        bytes memory args = abi.encode(
            manager, address(word), LP_FEE, TICK_SPACING, address(rewards), address(bounty), address(staking), admin
        );
        (address mined, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, type(FeeHookV2).creationCode, args);
        FeeHookV2 deployed = new FeeHookV2{salt: salt}(
            manager,
            address(word),
            LP_FEE,
            TICK_SPACING,
            IRewardsDistributor(address(rewards)),
            IBountyEngine(address(bounty)),
            IWordStaking(address(staking)),
            admin
        );
        assertEq(address(deployed), mined);
        assertEq(uint160(address(deployed)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
    }

    // ─────────────────────────────────── trading gate ──────────────────────────────────

    function test_swapsRevertBeforeEnableTrading() public {
        vm.expectRevert();
        _buyExactIn(1 ether);
    }

    function test_enableTrading_onlyAdmin_onlyOnce() public {
        vm.expectRevert();
        hook.enableTrading(); // not admin
        _enableTrading();
        assertEq(hook.tradingEnabledAt(), uint64(block.timestamp));
        vm.prank(admin);
        vm.expectRevert(FeeHookV2.TradingAlreadyEnabled.selector);
        hook.enableTrading();
    }

    // ─────────────────────────────── skim exactness ────────────────────────────────────

    function test_skim_buyExactIn() public {
        _enableTrading();
        uint256 ethIn = 1 ether;
        BalanceDelta delta = _buyExactIn(ethIn);
        assertEq(address(hook).balance, ethIn * FEE_BPS / BPS, "skim exact");
        assertEq(uint256(uint128(-delta.amount0())), ethIn, "user pays exactly ethIn");
        assertGt(delta.amount1(), 0);
    }

    function test_skim_sellExactIn() public {
        _enableTrading();
        BalanceDelta delta = swap(key, false, -int256(1_000e18), ZERO_BYTES);
        uint256 fee = address(hook).balance;
        uint256 poolEthOut = uint256(uint128(delta.amount0())) + fee;
        assertEq(fee, poolEthOut * FEE_BPS / BPS, "fee exact on pool ETH output");
    }

    function test_skim_accruesAcrossSwaps() public {
        _enableTrading();
        _buyExactIn(1 ether);
        _buyExactIn(2 ether);
        swap(key, false, int256(1 ether), ZERO_BYTES);
        assertEq(hook.pendingFees(), (1 ether + 2 ether + 1 ether) * FEE_BPS / BPS);
    }

    // ──────────────────────────────── fixed-split flush ────────────────────────────────

    function test_flush_routes_25_25_50() public {
        _enableTrading();
        _buyExactIn(10 ether); // fee = 0.1 ETH
        uint256 fee = address(hook).balance;
        assertGt(fee, 0);

        vm.prank(keeper);
        hook.flush(); // permissionless

        assertEq(rewards.received(), fee * 2500 / BPS, "rewards 25%");
        assertEq(bounty.received(), fee * 2500 / BPS, "bounty 25%");
        // staking takes the remainder so the three sum to the whole fee.
        assertEq(staking.received(), fee - (fee * 2500 / BPS) * 2, "staking 50% + remainder");
        assertEq(rewards.received() + bounty.received() + staking.received(), fee, "sums to balance");
        assertEq(address(hook).balance, 0, "fully routed");
    }

    function test_flush_permissionless_anyoneCanCall() public {
        _enableTrading();
        _buyExactIn(1 ether);
        address rando = makeAddr("rando");
        vm.prank(rando);
        hook.flush();
        assertEq(address(hook).balance, 0);
    }

    function test_flush_emptyIsNoop() public {
        hook.flush();
        assertEq(rewards.received(), 0);
        assertEq(staking.received(), 0);
    }

    // ─────────────────────────────── anti-whale guard ──────────────────────────────────

    function test_guard_buyAtCapPasses_overCapReverts() public {
        _enableTrading();
        assertTrue(hook.guardActive());
        BalanceDelta delta = _buyExactOut(10_000e18, 11_000 ether);
        assertEq(uint256(uint128(delta.amount1())), 10_000e18);

        vm.expectRevert();
        _buyExactOut(10_000e18 + 1, 11_000 ether);
    }

    function test_guard_autoExpiryAfterOneHour() public {
        _enableTrading();
        assertTrue(hook.guardActive());
        vm.warp(block.timestamp + 1 hours);
        assertFalse(hook.guardActive());
        BalanceDelta delta = _buyExactOut(50_000e18, 60_000 ether);
        assertEq(uint256(uint128(delta.amount1())), 50_000e18);
    }

    function test_guard_adminSunset() public {
        _enableTrading();
        vm.prank(admin);
        hook.sunsetGuard();
        assertFalse(hook.guardActive());
        BalanceDelta delta = _buyExactOut(50_000e18, 60_000 ether);
        assertEq(uint256(uint128(delta.amount1())), 50_000e18);
    }

    // ──────────────────────────────── bounded fee rate ─────────────────────────────────

    function test_setFeeBps_bounds() public {
        vm.startPrank(admin);
        vm.expectRevert(FeeHookV2.FeeOutOfBounds.selector);
        hook.setFeeBps(0);
        vm.expectRevert(FeeHookV2.FeeOutOfBounds.selector);
        hook.setFeeBps(201);
        hook.setFeeBps(200);
        vm.stopPrank();
        assertEq(hook.feeBps(), 200);
    }

    function test_setFeeBps_onlyAdmin() public {
        vm.expectRevert();
        hook.setFeeBps(150);
    }

    function test_setFeeBps_flushesFirst() public {
        _enableTrading();
        _buyExactIn(10 ether); // accrue at 1%
        vm.prank(admin);
        hook.setFeeBps(200); // must flush the 1%-rate fees before changing the rate
        assertEq(address(hook).balance, 0, "old-rate fees routed before change");
        assertGt(staking.received(), 0);
    }
}
