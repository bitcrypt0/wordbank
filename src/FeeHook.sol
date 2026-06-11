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
import {IBurnEngine} from "./interfaces/IBurnEngine.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import {IWordToken} from "./interfaces/IWordToken.sol";

/// @title  FeeHook — Uniswap V4 hook: 1% ETH-side fee skim, launch guard, dynamic fee router
/// @notice Attached to the canonical native-ETH/WORD pool with `beforeSwap` + `afterSwap` +
///         return-delta permissions. On every swap it skims `feeBps` (launch 100 = 1%, hard
///         ceiling 200) of the ETH side — ETH in on buys, ETH out on sells — and accrues the
///         ETH in this contract. A public, permissionless `flush()` routes the accrued balance
///         with the split chosen PER FLUSH by whether burnable WORD exists (Option B):
///         **burnable excess present → three-way** (launch 50% RewardsDistributor / 25%
///         BountyEngine / 25% BurnEngine); **no excess → two-way** (default 70% rewards / 30%
///         bounty) so the burn slice folds into the holder/bounty streams rather than idling.
///         The floor is dynamic (`WordBank.totalAlive() × 1000e18`, read via
///         `IWordToken.burnableExcess()`), so excess appears whenever an unbind frees WORD and
///         is consumed as the BurnEngine buys and burns it — the split toggles between the two
///         modes over the protocol's life and never permanently "completes". Both split
///         configurations are admin-reconfigurable within hardcoded bounds and are BOTH live
///         permanently; the hook selects between them automatically.
///
///         Launch protection: all swaps revert until the one-time `enableTrading()`; for at
///         most 1 hour after it (earlier if the one-time `sunsetGuard()` fires) any single buy
///         whose WORD output exceeds 10,000e18 (1% of the 1,000,000e18 liquidity seed) reverts.
///         A pool-wide per-block buy cap was considered and DELIBERATELY REJECTED (architecture
///         §3): a fixed per-block quota is a race bots win against retail, a worse DoS than the
///         whale problem it addresses. The per-swap cap stands alone.
///
/// @dev    The hook holds NO game, token, or swap-execution logic (system invariant 8). It
///         never calls WordBank and never executes the buyback — it only takes ETH from the
///         PoolManager and forwards it. The BurnEngine runs its buyback in its own transaction.
///
///         Skim accrual strategy (agent-5 micro-decision a): ACCUMULATE + PUBLIC FLUSH. The
///         per-swap cost is a single `poolManager.take` of native ETH to this contract (~10k
///         gas); the three external `deposit()` calls (~30k+ gas and three CALLs with value)
///         are deferred to `flush()`, which anyone may call at any time, so no stream ever
///         depends on an admin and swappers never pay routing gas. Split changes flush first,
///         so fees accrued under an old split are always routed at that old split.
///
///         Skim placement: ETH is ALWAYS currency0 of the canonical pool (native ETH sorts
///         first). When ETH is the swap's SPECIFIED currency (exact-input buy, exact-output
///         sell) the fee is taken in `beforeSwap` via the specified-currency return delta and
///         the basis is |amountSpecified|. When ETH is UNSPECIFIED (exact-output buy,
///         exact-input sell) the fee is taken in `afterSwap` via the unspecified-currency
///         return delta and the basis is the pool's ETH delta. The basis is therefore always
///         "the ETH amount known at the skim point"; the two bases differ only second-order
///         (1% of 1%) and each case is exact against its own basis (tested).
///
///         Guard boundary (documented choice): a buy of EXACTLY 10,000e18 WORD passes;
///         strictly more reverts. The BurnEngine is exempt from the guard (its buyback is a
///         buy and must never brick on it — architecture §6); it is identified as the swap
///         *sender* because it swaps the PoolManager directly, not through a router.
contract FeeHook is IHooks, Ownable2Step {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    // ─────────────────────────────────── constants ─────────────────────────────────────

    /// @notice Basis-point denominator for the fee rate and all splits.
    uint256 public constant BPS = 10_000;

    /// @notice Hard ceiling on the swap fee rate (2%). The admin can tune but never exceed.
    uint16 public constant MAX_FEE_BPS = 200;

    /// @notice Launch-guard per-buy WORD output cap: 1% of the 1,000,000e18 liquidity seed.
    uint128 public constant BUY_CAP = 10_000e18;

    /// @notice Hardcoded guard auto-expiry after `enableTrading()` — the backstop that kills
    ///         the cap even if the admin key goes dark.
    uint256 public constant GUARD_DURATION = 1 hours;

    // Three-way split bounds (active while burning) — architecture NORMATIVE.
    uint16 public constant BURN_PHASE_REWARDS_MIN_BPS = 4000;
    uint16 public constant BURN_PHASE_REWARDS_MAX_BPS = 6000;
    uint16 public constant BURN_PHASE_BOUNTY_MIN_BPS = 1500;
    uint16 public constant BURN_PHASE_BOUNTY_MAX_BPS = 3500;
    uint16 public constant BURN_PHASE_BURN_MIN_BPS = 1500;
    uint16 public constant BURN_PHASE_BURN_MAX_BPS = 3500;

    // Two-way split bounds (after burn completion) — architecture NORMATIVE.
    uint16 public constant POST_BURN_REWARDS_MIN_BPS = 5000;
    uint16 public constant POST_BURN_REWARDS_MAX_BPS = 8000;
    uint16 public constant POST_BURN_BOUNTY_MIN_BPS = 2000;
    uint16 public constant POST_BURN_BOUNTY_MAX_BPS = 5000;

    // Transient-storage slot for the flush reentrancy lock. Arbitrary fixed slot; this is the
    // contract's only transient-storage use, so there is nothing to collide with.
    bytes32 private constant FLUSH_LOCK_SLOT = 0x1f3c9647dbcc7da785a80f81f6f7d09ae62fa4a54a0bcef4e2962426c87a8113;

    // ──────────────────────────────────── storage ──────────────────────────────────────

    /// @notice The Uniswap V4 PoolManager.
    IPoolManager public immutable poolManager;

    /// @notice Holder fee-share stream (50% at launch; default 70% post-burn).
    IRewardsDistributor public immutable rewardsDistributor;

    /// @notice Bounty treasury stream (25% at launch; default 30% post-burn).
    IBountyEngine public immutable bountyEngine;

    /// @notice Buy-and-burn stream — receives the burn slice only on flushes where burnable
    ///         excess exists. Never retires (the dynamic floor descends as NFTs unbind).
    IBurnEngine public immutable burnEngine;

    /// @notice The WORD token — read on each flush for `burnableExcess()`, which selects the
    ///         routing mode. ETH is currency0; WORD is currency1 of the canonical pool.
    IWordToken public immutable wordToken;

    /// @notice The canonical pool's id — the only pool this hook serves.
    PoolId public immutable canonicalPoolId;

    /// @notice Swap fee rate in bps of the ETH side (launch 100 = 1%; 1..MAX_FEE_BPS).
    uint16 public feeBps = 100;

    // ── three-way split (used on flushes where burnable excess exists) ──
    /// @notice Rewards slice of the three-way split, bps. Launch 5000. setBurnPhaseSplit.
    uint16 public rewardsBps = 5000;
    /// @notice Bounty slice of the three-way split, bps. Launch 2500. setBurnPhaseSplit.
    uint16 public bountyBps = 2500;
    /// @notice Burn slice of the three-way split, bps. Launch 2500. setBurnPhaseSplit.
    uint16 public burnBps = 2500;

    // ── two-way split (used on flushes with no burnable excess; burn slice folds in) ──
    /// @notice Rewards slice of the two-way split, bps. Default 7000. setPostBurnSplit.
    uint16 public postRewardsBps = 7000;
    /// @notice Bounty slice of the two-way split, bps. Default 3000. setPostBurnSplit.
    uint16 public postBountyBps = 3000;

    /// @notice Timestamp of the one-time `enableTrading()`; 0 while trading is gated.
    uint64 public tradingEnabledAt;

    /// @notice True once the admin has fired the one-time `sunsetGuard()`.
    bool public guardSunset;

    // ──────────────────────────────────── events ───────────────────────────────────────

    /// @notice Trading was enabled (one-time). The guard window runs from this moment.
    event TradingEnabled(uint256 timestamp);
    /// @notice The admin sunset the launch guard ahead of its 1-hour auto-expiry.
    event GuardSunset(uint256 timestamp);
    /// @notice Accrued ETH was routed. `toBurn` is 0 on flushes with no burnable excess
    ///         (two-way mode); positive when excess exists (three-way mode).
    event Flushed(address indexed caller, uint256 toRewards, uint256 toBounty, uint256 toBurn);
    /// @notice A swap was skimmed. `ethSpecified` tells which basis applied (see contract @dev).
    event FeeSkimmed(PoolId indexed poolId, uint256 ethAmount, bool ethSpecified);
    /// @notice Admin changed the fee rate.
    event FeeBpsSet(uint16 feeBps);
    /// @notice Admin changed the three-way (excess) split.
    event BurnPhaseSplitSet(uint16 rewardsBps, uint16 bountyBps, uint16 burnBps);
    /// @notice Admin changed the two-way (no-excess) split.
    event PostBurnSplitSet(uint16 rewardsBps, uint16 bountyBps);

    // ──────────────────────────────────── errors ───────────────────────────────────────

    /// @notice Caller is not the PoolManager.
    error NotPoolManager();
    /// @notice This hook only serves the canonical ETH/WORD pool.
    error NotCanonicalPool();
    /// @notice A hook callback this contract does not use was invoked.
    error HookNotImplemented();
    /// @notice Swaps are gated until the one-time enableTrading().
    error TradingNotEnabled();
    /// @notice Trading was already enabled (enableTrading is one-time).
    error TradingAlreadyEnabled();
    /// @notice The guard was already sunset (sunsetGuard is one-time).
    error GuardAlreadySunset();
    /// @notice Launch guard: a single buy's WORD output exceeded BUY_CAP.
    error BuyExceedsLaunchCap(uint256 wordOut);
    /// @notice Fee rate outside (0, MAX_FEE_BPS].
    error FeeOutOfBounds();
    /// @notice Split shares outside their hardcoded bounds or not summing to 100%.
    error SplitOutOfBounds();
    /// @notice Reentrant flush.
    error FlushReentered();
    /// @notice Zero address where a real address is required.
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
    /// @param rewards      The RewardsDistributor.
    /// @param bounty       The BountyEngine.
    /// @param burn         The BurnEngine.
    /// @param admin        The protocol admin (bounded powers only — invariant 7).
    constructor(
        IPoolManager manager,
        address word,
        uint24 lpFee,
        int24 tickSpacing,
        IRewardsDistributor rewards,
        IBountyEngine bounty,
        IBurnEngine burn,
        address admin
    ) Ownable(admin) {
        if (
            address(manager) == address(0) || word == address(0) || address(rewards) == address(0)
                || address(bounty) == address(0) || address(burn) == address(0)
        ) revert ZeroAddress();

        poolManager = manager;
        rewardsDistributor = rewards;
        bountyEngine = bounty;
        burnEngine = burn;
        wordToken = IWordToken(word);

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

    /// @notice Receives the skimmed ETH from `poolManager.take`. Donations are accepted too —
    ///         anything here is protocol revenue at the next flush.
    receive() external payable {}

    // ────────────────────────────── swap-path callbacks ────────────────────────────────

    /// @inheritdoc IHooks
    /// @dev Gate check, canonical-pool check, and the ETH-specified skim (exact-input buys,
    ///      exact-output sells). Fee basis: |amountSpecified|.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(canonicalPoolId)) revert NotCanonicalPool();
        if (tradingEnabledAt == 0) revert TradingNotEnabled();

        // Specified currency is currency0 (= ETH) iff exact-input direction matches zeroForOne.
        bool ethSpecified = (params.amountSpecified < 0) == params.zeroForOne;
        if (!ethSpecified) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 ethAmount =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = ethAmount * feeBps / BPS;
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // Take the fee now; the positive specified-currency return delta charges it to the swap.
        poolManager.take(key.currency0, address(this), fee);
        emit FeeSkimmed(canonicalPoolId, fee, true);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Launch-guard post-check on buys, and the ETH-unspecified skim (exact-output buys,
    ///      exact-input sells). Fee basis: the pool's ETH delta for this swap.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        // Anti-whale guard: buys only (zeroForOne = ETH in, WORD out). delta.amount1() is
        // exactly the WORD credited to the swapper — the skim never touches the WORD side.
        // Boundary: exactly BUY_CAP passes, strictly more reverts. BurnEngine exempt.
        if (params.zeroForOne && sender != address(burnEngine) && guardActive()) {
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

    /// @notice Routes this contract's entire ETH balance, choosing the split PER FLUSH from
    ///         live burnable excess. Permissionless by design — no fee stream ever depends on
    ///         an admin. **Burnable excess present** → three-way rewards/bounty/burn
    ///         (remainder-to-burn). **No excess** → two-way rewards/bounty (remainder-to-bounty),
    ///         and the BurnEngine receives nothing — the burn slice folds into the holder and
    ///         bounty streams so no fee ever idles waiting for a burn that cannot happen yet.
    ///         The selection is automatic and reversible: excess reappears whenever an unbind
    ///         lowers the floor, so the hook flips back to three-way on the next flush.
    /// @dev    `wordToken.burnableExcess()` reads `totalSupply − WordBank.totalAlive()×1000e18`.
    ///         A view-only external read inside the reentrancy-locked flush; the recipients are
    ///         trusted protocol contracts. In both modes the slices sum to exactly 100% of the
    ///         routed balance (the last slice takes the integer-division remainder).
    function flush() public {
        // Transient reentrancy lock: recipients are trusted protocol contracts, but a
        // reentrant flush would mis-split the precomputed slices, so it is excluded outright.
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
            uint256 toRewards;
            uint256 toBounty;
            uint256 toBurn;
            if (wordToken.burnableExcess() > 0) {
                // Three-way: there is WORD to buy and burn.
                toRewards = balance * rewardsBps / BPS;
                toBounty = balance * bountyBps / BPS;
                toBurn = balance - toRewards - toBounty; // remainder → burn
            } else {
                // Two-way: nothing burnable — fold the burn slice into rewards/bounty.
                toRewards = balance * postRewardsBps / BPS;
                toBounty = balance - toRewards; // remainder → bounty
            }

            if (toRewards != 0) rewardsDistributor.deposit{value: toRewards}();
            if (toBounty != 0) bountyEngine.deposit{value: toBounty}();
            if (toBurn != 0) burnEngine.deposit{value: toBurn}();
            emit Flushed(msg.sender, toRewards, toBounty, toBurn);
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

    /// @notice One-time trading enable. Records `tradingEnabledAt` — the anchor for the
    ///         guard's 1-hour auto-expiry. Not re-disableable, not re-callable.
    function enableTrading() external onlyOwner {
        if (tradingEnabledAt != 0) revert TradingAlreadyEnabled();
        tradingEnabledAt = uint64(block.timestamp);
        emit TradingEnabled(block.timestamp);
    }

    /// @notice One-time, admin-only early end to the launch guard. Irreversible; the
    ///         1-hour auto-expiry stands regardless, so the guard dies even if this is
    ///         never called.
    function sunsetGuard() external onlyOwner {
        if (tradingEnabledAt == 0) revert TradingNotEnabled();
        if (guardSunset) revert GuardAlreadySunset();
        guardSunset = true;
        emit GuardSunset(block.timestamp);
    }

    /// @notice True while the anti-whale buy cap is enforced: trading enabled, not sunset,
    ///         and within 1 hour of `tradingEnabledAt`.
    function guardActive() public view returns (bool) {
        return tradingEnabledAt != 0 && !guardSunset && block.timestamp < uint256(tradingEnabledAt) + GUARD_DURATION;
    }

    // ──────────────────────────────── bounded admin ────────────────────────────────────

    /// @notice Sets the fee rate. Bounded (0, MAX_FEE_BPS] — the admin can tune within the
    ///         2% ceiling but can neither exceed it nor zero the streams out entirely.
    /// @dev    Flushes first so fees accrued at the old rate/split are routed before the
    ///         change takes effect.
    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps == 0 || newFeeBps > MAX_FEE_BPS) revert FeeOutOfBounds();
        flush();
        feeBps = newFeeBps;
        emit FeeBpsSet(newFeeBps);
    }

    /// @notice Sets the three-way (burnable-excess) split. Bounds: rewards 4000–6000, bounty
    ///         1500–3500, burn 1500–3500, sum exactly 10000. Permanently live — applied on any
    ///         flush where burnable excess exists.
    /// @dev    Flushes first so pending fees route at the old configuration.
    function setBurnPhaseSplit(uint16 newRewardsBps, uint16 newBountyBps, uint16 newBurnBps) external onlyOwner {
        flush();
        if (
            newRewardsBps < BURN_PHASE_REWARDS_MIN_BPS || newRewardsBps > BURN_PHASE_REWARDS_MAX_BPS
                || newBountyBps < BURN_PHASE_BOUNTY_MIN_BPS || newBountyBps > BURN_PHASE_BOUNTY_MAX_BPS
                || newBurnBps < BURN_PHASE_BURN_MIN_BPS || newBurnBps > BURN_PHASE_BURN_MAX_BPS
                || uint256(newRewardsBps) + newBountyBps + newBurnBps != BPS
        ) revert SplitOutOfBounds();
        rewardsBps = newRewardsBps;
        bountyBps = newBountyBps;
        burnBps = newBurnBps;
        emit BurnPhaseSplitSet(newRewardsBps, newBountyBps, newBurnBps);
    }

    /// @notice Sets the two-way (no-excess) split. Bounds: rewards 5000–8000, bounty 2000–5000,
    ///         sum exactly 10000. Permanently live — applied on any flush with no burnable
    ///         excess (the burn slice folds into these two streams).
    /// @dev    Flushes first so pending fees route at the old configuration.
    function setPostBurnSplit(uint16 newRewardsBps, uint16 newBountyBps) external onlyOwner {
        flush();
        if (
            newRewardsBps < POST_BURN_REWARDS_MIN_BPS || newRewardsBps > POST_BURN_REWARDS_MAX_BPS
                || newBountyBps < POST_BURN_BOUNTY_MIN_BPS || newBountyBps > POST_BURN_BOUNTY_MAX_BPS
                || uint256(newRewardsBps) + newBountyBps != BPS
        ) revert SplitOutOfBounds();
        postRewardsBps = newRewardsBps;
        postBountyBps = newBountyBps;
        emit PostBurnSplitSet(newRewardsBps, newBountyBps);
    }

    // ───────────────────────────── unused hook callbacks ───────────────────────────────
    // No permission flags are set for these; the PoolManager never calls them. They revert
    // so a misconfigured external caller fails loudly.

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
