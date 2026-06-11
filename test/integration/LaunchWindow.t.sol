// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {IntegrationBase} from "./IntegrationBase.sol";
import {FeeHook} from "../../src/FeeHook.sol";

/// @title  Scenario: the launch window — gate ordering, whale guard, no-admin sunset (agent 6)
/// @notice Charter scenario 4: the pool can be initialized and seeded while swaps stay
///         gated (gate-vs-seed ordering); whale-size buys revert during the guard at the
///         exact 10,000e18 WORD boundary; the guard dies at +1 hour with NO admin action;
///         the admin sunset path also works and neither is re-enableable; the BurnEngine's
///         own buyback is exempt from the guard.
contract LaunchWindowTest is IntegrationBase {
    function setUp() public {
        _deployProtocol();
        _mintOutCollection();
        _syncRegistry();
        _seedPool(); // pool initialized + seeded while the trading gate is still DOWN
        _seal();
    }

    /// @dev Gate-vs-seed ordering: liquidity sits in an initialized pool, yet every swap
    ///      reverts until the one-time enableTrading() — exactly the runbook's sequencing.
    function test_gateOrdering_seededPoolStaysGatedUntilEnable() public {
        // The pool exists, is funded, and is still unswappable — both directions.
        vm.expectRevert(); // TradingNotEnabled, wrapped by the router
        _buyExactIn(bob, 1 ether);
        token.approve(address(swapRouter), type(uint256).max); // fixture holds leftover WORD
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -int256(1_000e18), sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Only the admin can open it, exactly once.
        vm.prank(bob);
        vm.expectRevert();
        hook.enableTrading();

        _enableTrading();
        assertEq(hook.tradingEnabledAt(), uint64(block.timestamp));
        _buyExactIn(bob, 1 ether); // trading is live

        vm.prank(admin);
        vm.expectRevert(FeeHook.TradingAlreadyEnabled.selector);
        hook.enableTrading();
    }

    /// @dev The anti-whale boundary, on the real pool: a buy of EXACTLY 10,000e18 WORD
    ///      output passes; one more wei of output reverts in afterSwap.
    function test_whaleGuard_exactBoundaryOnRealPool() public {
        _enableTrading();
        assertTrue(hook.guardActive());

        // Exact-output buy at the cap: passes.
        _buyExactOut(bob, 10_000e18, 12 ether);

        // One wei past the cap: afterSwap reverts the whole swap.
        vm.expectRevert(); // BuyExceedsLaunchCap, wrapped by the router/manager
        _buyExactOut(bob, 10_000e18 + 1, 12 ether);

        // Exact-input buys are capped by their OUTPUT too: ~11 ETH would buy > 10,000 WORD.
        vm.expectRevert();
        _buyExactIn(bob, 11 ether);

        // Sells are never guard-limited (bob holds 10,000 WORD from the cap buy).
        _sellExactIn(bob, 10_000e18);
    }

    /// @dev The guard dies at +1 hour with NO admin involvement — the hardcoded backstop.
    function test_guardAutoExpiry_noAdminNeeded() public {
        _enableTrading();
        assertTrue(hook.guardActive());

        // One second before expiry it still bites.
        vm.warp(uint256(hook.tradingEnabledAt()) + 1 hours - 1);
        assertTrue(hook.guardActive());
        vm.expectRevert();
        _buyExactOut(bob, 10_001e18, 13 ether);

        // At exactly +1h it is dead — strictly by timestamp, no call needed.
        vm.warp(uint256(hook.tradingEnabledAt()) + 1 hours);
        assertFalse(hook.guardActive());
        _buyExactOut(bob, 10_001e18, 13 ether); // whale-size buy now passes
    }

    /// @dev The admin sunset path: early, one-time, irreversible.
    function test_sunsetGuard_adminPath_irreversible() public {
        // Sunset before enableTrading is meaningless and reverts.
        vm.prank(admin);
        vm.expectRevert(FeeHook.TradingNotEnabled.selector);
        hook.sunsetGuard();

        _enableTrading();

        vm.prank(bob);
        vm.expectRevert();
        hook.sunsetGuard(); // not admin

        vm.prank(admin);
        hook.sunsetGuard();
        assertFalse(hook.guardActive(), "sunset kills the guard early");
        _buyExactOut(bob, 10_001e18, 13 ether); // whale-size buy passes immediately

        vm.prank(admin);
        vm.expectRevert(FeeHook.GuardAlreadySunset.selector);
        hook.sunsetGuard(); // not re-callable; no re-enable path exists at all
    }

    /// @dev The BurnEngine's buyback is a buy too — and is exempt from the guard, so a
    ///      buyback can never brick on the launch window (architecture §6). Run INSIDE the
    ///      guard window with the engine's max 1-ETH spend; supply is sealed, so the burn
    ///      path is live (SYS-1: buybacks begin at the seal).
    function test_burnEngineBuyback_exemptFromGuard() public {
        _enableTrading();
        assertTrue(hook.guardActive());

        vm.deal(address(this), 2 ether);
        burnEngine.deposit{value: 1 ether}();
        uint256 supplyBefore = token.totalSupply();

        vm.prank(keeper);
        burnEngine.executeBuyback(1 ether); // a ~1,000-WORD buy, inside the guard window

        assertLt(token.totalSupply(), supplyBefore, "buyback bought and burned during the guard");
        assertGt(token.burnedTotal(), 0);
    }
}
