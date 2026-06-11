// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {BurnEngine} from "../src/BurnEngine.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {WordToken} from "../src/WordToken.sol";

/// @dev Canonical Permit2 (same address on every chain). PositionManager pulls ERC-20s
///      through it.
interface IPermit2Like {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @title  Phase 2a — mint liquidity WORD and seed the canonical pool (SEEDING ONLY)
/// @notice As of the 2026-06-16 change order, locking the position and enabling trading are
///         carved out into separate owner-paced manual scripts so the owner controls timing:
///           • 04_LockLiquidity.s.sol  — lock the position in the LPLocker
///           • 05_EnableTrading.s.sol  — flip the trading switch
///         This script stops after the pool is seeded and wired into the BurnEngine. Trading
///         stays OFF and the position NFT sits UNlocked in the admin wallet until those run.
///
///         RESUMABLE: each step reads on-chain state and is skipped if already done, so a
///         re-run after a revert/crash safely continues without re-minting liquidity,
///         re-minting a position, or double-spending.
///
///         NOTE on resuming a fresh position: unlike the Hardhat mirror, a forge script keeps
///         no addresses ledger — so if a prior run MINTED a position, a re-run MUST be given
///         `POSITION_TOKEN_ID` (printed by the prior run) or it would mint a second position.
///         (04_LockLiquidity then takes the same `POSITION_TOKEN_ID` to lock it.)
///
///         Required env:
///           WORD_TOKEN, FEE_HOOK, BURN_ENGINE, POOL_MANAGER, POSITION_MANAGER
///           ADMIN            protocol admin (broadcaster; receives the position)
///           SQRT_PRICE_X96   launch price (owner decision; see runbook for derivation)
///           ETH_LIQUIDITY    ETH side of the seed, in wei
///         Optional env (defaults):
///           WORD_LIQUIDITY     (1,000,000e18 — the full allotment)
///           LP_FEE (3000), TICK_SPACING (60)
///           POSITION_TOKEN_ID  (resume/recovery: adopt this existing position, skip minting)
///           PERMIT2            (0x000000000022D473030F116dDEE9F6B43aC78BA3)
contract SeedPoolAndLaunch is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    struct Launch {
        WordToken wordToken;
        FeeHook feeHook;
        BurnEngine burnEngine;
        IPoolManager poolManager;
        IPositionManager posm;
        address admin;
        uint160 sqrtPriceX96;
        uint256 ethLiquidity;
        uint256 wordLiquidity;
        uint24 lpFee;
        int24 tickSpacing;
        address permit2;
        uint256 positionOverride;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 tokenId;
    }

