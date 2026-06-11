// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {BurnEngine} from "../src/BurnEngine.sol";
import {FeeHook} from "../src/FeeHook.sol";

/// @title  Phase 2c — enable trading on the FeeHook
/// @notice Carved out of 02_SeedPoolAndLaunch by the 2026-06-16 change order so the owner
///         controls WHEN the market opens. Run AFTER 02 (and, recommended, after
///         04_LockLiquidity so liquidity is provably locked the moment people can trade).
///
///         Does ONLY the old step 7: feeHook.enableTrading(). One-way — no off switch. From
///         this moment swaps work; the guard dies at the earlier of sunsetGuard() or +1 hour.
///
///         HONEYPOT WINDOW: until this runs the pool exists but swaps are gated, so scanners
///         report "cannot buy/sell" — do NOT announce the token/pool address until AFTER this.
///
///         SANITY CHECKS before flipping (clear revert if 02 wasn't run): the pool must be
///         initialized and burnEngine.poolSet() must be true.
///
///         IDEMPOTENT: if feeHook.tradingEnabledAt() != 0 it logs "already live" and no-ops.
///
///         Required env:
///           WORD_TOKEN, FEE_HOOK, BURN_ENGINE, POOL_MANAGER
///         Optional env (defaults):
///           LP_FEE (3000), TICK_SPACING (60)
contract EnableTrading is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function run() external {
        FeeHook feeHook = FeeHook(payable(vm.envAddress("FEE_HOOK")));
        BurnEngine burnEngine = BurnEngine(payable(vm.envAddress("BURN_ENGINE")));
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address wordToken = vm.envAddress("WORD_TOKEN");
        uint24 lpFee = uint24(vm.envOr("LP_FEE", uint256(3000)));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));

        // Idempotent: nothing to do if trading is already live.
        if (feeHook.tradingEnabledAt() != 0) {
            console2.log("enableTrading: trading already live - skip");
            return;
        }

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(wordToken),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(feeHook))
        });

        // Sanity-check the seed ran: pool initialized + BurnEngine wired. Clear errors beat a
        // deep revert if 02_SeedPoolAndLaunch hasn't been run yet.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        require(sqrtPriceX96 != 0, "pool not initialized - run 02_SeedPoolAndLaunch (Phase 2a) first");
        require(burnEngine.poolSet(), "BurnEngine pool not set - run 02_SeedPoolAndLaunch (Phase 2a) first");

        vm.startBroadcast();
        feeHook.enableTrading();
        vm.stopBroadcast();

        console2.log("Phase 2c complete - TRADING IS LIVE.");
        console2.log("Guard rejects single buys > 10,000 WORD; it dies at the earlier of sunsetGuard()");
        console2.log("or +1 hour. The 1% fee skim is live (50% holders / 25% bounty / 25% burn).");
        console2.log("Anyone can now call FeeHook.flush(). NOTE: executeBuyback only activates at");
        console2.log("Phase 3 (the seal) - keepers calling it earlier just waste gas.");
    }
}
