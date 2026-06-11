// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {BountyEngine} from "../../src/BountyEngine.sol";
import {BurnEngine} from "../../src/BurnEngine.sol";
import {FeeHook} from "../../src/FeeHook.sol";
import {LPLocker} from "../../src/LPLocker.sol";
import {Renderer} from "../../src/Renderer.sol";
import {RewardsDistributor} from "../../src/RewardsDistributor.sol";
import {RoyaltySplitter} from "../../src/RoyaltySplitter.sol";
import {WordBank} from "../../src/WordBank.sol";
import {WordToken} from "../../src/WordToken.sol";
import {IBountyEngine} from "../../src/interfaces/IBountyEngine.sol";
import {IBurnEngine} from "../../src/interfaces/IBurnEngine.sol";
import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";
import {IWordToken} from "../../src/interfaces/IWordToken.sol";
import {HookMiner} from "../../script/HookMiner.sol";

// ── Minimal canonical-mainnet interfaces (decoupled from the repo's v4-periphery pin) ──

/// @dev The production UniversalRouter entrypoint the dApp calls (app/lib/swap/execute.ts).
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev Permit2 AllowanceTransfer.approve — the sell path's router allowance (mirrors
///      buildPermit2ApproveConfig in execute.ts).
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev V4 Quoter (mainnet). `quoteExactInputSingle` simulates the real swap (pool + our hook)
///      via swap-and-revert and returns the amount out; it is non-view but changes no state.
interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams calldata params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @dev The V4 router's slippage revert (exact-input received below the minimum). The DEPLOYED
///      mainnet V4Router emits the **uint256**-arg form here — `V4TooLittleReceived(uint256,
///      uint256)`, selector 0x8b063d73 (confirmed against the overseer's live-fork run). It
///      surfaces UNWRAPPED, since it is a router-level revert, not a hook revert.
interface IV4RouterErrors {
    error V4TooLittleReceived(uint256 minAmountOutReceived, uint256 amountReceived);
}