    function run() external {
        Launch memory l = _readConfig();

        l.key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(l.wordToken)),
            fee: l.lpFee,
            tickSpacing: l.tickSpacing,
            hooks: IHooks(address(l.feeHook))
        });

        // Full range, aligned to tick spacing.
        l.tickLower = (TickMath.MIN_TICK / l.tickSpacing) * l.tickSpacing;
        l.tickUpper = (TickMath.MAX_TICK / l.tickSpacing) * l.tickSpacing;
        l.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            l.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(l.tickLower),
            TickMath.getSqrtPriceAtTick(l.tickUpper),
            l.ethLiquidity,
            l.wordLiquidity
        );

        vm.startBroadcast();

        // 1. Mint the liquidity allotment (≤ 1,000,000e18, enforced by the token). Skip if done.
        if (l.wordToken.liquidityMinted() >= l.wordLiquidity) {
            console2.log("step 1 mintLiquidity: already done - skip");
        } else {
            l.wordToken.mintLiquidity(l.admin, l.wordLiquidity);
        }

        // 2. Approvals: WORD -> Permit2 -> PositionManager. Idempotent (allowance-checked).
        if (l.wordToken.allowance(l.admin, l.permit2) < l.wordLiquidity) {
            l.wordToken.approve(l.permit2, type(uint256).max);
        } else {
            console2.log("step 2a WORD->Permit2 approval: already done - skip");
        }
        (uint160 p2amount, uint48 p2exp,) =
            IPermit2Like(l.permit2).allowance(l.admin, address(l.wordToken), address(l.posm));
        if (p2amount >= l.wordLiquidity && p2exp > block.timestamp) {
            console2.log("step 2b Permit2->POSM approval: already done - skip");
        } else {
            IPermit2Like(l.permit2).approve(address(l.wordToken), address(l.posm), type(uint160).max, type(uint48).max);
        }

        // 3. Initialize the canonical pool (swaps stay gated until enableTrading). Skip if the
        //    pool already has a non-zero price (read slot0 via StateLibrary/extsload).
        (uint160 existingSqrtPrice,,,) = l.poolManager.getSlot0(l.key.toId());
        if (existingSqrtPrice != 0) {
            console2.log("step 3 initialize pool: already done - skip");
        } else {
            l.poolManager.initialize(l.key, l.sqrtPriceX96);
        }

        // 4. Position: use POSITION_TOKEN_ID if supplied (resume/recovery), else mint a fresh
        //    one and log the id (note it for any future resume — forge keeps no ledger).
        if (l.positionOverride != 0) {
            l.tokenId = l.positionOverride;
            console2.log("step 4 position: using POSITION_TOKEN_ID override - skip mint:", l.tokenId);
        } else {
            _mintPosition(l);
            l.tokenId = l.posm.nextTokenId() - 1;
            console2.log("step 4 position MINTED - RECORD this tokenId for any resume:", l.tokenId);
        }

        // 5. Wire the pool into the BurnEngine (one-time). Pool wiring, not lock/trade
        //    activation — needs the pool initialized, so it belongs here. Skip if already set.
        //    (The old step-5 LPLocker lock + step-7 enableTrading were carved out into the
        //    separate 04_LockLiquidity / 05_EnableTrading scripts per the 2026-06-16 change order.)
        if (l.burnEngine.poolSet()) {
            console2.log("step 5 setPool: already done - skip");
        } else {
            l.burnEngine.setPool(l.key);
            console2.log("step 5 setPool: BurnEngine pointed at the pool");
        }

        vm.stopBroadcast();

        console2.log("Phase 2a complete - pool SEEDED. Trading is OFF and the position is UNlocked.");
        console2.log("Position tokenId:", l.tokenId);
        console2.log("TWO MANUAL STEPS REMAIN (recommended order: lock, then trading):");
        console2.log("  forge script script/04_LockLiquidity.s.sol  (npm run lock-liquidity)");
        console2.log("  forge script script/05_EnableTrading.s.sol  (npm run enable-trading)");
        console2.log("Do NOT announce the token/pool until AFTER enable-trading; do NOT publish");
        console2.log("the LPLocker claim until AFTER lock. Pass POSITION_TOKEN_ID to 04 to lock this id.");
    }

    function _readConfig() internal view returns (Launch memory l) {
        l.wordToken = WordToken(vm.envAddress("WORD_TOKEN"));
        l.feeHook = FeeHook(payable(vm.envAddress("FEE_HOOK")));
        l.burnEngine = BurnEngine(payable(vm.envAddress("BURN_ENGINE")));
        l.poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        l.posm = IPositionManager(vm.envAddress("POSITION_MANAGER"));
        l.admin = vm.envAddress("ADMIN");
        l.sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));
        l.ethLiquidity = vm.envUint("ETH_LIQUIDITY");
        l.wordLiquidity = vm.envOr("WORD_LIQUIDITY", uint256(1_000_000e18));
        l.lpFee = uint24(vm.envOr("LP_FEE", uint256(3000)));
        l.tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        l.permit2 = vm.envOr("PERMIT2", 0x000000000022D473030F116dDEE9F6B43aC78BA3);
        l.positionOverride = vm.envOr("POSITION_TOKEN_ID", uint256(0));
    }

    function _mintPosition(Launch memory l) internal {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            l.key,
            l.tickLower,
            l.tickUpper,
            uint256(l.liquidity),
            uint128(l.ethLiquidity),
            uint128(l.wordLiquidity),
            l.admin,
            bytes("")
        );
        params[1] = abi.encode(l.key.currency0, l.key.currency1);
        params[2] = abi.encode(l.key.currency0, l.admin);
        l.posm.modifyLiquidities{value: l.ethLiquidity}(abi.encode(actions, params), block.timestamp + 600);
    }
}
