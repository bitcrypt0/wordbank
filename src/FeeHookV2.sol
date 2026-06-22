// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IBountyEngine} from "./interfaces/IBountyEngine.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import {IWordStaking} from "./interfaces/IWordStaking.sol";

/// @title  FeeHookV2 — Uniswap V4 hook: 1% ETH-side fee, FIXED 25/25/50 router (relaunch)
/// @author WORDBANK — https://wordbank.fun
/// @notice Attached to the relaunch ETH/WORD pool. On every swap it skims `feeBps` (launch
///         100 = 1%, hard ceiling 200) of the ETH side — ETH in on buys, ETH out on sells —
///         and accrues it here. A public, permissionless `flush()` routes the whole balance on
///         a PERMANENT, HARDCODED split:
///           • 25% → RewardsDistributor  (the NFT holders' fee stream)
///           • 25% → BountyEngine        (the daily-game treasury)
///           • 50% → WordStaking         (the WORD stakers' fee stream)
///         "NFT side" (Rewards + Bounty) and "token side" (Staking) each take half. The split
///         is NOT adjustable — there is no setter — so the relaunch carries no admin lever over
///         where revenue goes. Only the fee RATE is tunable (bounded ≤2%).
///
/// @dev    Versus the original FeeHook this drops the buy-and-burn entirely: no BurnEngine, no
///         `burnableExcess` mode toggle (the relaunch WORD is standalone, with no backing floor
///         to defend). The skim mechanics are otherwise identical and the fee is ALWAYS taken in
///         ETH (currency0), so every recipient is funded in ETH with no swapping.
///
///         Skim placement (unchanged): ETH is currency0 (native ETH sorts first). When ETH is
///         the swap's SPECIFIED currency (exact-input buy, exact-output sell) the fee is taken in
///         `beforeSwap` via the specified-currency return delta (basis |amountSpecified|). When
///         ETH is UNSPECIFIED (exact-output buy, exact-input sell) it is taken in `afterSwap` via
///         the unspecified-currency return delta (basis: the pool's ETH delta).
///
///         Launch protection: swaps revert until the one-time `enableTrading()`; for ≤1 hour
///         after it (earlier if `sunsetGuard()` fires) any single buy whose WORD output exceeds
///         BUY_CAP (1% of the 1,000,000e18 seed) reverts. There is no buyback contract to exempt.
contract FeeHookV2 is IHooks, Ownable2Step {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    // ─────────────────────────────────── constants ─────────────────────────────────────

    /// @notice Basis-point denominator for the fee rate and the split.
    uint256 public constant BPS = 10_000;

    /// @notice Hard ceiling on the swap fee rate (2%). The admin can tune but never exceed.
    uint16 public constant MAX_FEE_BPS = 200;

    /// @notice Permanent, hardcoded fee split — NFT side (Rewards + Bounty) and token side
    ///         (Staking) each take half; within the NFT side Rewards and Bounty are equal.
    uint16 public constant REWARDS_BPS = 2500; // 25% → RewardsDistributor
    uint16 public constant BOUNTY_BPS = 2500; //  25% → BountyEngine
    uint16 public constant STAKING_BPS = 5000; // 50% → WordStaking

    /// @notice Launch-guard per-buy WORD output cap: 1% of the 1,000,000e18 liquidity seed.
    uint128 public constant BUY_CAP = 10_000e18;

    /// @notice Hardcoded guard auto-expiry after `enableTrading()` — kills the cap even if the
    ///         admin key goes dark.
    uint256 public constant GUARD_DURATION = 1 hours;

    /// @dev Transient-storage slot for the flush reentrancy lock (the only transient use here).
    bytes32 private constant FLUSH_LOCK_SLOT = 0x1f3c9647dbcc7da785a80f81f6f7d09ae62fa4a54a0bcef4e2962426c87a8113;

    // ──────────────────────────────────── storage ──────────────────────────────────────

    /// @notice The Uniswap V4 PoolManager.
    IPoolManager public immutable poolManager;

    /// @notice NFT-side stream #1 — 25% (the existing, reused RewardsDistributor).
    IRewardsDistributor public immutable rewardsDistributor;

    /// @notice NFT-side stream #2 — 25% (the existing, reused BountyEngine).
    IBountyEngine public immutable bountyEngine;

    /// @notice Token-side stream — 50% (the new WordStaking).
    IWordStaking public immutable wordStaking;

    /// @notice The canonical pool's id — the only pool this hook serves.
    PoolId public immutable canonicalPoolId;

    /// @notice Swap fee rate in bps of the ETH side (launch 100 = 1%; 1..MAX_FEE_BPS).
    uint16 public feeBps = 100;

    /// @notice Timestamp of the one-time `enableTrading()`; 0 while trading is gated.
    uint64 public tradingEnabledAt;

    /// @notice True once the admin has fired the one-time `sunsetGuard()`.
    bool public guardSunset;

    // ──────────────────────────────────── events ───────────────────────────────────────

    event TradingEnabled(uint256 timestamp);
    event GuardSunset(uint256 timestamp);
    /// @notice Accrued ETH was routed on the fixed split.
    event Flushed(address indexed caller, uint256 toRewards, uint256 toBounty, uint256 toStaking);
    event FeeSkimmed(PoolId indexed poolId, uint256 ethAmount, bool ethSpecified);
    event FeeBpsSet(uint16 feeBps);

    // ──────────────────────────────────── errors ───────────────────────────────────────

    error NotPoolManager();
    error NotCanonicalPool();
    error HookNotImplemented();
    error TradingNotEnabled();
    error TradingAlreadyEnabled();
    error GuardAlreadySunset();
    error BuyExceedsLaunchCap(uint256 wordOut);
    error FeeOutOfBounds();
    error FlushReentered();
    error ZeroAddress();

    // ──────────────────────────────────── modifiers ────────────────────────────────────

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ───────────────────────────────── construction ────────────────────────────────────

    /// @param manager      The V4 PoolManager.
    /// @param word         The WORD token (currency1 of the canonical pool; ETH is currency0).
    /// @param lpFee        The canonical pool's LP fee (pips), part of its PoolKey.
    /// @param tickSpacing  The canonical pool's tick spacing, part of its PoolKey.
    /// @param rewards      The (reused) RewardsDistributor.
    /// @param bounty       The (reused) BountyEngine.
    /// @param staking      The new WordStaking.
    /// @param admin        The protocol admin (fee-rate + launch lifecycle only).
    constructor(
        IPoolManager manager,
        address word,
        uint24 lpFee,
        int24 tickSpacing,
        IRewardsDistributor rewards,
        IBountyEngine bounty,
        IWordStaking staking,
        address admin
    ) Ownable(admin) {
        if (
            address(manager) == address(0) || word == address(0) || address(rewards) == address(0)
                || address(bounty) == address(0) || address(staking) == address(0)
        ) revert ZeroAddress();

        poolManager = manager;
        rewardsDistributor = rewards;
        bountyEngine = bounty;
        wordStaking = staking;

        canonicalPoolId = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(word),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        }).toId();

        // The deployed address must encode exactly our four permission flags (CREATE2-mined).
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    /// @notice Receives skimmed ETH from `poolManager.take`. Donations are accepted too —
    ///         anything here is protocol revenue at the next flush.
    receive() external payable {}

    // ────────────────────────────── swap-path callbacks ────────────────────────────────

    /// @inheritdoc IHooks
    /// @dev Gate + canonical-pool check + the ETH-specified skim. Fee basis: |amountSpecified|.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(canonicalPoolId)) revert NotCanonicalPool();
        if (tradingEnabledAt == 0) revert TradingNotEnabled();

        bool ethSpecified = (params.amountSpecified < 0) == params.zeroForOne;
        if (!ethSpecified) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 ethAmount =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = ethAmount * feeBps / BPS;
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        poolManager.take(key.currency0, address(this), fee);
        emit FeeSkimmed(canonicalPoolId, fee, true);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Launch-guard post-check on buys + the ETH-unspecified skim. Fee basis: ETH delta.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        // Anti-whale guard: buys only (zeroForOne = ETH in, WORD out). amount1() is the WORD
        // credited to the swapper. Boundary: exactly BUY_CAP passes, strictly more reverts.
        if (params.zeroForOne && guardActive()) {
            int128 wordOut = delta.amount1();
            if (wordOut > 0 && uint128(wordOut) > BUY_CAP) revert BuyExceedsLaunchCap(uint128(wordOut));
        }

        bool ethSpecified = (params.amountSpecified < 0) == params.zeroForOne;
        if (ethSpecified) return (IHooks.afterSwap.selector, 0);

        int128 ethDelta = delta.amount0();
        uint256 ethAmount = ethDelta < 0 ? uint256(uint128(-ethDelta)) : uint256(uint128(ethDelta));
        uint256 fee = ethAmount * feeBps / BPS;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        poolManager.take(key.currency0, address(this), fee);
        emit FeeSkimmed(canonicalPoolId, fee, false);
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    // ─────────────────────────────────── routing ───────────────────────────────────────

    /// @notice Routes this contract's entire ETH balance on the fixed 25/25/50 split.
    ///         Permissionless — no fee stream ever depends on an admin. The staking slice takes
    ///         the integer-division remainder so the three slices sum to exactly the balance.
    function flush() public {
        bool locked;
        assembly ("memory-safe") {
            locked := tload(FLUSH_LOCK_SLOT)
        }
        if (locked) revert FlushReentered();
        assembly ("memory-safe") {
            tstore(FLUSH_LOCK_SLOT, 1)
        }

        uint256 balance = address(this).balance;
        if (balance != 0) {
            uint256 toRewards = balance * REWARDS_BPS / BPS;
            uint256 toBounty = balance * BOUNTY_BPS / BPS;
            uint256 toStaking = balance - toRewards - toBounty; // remainder → staking (the 50%)

            if (toRewards != 0) rewardsDistributor.deposit{value: toRewards}();
            if (toBounty != 0) bountyEngine.deposit{value: toBounty}();
            if (toStaking != 0) wordStaking.deposit{value: toStaking}();
            emit Flushed(msg.sender, toRewards, toBounty, toStaking);
        }

        assembly ("memory-safe") {
            tstore(FLUSH_LOCK_SLOT, 0)
        }
    }

    /// @notice ETH accrued and not yet flushed.
    function pendingFees() external view returns (uint256) {
        return address(this).balance;
    }

    // ─────────────────────────────── launch lifecycle ──────────────────────────────────

    /// @notice One-time trading enable. Anchors the guard's 1-hour auto-expiry.
    function enableTrading() external onlyOwner {
        if (tradingEnabledAt != 0) revert TradingAlreadyEnabled();
        tradingEnabledAt = uint64(block.timestamp);
        emit TradingEnabled(block.timestamp);
    }

    /// @notice One-time, admin-only early end to the launch guard. The 1-hour auto-expiry
    ///         stands regardless, so the guard dies even if this is never called.
    function sunsetGuard() external onlyOwner {
        if (tradingEnabledAt == 0) revert TradingNotEnabled();
        if (guardSunset) revert GuardAlreadySunset();
        guardSunset = true;
        emit GuardSunset(block.timestamp);
    }

    /// @notice True while the anti-whale buy cap is enforced.
    function guardActive() public view returns (bool) {
        return tradingEnabledAt != 0 && !guardSunset && block.timestamp < uint256(tradingEnabledAt) + GUARD_DURATION;
    }

    // ──────────────────────────────── bounded admin ────────────────────────────────────

    /// @notice Sets the fee rate within (0, MAX_FEE_BPS]. The SPLIT is not adjustable — only the
    ///         rate. Flushes first so fees accrued at the old rate route before the change.
    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps == 0 || newFeeBps > MAX_FEE_BPS) revert FeeOutOfBounds();
        flush();
        feeBps = newFeeBps;
        emit FeeBpsSet(newFeeBps);
    }

    // ───────────────────────────── unused hook callbacks ───────────────────────────────
    // No permission flags set for these; the PoolManager never calls them. They revert so a
    // misconfigured external caller fails loudly.

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