/// @title  UniversalRouter swap — production router path against our pool+hook (agent 6)
/// @notice CHANGE ORDER 2026-06-14. Agent 9 wired the frontend WORD swap to the canonical
///         UniversalRouter (`app/lib/swap/execute.ts`). The live buy/sell is wallet-driven
///         (testnet rehearsal), but the ON-CHAIN production-router path is provable without a
///         wallet — this is that proof. It encodes the SAME command/action shape the dApp emits
///         — one `V4_SWAP` command of `SWAP_EXACT_IN_SINGLE → SETTLE_ALL → TAKE_ALL` — and
///         calls the real mainnet `UniversalRouter.execute` against our seeded pool + FeeHook.
///
///         RPC-GATED exactly like ForkLifecycle: skips unless `FORK_URL`/`MAINNET_RPC_URL` is
///         set, so the default offline `forge test` stays green. The overseer runs it against a
///         live mainnet fork to capture the green result.
///
///         CALLDATA-SHAPE NOTE: the swap params are encoded with the **5-field**
///         `ExactInputSingleParams` layout used by the deployed mainnet V4 router and the
///         frontend's Uniswap v4 SDK (poolKey, zeroForOne, amountIn, amountOutMinimum,
///         hookData) — NOT this repo's newer 6-field v4-periphery pin (which adds
///         `minHopPriceX36` and the mainnet router would not decode). Proving the shape the
///         dApp actually emits is the whole point, so the local struct mirrors the SDK/mainnet.
contract UniversalRouterSwapTest is Test {
    using Strings for uint256;

    // Canonical mainnet addresses (overridable by env) — same set as app/lib/contracts/addresses.ts.
    address constant DEFAULT_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant DEFAULT_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant DEFAULT_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant DEFAULT_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant DEFAULT_V4_QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;

    // V4 UniversalRouter command + V4 router action selectors (stable on mainnet).
    uint8 constant V4_SWAP = 0x10;
    uint8 constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE_ALL = 0x0f;

    uint160 constant HOOK_FLAGS = uint160((1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint24 constant LP_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint256 constant LIQUIDITY = 1_000_000e18; // WORD seeded into the pool
    uint96 constant LAUNCH_ROYALTY_BPS = 300;

    /// @dev The 5-field mainnet/SDK exact-input-single params (see contract CALLDATA-SHAPE NOTE).
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    bool internal forkActive;
    IPoolManager internal poolManager;
    IPositionManager internal posm;
    address internal permit2;
    address internal wethAddr;
    IUniversalRouter internal router;
    IV4Quoter internal quoter;

    address internal admin = makeAddr("admin");
    address internal trader = makeAddr("trader");

    WordBank internal bank;
    WordToken internal token;
    BountyEngine internal bounty;
    RewardsDistributor internal distributor;
    BurnEngine internal burnEngine;
    FeeHook internal hook;
    LPLocker internal locker;
    RoyaltySplitter internal royaltySplitter;
    PoolKey internal key;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_URL", vm.envOr("MAINNET_RPC_URL", string("")));
        if (bytes(rpc).length == 0) {
            forkActive = false;
            return;
        }
        vm.createSelectFork(rpc);
        forkActive = true;

        poolManager = IPoolManager(vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER));
        posm = IPositionManager(vm.envOr("POSITION_MANAGER", DEFAULT_POSITION_MANAGER));
        permit2 = vm.envOr("PERMIT2", DEFAULT_PERMIT2);
        wethAddr = vm.envOr("WETH", DEFAULT_WETH);
        router = IUniversalRouter(vm.envOr("UNIVERSAL_ROUTER", DEFAULT_UNIVERSAL_ROUTER));
        quoter = IV4Quoter(vm.envOr("V4_QUOTER", DEFAULT_V4_QUOTER));

        vm.deal(admin, 5_000 ether);
        vm.deal(trader, 5_000 ether);

        _deployAndWire();
        _seedPoolAndEnableTrading();
    }

    modifier requiresFork() {
        if (!forkActive) {
            emit log("SKIP: set FORK_URL (or MAINNET_RPC_URL) to run the UniversalRouter swap fork test");
            vm.skip(true);
            return;
        }
        _;
    }

    // ─────────────────────────────────── buy: ETH → WORD ───────────────────────────────

    /// @dev execute{value: ethIn}(...) with no approval — exactly the dApp's buy path. Asserts
    ///      WORD received ≥ minOut and ≈ the V4 Quoter quote, and that the FeeHook skimmed 1%.
    function test_router_buy_ethForWord() public requiresFork {
        uint256 ethIn = 1 ether;

        uint256 quoted = _quote(true, uint128(ethIn));
        uint256 minOut = quoted * 9_900 / 10_000; // 1% slippage, like the dApp

        (bytes memory commands, bytes[] memory inputs) = _buildSwap(true, uint128(ethIn), uint128(minOut));

        uint256 wordBefore = token.balanceOf(trader);
        uint256 hookFeesBefore = hook.pendingFees();

        uint256 g = gasleft();
        vm.prank(trader);
        router.execute{value: ethIn}(commands, inputs, block.timestamp + 1800);
        console2.log("UniversalRouter buy (ETH->WORD) gas", g - gasleft());

        uint256 received = token.balanceOf(trader) - wordBefore;
        assertGe(received, minOut, "WORD received >= minOut");
        // The Quoter simulates the same pool+hook swap in this pre-swap state → matches closely.
        assertApproxEqRel(received, quoted, 0.001e18, "WORD received ~= V4 Quoter quote (<=0.1%)");
        // FeeHook skims 1% of the ETH-in on an exact-input buy (taken in beforeSwap).
        assertEq(hook.pendingFees() - hookFeesBefore, ethIn / 100, "FeeHook took its 1% skim");
    }

    // ─────────────────────────────────── sell: WORD → ETH ──────────────────────────────

    /// @dev Full Permit2 sell path in Solidity — WORD.approve(Permit2) → Permit2.approve(router)
    ///      → execute(...) — exactly the dApp's sell path (buildErc20ApproveConfig +
    ///      buildPermit2ApproveConfig + buildSwapConfig).
    function test_router_sell_wordForEth() public requiresFork {
        // Acquire WORD via a buy first (the trader starts with none).
        uint256 wordHeld = _buyForWord(2 ether);
        uint256 wordIn = wordHeld / 2;

        uint256 quoted = _quote(false, uint128(wordIn));
        uint256 minOut = quoted * 9_900 / 10_000;

        // dApp's two-step allowance: ERC-20 → Permit2, then Permit2 → UniversalRouter.
        vm.startPrank(trader);
        token.approve(permit2, type(uint256).max);
        IPermit2(permit2).approve(address(token), address(router), uint160(wordIn), uint48(block.timestamp + 3600));
        vm.stopPrank();

        (bytes memory commands, bytes[] memory inputs) = _buildSwap(false, uint128(wordIn), uint128(minOut));

        uint256 ethBefore = trader.balance;
        vm.prank(trader);
        router.execute(commands, inputs, block.timestamp + 1800);

        assertGe(trader.balance - ethBefore, minOut, "ETH received >= minOut");
    }

    // ────────────────────────────────── revert cases ───────────────────────────────────

    /// @dev (a) A buy whose WORD-out exceeds BUY_CAP (10,000e18) during the guard window
    ///      reverts FeeHook.BuyExceedsLaunchCap — the dApp pre-blocks this client-side. On the
    ///      live mainnet router the hook revert surfaces WRAPPED in v4's
    ///      `CustomRevert.WrappedError(target, selector, reason, details)`: we assert the outer
    ///      wrapper, that `target` is our FeeHook, and that the inner `reason` selector is
    ///      BuyExceedsLaunchCap (the bare selector never appears at top level).
    function test_router_buy_exceedsLaunchCap_reverts() public requiresFork {
        assertTrue(hook.guardActive(), "guard active in setUp window");
        // ~11 ETH buys > 10,000 WORD at the ~1,000 WORD/ETH seed price.
        uint256 ethIn = 11 ether;
        (bytes memory commands, bytes[] memory inputs) = _buildSwap(true, uint128(ethIn), 1);
        bytes memory ret = _executeExpectingRevert(ethIn, commands, inputs);
        _assertWrappedHookError(ret, FeeHook.BuyExceedsLaunchCap.selector);
    }

    /// @dev (b) A swap before enableTrading() reverts FeeHook.TradingNotEnabled — same WRAPPED
    ///      shape as (a). Uses a fresh, seeded-but-not-enabled deployment so the gate is the
    ///      only difference.
    function test_router_swap_beforeEnableTrading_reverts() public requiresFork {
        _redeployWithoutEnablingTrading();
        uint256 ethIn = 1 ether;
        (bytes memory commands, bytes[] memory inputs) = _buildSwap(true, uint128(ethIn), 1);
        bytes memory ret = _executeExpectingRevert(ethIn, commands, inputs);
        _assertWrappedHookError(ret, FeeHook.TradingNotEnabled.selector);
    }

    /// @dev (c) An impossible amountOutMinimum reverts the V4 slippage error. This is a
    ///      router-level (not hook) revert, so it surfaces UNWRAPPED — top-level
    ///      V4TooLittleReceived, the deployed mainnet uint256-arg form (see IV4RouterErrors note).
    function test_router_buy_slippage_reverts() public requiresFork {
        uint256 ethIn = 1 ether;
        uint128 impossibleMin = type(uint128).max; // far above any real output
        (bytes memory commands, bytes[] memory inputs) = _buildSwap(true, uint128(ethIn), impossibleMin);
        bytes memory ret = _executeExpectingRevert(ethIn, commands, inputs);
        assertEq(
            _selectorOf(ret),
            IV4RouterErrors.V4TooLittleReceived.selector,
            "unwrapped V4 slippage error (mainnet uint256 signature)"
        );
    }

    // ─────────────────────────── revert-assertion helpers ──────────────────────────────

    /// @dev Calls UniversalRouter.execute as `trader`, asserts it reverted, and returns the
    ///      raw revert data for selector/inner-error inspection. (A low-level call captures the
    ///      revert bytes; `vm.expectRevert` cannot match the live router's WrappedError wrapping
    ///      of inner hook errors with an unknown inner argument.)
    function _executeExpectingRevert(uint256 ethIn, bytes memory commands, bytes[] memory inputs)
        internal
        returns (bytes memory ret)
    {
        bool ok;
        vm.prank(trader);
        (ok, ret) = address(router).call{value: ethIn}(
            abi.encodeCall(IUniversalRouter.execute, (commands, inputs, block.timestamp + 1800))
        );
        assertFalse(ok, "expected the swap to revert");
    }

    /// @dev Asserts `ret` is v4's `CustomRevert.WrappedError(target, selector, reason, details)`
    ///      with `target == our FeeHook` and `reason`'s selector == `innerSelector` — i.e. the
    ///      mainnet UniversalRouter wrapped our hook's specific revert.
    function _assertWrappedHookError(bytes memory ret, bytes4 innerSelector) internal view {
        assertEq(_selectorOf(ret), CustomRevert.WrappedError.selector, "mainnet router wraps inner hook reverts");
        (address target,, bytes memory reason,) = abi.decode(_stripSelector(ret), (address, bytes4, bytes, bytes));
        assertEq(target, address(hook), "WrappedError target is our FeeHook");
        assertEq(_selectorOf(reason), innerSelector, "inner hook error matches the dApp's pre-block");
    }

    /// @dev First 4 bytes of a memory bytes blob as a selector.
    function _selectorOf(bytes memory data) internal pure returns (bytes4 s) {
        require(data.length >= 4, "no selector");
        assembly {
            s := mload(add(data, 0x20))
        }
    }

    /// @dev `data` with its leading 4-byte selector stripped (for abi.decode of the args).
    function _stripSelector(bytes memory data) internal pure returns (bytes memory out) {
        require(data.length >= 4, "no selector");
        out = new bytes(data.length - 4);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }

    // ─────────────────────────────── encoding (mirrors execute.ts) ──────────────────────

    /// @dev Builds the UniversalRouter (commands, inputs) for an exact-input V4 swap, byte-shape
    ///      identical to app/lib/swap/execute.ts: one V4_SWAP command whose actions are
    ///      SWAP_EXACT_IN_SINGLE → SETTLE_ALL → TAKE_ALL. buy = ETH(currency0)→WORD(currency1)
    ///      (zeroForOne true); sell = WORD→ETH (false).
    function _buildSwap(bool isBuy, uint128 amountIn, uint128 minOut)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        Currency inputCurrency = isBuy ? key.currency0 : key.currency1;
        Currency outputCurrency = isBuy ? key.currency1 : key.currency0;

        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: key, zeroForOne: isBuy, amountIn: amountIn, amountOutMinimum: minOut, hookData: bytes("")
            })
        );
        params[1] = abi.encode(inputCurrency, uint256(amountIn)); // SETTLE_ALL
        params[2] = abi.encode(outputCurrency, uint256(minOut)); // TAKE_ALL

        commands = abi.encodePacked(V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _quote(bool isBuy, uint128 amountIn) internal returns (uint256 amountOut) {
        (amountOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: isBuy, exactAmount: amountIn, hookData: bytes("")
            })
        );
    }

    /// @dev Runs a router buy and returns the WORD received (helper for the sell test).
    function _buyForWord(uint256 ethIn) internal returns (uint256 received) {
        uint256 minOut = _quote(true, uint128(ethIn)) * 9_900 / 10_000;
        (bytes memory commands, bytes[] memory inputs) = _buildSwap(true, uint128(ethIn), uint128(minOut));
        uint256 before = token.balanceOf(trader);
        vm.prank(trader);
        router.execute{value: ethIn}(commands, inputs, block.timestamp + 1800);
        received = token.balanceOf(trader) - before;
    }

    // ─────────────────────────── deploy + seed (mirrors ForkLifecycle) ──────────────────

    function _deployAndWire() internal {
        bank = new WordBank(admin);
        token = bank.wordToken();
        Renderer renderer = new Renderer();
        bounty = new BountyEngine(address(bank), admin);
        distributor = new RewardsDistributor(address(bank), address(bounty));
        burnEngine =
            new BurnEngine(poolManager, IWordToken(address(token)), IRewardsDistributor(address(distributor)), admin);

        bytes memory hookArgs = abi.encode(
            poolManager,
            address(token),
            LP_FEE,
            TICK_SPACING,
            IRewardsDistributor(address(distributor)),
            IBountyEngine(address(bounty)),
            IBurnEngine(address(burnEngine)),
            admin
        );
        (address minedHook, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(FeeHook).creationCode, hookArgs);
        hook = new FeeHook{salt: salt}(
            poolManager,
            address(token),
            LP_FEE,
            TICK_SPACING,
            IRewardsDistributor(address(distributor)),
            IBountyEngine(address(bounty)),
            IBurnEngine(address(burnEngine)),
            admin
        );
        require(address(hook) == minedHook, "hook address mismatch");

        locker = new LPLocker(posm, admin);
        royaltySplitter = new RoyaltySplitter(address(burnEngine), address(bounty), admin, wethAddr);

        vm.startPrank(admin);
        bank.setRenderer(address(renderer));
        bank.setRewardsDistributor(address(distributor));
        token.setBurner(address(burnEngine));
        bank.setRoyalty(address(royaltySplitter), LAUNCH_ROYALTY_BPS);
        vm.stopPrank();
    }

    /// @dev Lean tradeable state: mint the liquidity allotment, seed the WORD/ETH pool at
    ///      ~1,000 WORD/ETH, lock the position, wire the engine, enableTrading(). No NFT
    ///      mint-out / seal needed — user swaps are live the moment trading is enabled (the
    ///      buyback, which needs the seal, is out of scope here).
    function _seedPoolAndEnableTrading() internal {
        uint160 sqrtPriceX96 = uint160(_sqrt(1000 << 192));
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        int24 tickLower = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        uint256 ethLiquidity = 1_000 ether;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethLiquidity,
            LIQUIDITY
        );

        vm.startPrank(admin);
        token.mintLiquidity(admin, LIQUIDITY);
        token.approve(permit2, type(uint256).max);
        (bool ok,) = permit2.call(
            abi.encodeWithSignature(
                "approve(address,address,uint160,uint48)",
                address(token),
                address(posm),
                type(uint160).max,
                type(uint48).max
            )
        );
        require(ok, "permit2 approve failed");

        poolManager.initialize(key, sqrtPriceX96);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(liquidity), uint128(ethLiquidity), uint128(LIQUIDITY), admin, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, admin);
        posm.modifyLiquidities{value: ethLiquidity}(abi.encode(actions, params), block.timestamp + 600);
        uint256 tokenId = posm.nextTokenId() - 1;

        (ok,) = address(posm).call(abi.encodeWithSignature("approve(address,uint256)", address(locker), tokenId));
        require(ok, "posm approve failed");
        locker.lock(tokenId, block.timestamp + 365 days);

        burnEngine.setPool(key);
        hook.enableTrading();
        vm.stopPrank();
    }

    /// @dev Fresh deployment seeded to a tradeable pool but with trading still GATED (no
    ///      enableTrading) — for the TradingNotEnabled revert case.
    function _redeployWithoutEnablingTrading() internal {
        _deployAndWire();
        uint160 sqrtPriceX96 = uint160(_sqrt(1000 << 192));
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        int24 tickLower = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        uint256 ethLiquidity = 1_000 ether;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethLiquidity,
            LIQUIDITY
        );
        vm.startPrank(admin);
        token.mintLiquidity(admin, LIQUIDITY);
        token.approve(permit2, type(uint256).max);
        (bool ok,) = permit2.call(
            abi.encodeWithSignature(
                "approve(address,address,uint160,uint48)",
                address(token),
                address(posm),
                type(uint160).max,
                type(uint48).max
            )
        );
        require(ok, "permit2 approve failed");
        poolManager.initialize(key, sqrtPriceX96);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(liquidity), uint128(ethLiquidity), uint128(LIQUIDITY), admin, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, admin);
        posm.modifyLiquidities{value: ethLiquidity}(abi.encode(actions, params), block.timestamp + 600);
        burnEngine.setPool(key);
        // NOTE: hook.enableTrading() deliberately NOT called.
        vm.stopPrank();
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
