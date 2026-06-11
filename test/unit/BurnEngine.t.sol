// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {BurnEngine} from "../../src/BurnEngine.sol";
import {FeeHook} from "../../src/FeeHook.sol";
import {WordToken} from "../../src/WordToken.sol";
import {IBurnEngine} from "../../src/interfaces/IBurnEngine.sol";
import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";
import {IWordToken} from "../../src/interfaces/IWordToken.sol";
import {MockEthSink} from "../mocks/MockEthSink.sol";

/// @dev Keeper that cannot receive ETH — proves the tip-transfer failure path.
contract NoReceiveKeeper {
    function callBuyback(BurnEngine engine, uint256 maxSpend) external {
        engine.executeBuyback(maxSpend);
    }
}

/// @dev Stand-in for WordBank: the token's deployer (so `wordBank` points here) with a
///      settable `totalAlive` that drives WordToken's DYNAMIC floor
///      (`currentBurnFloor = totalAlive × 1000e18`). Lowering `totalAlive` simulates an
///      unbind — the live read the v3 floor depends on.
contract MockFloorBank {
    uint256 public totalAlive;

    function setTotalAlive(uint256 n) external {
        totalAlive = n;
    }
}

/// @notice Unit suite for the BurnEngine against a real local V4 pool with the real FeeHook
///         attached and the REAL WordToken (so dynamic-floor sizing, burnedTotal accounting,
///         and the resume-after-unbind behaviour are exercised end to end, not mocked).
///
///         Dynamic floor (interfaces-v3): the burnable amount is
///         `WordToken.burnableExcess() = totalSupply − totalAlive × 1000e18`. The bank mock's
///         `totalAlive` is the live oracle; lowering it (an unbind) frees new excess and the
///         buyback resumes — there is no permanent completion.
///
///         Pool economics: price 1,000 WORD per ETH, ~1,000 ETH / ~1,000,000 WORD of
///         full-range depth. The engine's spend band (0.1–1 ETH) buys 100–1,000 WORD per
///         call — 0.01–0.1% of depth, comfortably inside the 1% slippage tolerance.
contract BurnEngineTest is Test, Deployers {
    uint256 constant BPS = 10_000;
    int24 constant TICK_SPACING = 60;
    uint24 constant LP_FEE = 3000;
    uint160 constant HOOK_FLAGS = uint160((1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    MockFloorBank bank;
    WordToken token;
    BurnEngine engine;
    FeeHook hook;
    MockEthSink rewards;
    MockEthSink bounty;
    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");

    function setUp() public {
        deployFreshManagerAndRouters();

        // Real WordToken deployed by the floor-bank mock (so `wordBank` is the mock and its
        // settable totalAlive drives the dynamic floor). Full launch: 10M backing + 1M
        // liquidity, sealed, all 10,000 NFTs alive → floor 10M, burnable excess 1M.
        bank = new MockFloorBank();
        vm.prank(address(bank));
        token = new WordToken(admin);
        vm.prank(address(bank));
        token.mint(address(this), 10_000_000e18); // full backing allotment
        vm.prank(admin);
        token.mintLiquidity(address(this), 1_000_000e18); // full liquidity allotment
        token.sealMinting();
        bank.setTotalAlive(10_000); // floor = 10,000 × 1000e18 = 10M; excess = 1M

        rewards = new MockEthSink();
        bounty = new MockEthSink();

        engine = new BurnEngine(manager, IWordToken(address(token)), IRewardsDistributor(address(rewards)), admin);
        vm.prank(admin);
        token.setBurner(address(engine));

        address hookAddr = address(uint160(0x4444 << 144) | HOOK_FLAGS);
        deployCodeTo(
            "FeeHook.sol:FeeHook",
            abi.encode(
                manager, address(token), LP_FEE, TICK_SPACING, address(rewards), address(bounty), address(engine), admin
            ),
            hookAddr
        );
        hook = FeeHook(payable(hookAddr));

        // Initialize at 1,000 WORD per ETH: sqrtPriceX96 = sqrt(1000 << 192).
        uint160 sqrtPrice1000 = uint160(FixedPointMathLib.sqrt(1000 << 192));
        (key,) = initPool(
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(token)),
            IHooks(hookAddr),
            LP_FEE,
            TICK_SPACING,
            sqrtPrice1000
        );

        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        vm.deal(address(this), 100_000 ether);
        // L ≈ 31,623e18 over full range → ~1,000 ETH and ~1,000,000 WORD.
        modifyLiquidityRouter.modifyLiquidity{value: 1_010 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 31_623e18, salt: 0
            }),
            ZERO_BYTES
        );

        vm.startPrank(admin);
        hook.enableTrading();
        hook.sunsetGuard(); // guard interplay is covered separately; keep buy tests unconstrained
        engine.setPool(key);
        vm.stopPrank();
    }

    /// @dev Legitimate burner-path shortcut to bring supply near the floor: the engine (the
    ///      sole burner) burns WORD we hand it, exactly as it would burn bought WORD.
    function _preBurn(uint256 amount) internal {
        token.transfer(address(engine), amount);
        vm.prank(address(engine));
        token.burn(amount);
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), address(this).balance + amount);
        engine.deposit{value: amount}();
    }

    // ─────────────────────────────────── funding ───────────────────────────────────────

    function test_deposit_recordsAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit IBurnEngine.Deposited(address(this), 1 ether);
        engine.deposit{value: 1 ether}();
        assertEq(engine.pendingEth(), 1 ether);

        // Bare sends are accepted as donations.
        (bool ok,) = address(engine).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(engine.pendingEth(), 1.5 ether);
    }

    // ─────────────────────────────────── wiring ────────────────────────────────────────

    /// @dev Wires a fresh engine + a fresh FeeHook that points back at it (the R-1 mutual
    ///      binding means a hook wired to another engine is no longer an acceptable key).
    function _freshEnginePair() internal returns (BurnEngine fresh, PoolKey memory freshKey) {
        fresh = new BurnEngine(manager, IWordToken(address(token)), IRewardsDistributor(address(rewards)), admin);
        address hookAddr = address(uint160(0x5555 << 144) | HOOK_FLAGS);
        deployCodeTo(
            "FeeHook.sol:FeeHook",
            abi.encode(
                manager, address(token), LP_FEE, TICK_SPACING, address(rewards), address(bounty), address(fresh), admin
            ),
            hookAddr
        );
        freshKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
    }

    function test_setPool_validationsAndOneTime() public {
        (BurnEngine fresh, PoolKey memory freshKey) = _freshEnginePair();

        // Non-admin.
        vm.expectRevert();
        fresh.setPool(freshKey);

        // NB: memory-to-memory struct assignment aliases, so mutate freshKey directly and
        // restore each field before the next case.

        // Wrong currency1.
        freshKey.currency1 = Currency.wrap(address(rewards));
        vm.prank(admin);
        vm.expectRevert(BurnEngine.InvalidPoolKey.selector);
        fresh.setPool(freshKey);
        freshKey.currency1 = Currency.wrap(address(token));

        // Non-native currency0.
        freshKey.currency0 = Currency.wrap(address(token));
        vm.prank(admin);
        vm.expectRevert(BurnEngine.InvalidPoolKey.selector);
        fresh.setPool(freshKey);
        freshKey.currency0 = CurrencyLibrary.ADDRESS_ZERO;

        vm.prank(admin);
        fresh.setPool(freshKey);
        assertTrue(fresh.poolSet());

        vm.prank(admin);
        vm.expectRevert(BurnEngine.PoolAlreadySet.selector);
        fresh.setPool(freshKey);
    }

    /// @dev R-1: a hook wired to a DIFFERENT BurnEngine is rejected — the burn stream cannot
    ///      be misdirected to a pool whose hook doesn't route back to this engine.
    function test_setPool_rejectsHookBoundToForeignEngine() public {
        BurnEngine fresh =
            new BurnEngine(manager, IWordToken(address(token)), IRewardsDistributor(address(rewards)), admin);
        // `key` is the canonical pool of the hook wired to `engine`, not `fresh`.
        vm.prank(admin);
        vm.expectRevert(BurnEngine.InvalidPoolKey.selector);
        fresh.setPool(key);
    }

    /// @dev R-1: even with the right hook, a key that is not that hook's CANONICAL pool
    ///      (here: a different LP fee tier) is rejected via the poolId cross-check.
    function test_setPool_rejectsNonCanonicalPoolOfOurHook() public {
        (BurnEngine fresh, PoolKey memory freshKey) = _freshEnginePair();
        PoolKey memory offTier = freshKey;
        offTier.fee = 500; // canonical was mined/constructed for LP_FEE = 3000
        vm.prank(admin);
        vm.expectRevert(BurnEngine.InvalidPoolKey.selector);
        fresh.setPool(offTier);
    }

    /// @dev R-1: an EOA / codeless "hook" fails the view-call rather than being accepted.
    function test_setPool_rejectsCodelessHook() public {
        BurnEngine fresh =
            new BurnEngine(manager, IWordToken(address(token)), IRewardsDistributor(address(rewards)), admin);
        PoolKey memory bad = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(makeAddr("not-a-hook"))
        });
        vm.prank(admin);
        vm.expectRevert();
        fresh.setPool(bad);
    }

    /// @dev SYS-1: before the token seal (Phase 3), executeBuyback fails fast with the
    ///      unambiguous MintingNotSealedYet — no deep revert from inside WordToken.burn, no
    ///      pool interaction, no ETH moved, and the per-block buyback slot is NOT consumed.
    function test_executeBuyback_revertsCleanlyBeforeSeal() public {
        // Fresh, UNSEALED token + its own engine/hook pair (the suite's main token is sealed
        // in setUp).
        WordToken unsealed = new WordToken(admin);
        BurnEngine engine2 =
            new BurnEngine(manager, IWordToken(address(unsealed)), IRewardsDistributor(address(rewards)), admin);
        address hookAddr = address(uint160(0x6666 << 144) | HOOK_FLAGS);
        deployCodeTo(
            "FeeHook.sol:FeeHook",
            abi.encode(
                manager,
                address(unsealed),
                LP_FEE,
                TICK_SPACING,
                address(rewards),
                address(bounty),
                address(engine2),
                admin
            ),
            hookAddr
        );
        PoolKey memory key2 = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(unsealed)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        vm.prank(admin);
        engine2.setPool(key2);
        engine2.deposit{value: 1 ether}();

        vm.expectRevert(BurnEngine.MintingNotSealedYet.selector);
        engine2.executeBuyback(1 ether);

        // The doomed call consumed nothing: the slice keeps accruing and the block's
        // buyback slot stays free.
        assertEq(engine2.pendingEth(), 1 ether, "accrued ETH untouched");
        assertEq(engine2.lastBuybackBlock(), 0, "rate-limit slot not consumed");
    }

    function test_executeBuyback_revertsBeforeSetPool() public {
        BurnEngine fresh =
            new BurnEngine(manager, IWordToken(address(token)), IRewardsDistributor(address(rewards)), admin);
        vm.expectRevert(BurnEngine.PoolNotSet.selector);
        fresh.executeBuyback(1 ether);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(BurnEngine.NotPoolManager.selector);
        engine.unlockCallback(abi.encode(uint256(1), uint256(1)));
    }

    function test_setMaxSlippageBps_bounds() public {
        vm.startPrank(admin);
        vm.expectRevert(BurnEngine.SlippageOutOfBounds.selector);
        engine.setMaxSlippageBps(0);
        vm.expectRevert(BurnEngine.SlippageOutOfBounds.selector);
        engine.setMaxSlippageBps(501);
        vm.expectEmit(false, false, false, true);
        emit IBurnEngine.MaxSlippageSet(500);
        engine.setMaxSlippageBps(500);
        assertEq(engine.maxSlippageBps(), 500);
        vm.stopPrank();

        vm.expectRevert();
        engine.setMaxSlippageBps(100); // not admin
    }

    // ─────────────────────────────────── buyback ───────────────────────────────────────

    function test_buyback_buysAndBurns100Percent() public {
        _fund(1 ether);
        uint256 supplyBefore = token.totalSupply();
        uint256 burnedBefore = token.burnedTotal();

        vm.prank(keeper);
        engine.executeBuyback(1 ether);

        uint256 burned = token.burnedTotal() - burnedBefore;
        assertGt(burned, 0, "something was burned");
        assertEq(token.totalSupply(), supplyBefore - burned, "supply down by exactly the burn");
        assertEq(token.balanceOf(address(engine)), 0, "engine keeps NO bought WORD - 100% burned");
        assertGe(token.totalSupply(), token.currentBurnFloor(), "never below the live floor");
    }

    function test_buyback_keeperTipExactAndBounded() public {
        _fund(1 ether);
        uint256 balBefore = keeper.balance;
        uint256 engineBalBefore = engine.pendingEth();

        vm.prank(keeper);
        engine.executeBuyback(1 ether);

        uint256 ethSpent = engineBalBefore - engine.pendingEth() - (keeper.balance - balBefore);
        uint256 tip = keeper.balance - balBefore;
        assertEq(tip, ethSpent * engine.TIP_BPS() / BPS, "tip = exactly 1% of ETH spent");
        // The tip plus swap cost always fit the offered budget.
        assertLe(ethSpent + tip, 1 ether, "never exceeds maxEthToSpend");
    }

    function test_buyback_tipTransferFailureReverts() public {
        _fund(1 ether);
        NoReceiveKeeper bad = new NoReceiveKeeper();
        vm.expectRevert(BurnEngine.EthTransferFailed.selector);
        bad.callBuyback(engine, 1 ether);
    }

    function test_buyback_effectivePriceWithinTolerance() public {
        _fund(1 ether);
        // Spot: 1000 WORD/ETH. Margins: 0.3% LP + 1% hook + 1% slippage.
        vm.recordLogs();
        vm.prank(keeper);
        engine.executeBuyback(1 ether);
        (, uint256 ethSpent, uint256 wordBought,) = _lastBuybackFromLogs();
        // effective WORD-per-ETH must be >= spot deflated by the three margins.
        uint256 effective = wordBought * 1e18 / ethSpent; // WORD per ETH, 1e18-scaled
        uint256 floorPrice = 1000e18 * (1e6 - uint256(LP_FEE)) / 1e6 * (BPS - 100 - 100) / BPS;
        assertGe(effective, floorPrice, "paid within tolerance of spot");
    }

    function test_buyback_rateLimitedPerBlock() public {
        _fund(2 ether);
        engine.executeBuyback(1 ether);
        vm.expectRevert(BurnEngine.BuybackRateLimited.selector);
        engine.executeBuyback(1 ether);

        vm.roll(block.number + 1);
        engine.executeBuyback(1 ether); // next block fine
    }

    function test_buyback_spendMinimumEnforced() public {
        _fund(1 ether);
        // Balance is 1 ETH (> MIN 0.1): offering less than 0.1 is a griefing-shaped call.
        vm.expectRevert(BurnEngine.SpendBelowMinimum.selector);
        engine.executeBuyback(0.05 ether);
        vm.expectRevert(BurnEngine.SpendBelowMinimum.selector);
        engine.executeBuyback(0);
    }

    function test_buyback_smallBalanceFullySpendable() public {
        _fund(0.05 ether); // balance below MIN: the whole balance is the minimum
        engine.executeBuyback(0.05 ether);
        assertLt(engine.pendingEth(), 0.05 ether, "spent");
    }

    function test_buyback_smallBalanceDustOfferStillRejected() public {
        _fund(0.05 ether);
        vm.expectRevert(BurnEngine.SpendBelowMinimum.selector);
        engine.executeBuyback(0.01 ether);
    }

    function test_buyback_emptyEngineReverts() public {
        vm.expectRevert(BurnEngine.SpendBelowMinimum.selector);
        engine.executeBuyback(1 ether);
    }

    function test_buyback_perCallSpendCapEnforced() public {
        _fund(10 ether);
        uint256 before = engine.pendingEth();
        engine.executeBuyback(type(uint256).max); // ask for everything
        uint256 spent = before - engine.pendingEth();
        assertLe(spent, engine.MAX_BUYBACK_ETH(), "hard 1 ETH per-call cap");
    }

    function test_buyback_feedsHookSkimBack() public {
        _fund(1 ether);
        uint256 hookBefore = hook.pendingFees();
        engine.executeBuyback(1 ether);
        // The buyback is itself a skimmed swap: 1% of its ETH flows back into the fee cycle.
        assertGt(hook.pendingFees(), hookBefore, "buyback pays the skim like any swap");
    }

    function test_buyback_slippageGuardRejectsOverTightTolerance() public {
        // 1 bp tolerance cannot absorb the swap's own ~0.1% impact + fees: must revert,
        // atomically (no partial fill, no burn).
        vm.prank(admin);
        engine.setMaxSlippageBps(1);
        _fund(1 ether);
        uint256 supplyBefore = token.totalSupply();
        vm.expectRevert(); // SlippageExceeded, wrapped in the unlock revert path
        engine.executeBuyback(1 ether);
        assertEq(token.totalSupply(), supplyBefore, "no partial fill");
        assertEq(engine.pendingEth(), 1 ether, "no ETH spent");
    }

    // ──────────────────────── dynamic floor: pause / resume / sweep ─────────────────────

    function test_buyback_neverOvershootsFloor_acrossMany() public {
        _preBurn(995_000e18); // burnable excess: 5,000 WORD
        _fund(20 ether);
        // Repeated capped buybacks: supply approaches the live floor monotonically and stops
        // (no excess left), then the next call reverts NoBurnableExcess.
        for (uint256 i; i < 12; i++) {
            if (token.burnableExcess() == 0) break;
            vm.roll(block.number + 1);
            engine.executeBuyback(1 ether);
            assertGe(token.totalSupply(), token.currentBurnFloor(), "never below the live floor");
        }
        assertEq(token.burnableExcess(), 0, "all current excess consumed");
        assertEq(token.totalSupply(), token.currentBurnFloor(), "rests EXACTLY on the live floor");
    }

    function test_finalBuyback_landsExactlyOnFloor_thenNoExcessReverts() public {
        _preBurn(999_500e18); // excess: 500 WORD — well within one capped buyback
        _fund(1 ether);

        vm.prank(keeper);
        engine.executeBuyback(1 ether);

        assertEq(token.totalSupply(), token.currentBurnFloor(), "exact landing on the live floor");
        assertEq(token.burnableExcess(), 0, "no excess remains");

        // No permanent retirement and no auto-sweep: leftover ETH simply waits for the next
        // unbind. A further buyback now cleanly reverts (nothing to buy).
        assertGt(engine.pendingEth(), 0, "leftover ETH retained, not swept (no retirement)");
        vm.roll(block.number + 1);
        vm.prank(keeper);
        vm.expectRevert(BurnEngine.NoBurnableExcess.selector);
        engine.executeBuyback(1 ether);
    }

    /// @dev The defining v3 behaviour: at the floor the engine pauses; an unbind that lowers
    ///      `totalAlive` (and the floor) frees new excess and the buyback RESUMES — no
    ///      permanent completion.
    function test_buyback_resumesAfterUnbindLowersFloor() public {
        // Burn down to the floor: excess 0.
        _preBurn(1_000_000e18);
        assertEq(token.burnableExcess(), 0, "at the floor");
        _fund(1 ether);
        vm.roll(block.number + 1);
        vm.expectRevert(BurnEngine.NoBurnableExcess.selector);
        engine.executeBuyback(1 ether);

        // Simulate one unbind: totalAlive 10,000 -> 9,999. Floor drops 1,000e18; supply is
        // unchanged, so 1,000e18 becomes burnable.
        bank.setTotalAlive(9_999);
        assertEq(token.burnableExcess(), 1_000e18, "unbind freed 1,000 WORD of excess");

        // Burning resumes. One 1-ETH capped buyback buys most of the freed WORD (margins
        // leave a little); a couple of capped calls drain it back to the new, lower floor.
        uint256 burnedBefore = token.burnedTotal();
        _fund(3 ether);
        for (uint256 i; i < 4 && token.burnableExcess() > 0; ++i) {
            vm.roll(block.number + 1);
            vm.prank(keeper);
            engine.executeBuyback(1 ether);
        }

        assertGt(token.burnedTotal(), burnedBefore, "burning resumed after the unbind");
        assertEq(token.burnableExcess(), 0, "freed excess fully consumed");
        assertEq(token.totalSupply(), token.currentBurnFloor(), "back at the new, lower floor");
    }

    /// @dev INT-1 regression (unit-level): with a WEI-DUST remainder, the pool's rounded-up
    ///      charge used to exceed the floor-rounded guard ceiling by 1-2 wei, stalling the
    ///      buyback. The ceiling now rounds up, so the dust buyback completes and lands the
    ///      live floor exactly. Swept across remainders 1..2000 wei to cover the rounding
    ///      lattice (each iteration on a fresh-state snapshot).
    function test_finalBuyback_completesOnWeiDustRemainder() public {
        for (uint256 dust = 1; dust <= 2_000; dust += 271) {
            uint256 snap = vm.snapshotState();

            _preBurn(1_000_000e18 - dust);
            assertEq(token.burnableExcess(), dust, "staged dust excess");
            _fund(1 ether);

            vm.roll(block.number + 1);
            vm.prank(keeper);
            engine.executeBuyback(1 ether);

            assertEq(token.totalSupply(), token.currentBurnFloor(), "dust buyback lands exactly on the floor");
            assertEq(token.burnableExcess(), 0, "dust fully consumed");

            vm.revertToState(snap);
        }
    }

    function test_sweepResidual_onlyWhenNoExcess() public {
        // While there is burnable excess, the onward-sweep is refused (use the buyback).
        _fund(0.3 ether);
        assertGt(token.burnableExcess(), 0);
        vm.expectRevert(BurnEngine.ExcessStillBurnable.selector);
        engine.sweepResidual();

        // Bring supply to the floor (excess 0); now idle ETH can be swept onward to rewards,
        // so nothing is ever stranded (the no-stranding backstop).
        _preBurn(1_000_000e18);
        assertEq(token.burnableExcess(), 0);
        uint256 rewardsBefore = rewards.received();
        uint256 bal = engine.pendingEth();
        assertGt(bal, 0);

        vm.expectEmit(false, false, false, true);
        emit BurnEngine.ResidualSwept(bal);
        engine.sweepResidual();
        assertEq(engine.pendingEth(), 0, "swept");
        assertEq(rewards.received(), rewardsBefore + bal, "residual went to the RewardsDistributor");
    }

    // ───────────────────────────── adversarial: sandwich ───────────────────────────────

    /// @dev Full sandwich simulation. The attacker frontruns the buyback (pumping spot),
    ///      lets it execute, and backruns. Asserts both documented properties:
    ///      (1) the engine's loss is bounded — its effective buy price tracks the
    ///          (manipulated) spot within LP fee + hook fee + maxSlippageBps, and the
    ///          absolute exposure is capped by the 1 ETH per-call spend cap;
    ///      (2) the attack is UNPROFITABLE — the attacker pays the 1% hook skim twice and
    ///          the LP fee twice on attack volume that must dwarf the 1 ETH buyback.
    function test_sandwich_lossBoundedAndAttackUnprofitable() public {
        _fund(1 ether);

        address attacker = makeAddr("attacker");
        vm.deal(attacker, 100 ether);
        uint256 attackerStartEth = attacker.balance;

        // ── frontrun: pump WORD ~10% with a 50 ETH buy ─────────────────────────────────
        vm.startPrank(attacker);
        BalanceDelta front = swapRouter.swap{value: 50 ether}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -50 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        uint256 attackerWord = uint256(uint128(front.amount1()));
        vm.stopPrank();

        // ── victim: the buyback executes against the manipulated pool ──────────────────
        uint256 engineBalBefore = engine.pendingEth();
        vm.recordLogs();
        engine.executeBuyback(1 ether);
        (, uint256 ethSpent, uint256 wordBought,) = _lastBuybackFromLogs();

        // (1) loss bounds: absolute exposure ≤ the per-call cap…
        assertLe(engineBalBefore - engine.pendingEth(), 1 ether, "absolute exposure capped");
        // …and the engine still paid within tolerance of the price it could observe:
        // effective price no worse than ~10% premium + margins vs the fair 1000 WORD/ETH.
        uint256 effective = wordBought * 1e18 / ethSpent;
        assertGe(effective, 850e18, "loss bounded near the manipulated premium (~10% + margins)");

        // ── backrun: attacker dumps everything bought ──────────────────────────────────
        vm.startPrank(attacker);
        token.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -int256(attackerWord), sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        vm.stopPrank();

        // (2) the sandwich lost money: double skim + double LP fee on 50 ETH of attack
        // volume (~2.6 ETH) dwarfs anything extractable from a 1 ETH buyback.
        assertLt(
            attacker.balance,
            attackerStartEth - 1 ether,
            "sandwich is decisively unprofitable (fees exceed extractable value)"
        );
    }

    /// @dev A downward manipulation (attacker dumps WORD before the buyback) only helps the
    ///      protocol: the engine buys MORE WORD per ETH. Sanity-check no revert and better
    ///      price.
    function test_sandwich_downwardManipulationOnlyHelpsTheBurn() public {
        _fund(1 ether);

        address attacker = makeAddr("attacker");
        token.transfer(attacker, 100_000e18);
        vm.startPrank(attacker);
        token.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -100_000e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        vm.stopPrank();

        vm.recordLogs();
        engine.executeBuyback(1 ether);
        (, uint256 ethSpent, uint256 wordBought,) = _lastBuybackFromLogs();
        assertGt(wordBought * 1e18 / ethSpent, 1000e18, "cheaper than fair price - more burn per ETH");
    }

    // ──────────────────────────────────── helpers ──────────────────────────────────────

    /// @dev Reads the most recent BuybackExecuted event.
    function _lastBuybackFromLogs()
        internal
        returns (address caller, uint256 ethSpent, uint256 wordBought, uint256 tip)
    {
        // Re-execute pattern is brittle; instead recompute from recorded logs.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("BuybackExecuted(address,uint256,uint256,uint256)");
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == sig) {
                caller = address(uint160(uint256(logs[i - 1].topics[1])));
                (ethSpent, wordBought, tip) = abi.decode(logs[i - 1].data, (uint256, uint256, uint256));
                return (caller, ethSpent, wordBought, tip);
            }
        }
        revert("no BuybackExecuted log");
    }
}
