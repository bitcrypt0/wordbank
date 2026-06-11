// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IBurnEngine} from "./interfaces/IBurnEngine.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import {IWordToken} from "./interfaces/IWordToken.sol";

/// @dev Minimal view of the FeeHook (avoids a circular import — the FeeHook imports
///      IBurnEngine). `feeBps` sizes buybacks against the live skim rather than the ceiling;
///      `burnEngine` and `canonicalPoolId` let `setPool` prove the supplied key is OUR hook's
///      canonical pool (overseer review R-1).
interface IFeeHookView {
    function feeBps() external view returns (uint16);
    function burnEngine() external view returns (address);
    function canonicalPoolId() external view returns (PoolId);
}

/// @title  BurnEngine — buy-and-burn down to the DYNAMIC backing floor
/// @notice The third fee destination. Accrues the burn slice of the FeeHook's skim (25% at
///         launch) as ETH and exposes a permissionless `executeBuyback()` that buys WORD on
///         the canonical pool and burns 100% of it via `WordToken.burn`, which is floored at
///         the LIVE backing requirement `WordBank.totalAlive() × 1000e18` (read by WordToken).
///         The burnable amount is `WordToken.burnableExcess()` = `totalSupply − currentBurnFloor`.
///         There is NO permanent completion: when supply has caught the floor, `executeBuyback`
///         cleanly reverts (nothing to buy) and RESUMES automatically once a later unbind lowers
///         the floor and frees that NFT's released 1,000 WORD into burnable excess. Holds no
///         NFT, bounty, or rewards logic (system invariant 9).
///
/// @dev    THE BUYBACK ALWAYS RUNS IN ITS OWN TRANSACTION. The FeeHook only routes ETH here;
///         this contract opens its own `poolManager.unlock` and swaps inside its own callback.
///         It is never invoked from within another swap's hook callbacks — re-entering the
///         PoolManager mid-settlement is the canonical V4 hook exploit pattern and is
///         structurally excluded by this separation (architecture §6).
///
///         ## Dynamic floor read path (read me, agent 7)
///         `executeBuyback` sizes against `WordToken.burnableExcess()`, which WordToken derives
///         live as `totalSupply − WordBank.totalAlive() × 1000e18`. So a buyback's size depends
///         on `WordBank.totalAlive()` at call time. This is a VIEW read inside the engine's own
///         tx (no reentrancy: the engine calls WordToken/WordBank views, never the other way),
///         and `WordToken.burn` re-checks the same floor atomically — the engine's sizing is an
///         optimisation, the token's check is the guarantee. An unbind that lowers `totalAlive`
///         between sizing and burn only makes more burnable (never less mid-call: `totalAlive`
///         cannot rise post-seal), so the engine can never overshoot the floor.
///
///         ## Why exact-output swaps
///         `WordToken.burn` reverts above `burnableExcess()`. An exact-input buyback can only
///         approach the floor asymptotically; an exact-output buyback of
///         `min(sized target, burnableExcess())` can never overshoot by construction and lands
///         supply exactly on the floor on the call that consumes the last of the current excess.
///
///         ## MEV surface and defenses (read me, agent 7)
///         The frozen `IBurnEngine` takes only `maxEthToSpend` — no caller min-out — so the
///         defense is layered:
///         1. SLIPPAGE GUARD: the ETH actually paid must not exceed the spot-price cost of the
///            target (read from the pool in this same transaction, immediately before the
///            swap) grossed up by the LP fee, the hook fee, and `maxSlippageBps` (default 100,
///            hardcoded ceiling MAX_SLIPPAGE_BPS = 500 — the admin can tighten or modestly
///            loosen but can never open a free sandwich). This caps the engine's own price
///            impact and any intra-transaction interference.
///         2. An in-transaction spot reference CANNOT see manipulation that happened before
///            the transaction (a sandwich frontrun inflates the very spot we read). That
///            residual exposure is bounded ECONOMICALLY: per-call spend is capped
///            (MAX_BUYBACK_ETH = 1 ETH), buybacks are rate-limited to one per block (so the
///            cap cannot be batch-bypassed inside one attacker transaction), and the attacker
///            pays the FeeHook's skim twice plus the LP fee twice on the attack volume
///            (~2.6% round trip at launch rates). Inflating spot by p% costs the attacker
///            fees on attack volume proportional to pool depth, while the win is at most
///            1 ETH × p% per block — unprofitable unless the pool is nearly empty.
///         3. The per-block limit is NOT the architecture's rejected "pool-wide per-block buy
///            cap": it gates only this engine's own keeper calls, never user swaps.
///         4. Dust-call griefing of the per-block slot is neutralized by a minimum spend:
///            a call must offer at least min(balance, MIN_BUYBACK_ETH = 0.1 ETH), so
///            occupying a block's slot does real burning at fair-or-reverted prices.
///         Keepers are paid TIP_BPS (1%, hardcoded) of the ETH actually spent, off the top —
///         proportional to work done, zero for reverted or empty calls, ungameable by
///         splitting (N small calls earn the same total tip and need N blocks).
contract BurnEngine is IBurnEngine, IUnlockCallback, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─────────────────────────────────── constants ─────────────────────────────────────

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice Keeper tip: 1% of the ETH actually spent, hardcoded (no admin lever).
    uint256 public constant TIP_BPS = 100;

    /// @notice Hard ceiling on the admin-tunable slippage tolerance (5%).
    uint16 public constant MAX_SLIPPAGE_BPS = 500;

    /// @notice Hard per-call ETH spend cap. Bounds the value a single sandwich can target.
    uint256 public constant MAX_BUYBACK_ETH = 1 ether;

    /// @notice Minimum ETH a call must offer (or the whole balance, if smaller) — makes
    ///         consuming the per-block buyback slot do real work.
    uint256 public constant MIN_BUYBACK_ETH = 0.1 ether;

    /// @notice The FeeHook's fee ceiling, mirrored for conservative sizing (sizing uses the
    ///         live fee; this is only a sanity bound).
    uint256 internal constant HOOK_FEE_CEILING_BPS = 200;

    // ──────────────────────────────────── storage ──────────────────────────────────────

    /// @notice The Uniswap V4 PoolManager.
    IPoolManager public immutable poolManager;

    /// @notice WORD — the token this engine buys and burns. This engine is its sole `burner`.
    IWordToken public immutable wordToken;

    /// @notice Destination of the residual-ETH sweep at retirement.
    IRewardsDistributor public immutable rewardsDistributor;

    /// @notice The canonical ETH/WORD pool key. Set once via `setPool` (the hook address is
    ///         CREATE2-mined after this contract deploys, so it cannot be a constructor arg).
    PoolKey public poolKey;

    /// @notice True once `setPool` has wired the canonical pool.
    bool public poolSet;

    /// @notice Admin-tunable slippage tolerance in bps (≤ MAX_SLIPPAGE_BPS). Default 100 = 1%.
    uint16 public maxSlippageBps = 100;

    /// @notice Block number of the last buyback (per-block rate limit).
    uint256 public lastBuybackBlock;

    // ──────────────────────────────────── events ───────────────────────────────────────
    // Deposited / BuybackExecuted / MaxSlippageSet are inherited from IBurnEngine.

    /// @notice The canonical pool was wired (one-time).
    event PoolSet(PoolId indexed poolId);
    /// @notice Idle ETH (held while there is no burnable excess) was swept onward to the
    ///         RewardsDistributor so no fee is ever stranded. Backstop — the FeeHook's dynamic
    ///         routing normally avoids sending burn-slice ETH when there is no excess.
    event ResidualSwept(uint256 amount);

    // ──────────────────────────────────── errors ───────────────────────────────────────

    /// @notice Caller is not the PoolManager.
    error NotPoolManager();
    /// @notice setPool called twice, or buyback attempted before setPool.
    error PoolAlreadySet();
    /// @notice Buyback attempted before the canonical pool was wired.
    error PoolNotSet();
    /// @notice The supplied pool key is not an ETH/WORD pool with a hook.
    error InvalidPoolKey();
    /// @notice Buybacks are not live yet: WordToken minting has not been sealed (Phase 3).
    ///         The burn slice accrues safely here in the meantime (SYS-1).
    error MintingNotSealedYet();
    /// @notice Nothing to buy right now: WordToken has no burnable excess (supply is at the
    ///         live backing floor). Resumes when a later unbind lowers the floor.
    error NoBurnableExcess();
    /// @notice One buyback per block.
    error BuybackRateLimited();
    /// @notice The call offered less than min(balance, MIN_BUYBACK_ETH).
    error SpendBelowMinimum();
    /// @notice Sized WORD target came out zero (no ETH, or dust budget).
    error NothingToBuy();
    /// @notice The swap's ETH cost exceeded the spot-derived maximum (manipulation or impact
    ///         beyond tolerance).
    error SlippageExceeded(uint256 ethCost, uint256 maxEthCost);
    /// @notice Slippage tolerance outside (0, MAX_SLIPPAGE_BPS].
    error SlippageOutOfBounds();
    /// @notice ETH transfer (keeper tip) failed.
    error EthTransferFailed();
    /// @notice Residual sweep attempted while WORD is still burnable (use the buyback instead).
    error ExcessStillBurnable();
    /// @notice Zero address where a real address is required.
    error ZeroAddress();

    // ───────────────────────────────── construction ────────────────────────────────────

    /// @param manager The V4 PoolManager.
    /// @param token   The WORD token (this engine must be wired as its `burner`).
    /// @param rewards The RewardsDistributor (residual-sweep destination).
    /// @param admin   The protocol admin (may set the pool once and tune slippage, bounded).
    constructor(IPoolManager manager, IWordToken token, IRewardsDistributor rewards, address admin) Ownable(admin) {
        if (address(manager) == address(0) || address(token) == address(0) || address(rewards) == address(0)) {
            revert ZeroAddress();
        }
        poolManager = manager;
        wordToken = token;
        rewardsDistributor = rewards;
    }

    /// @notice Bare ETH transfers are accepted as donations to the burn (or, when there is no
    ///         burnable excess, sweepable onward via `sweepResidual`).
    receive() external payable {}

    // ─────────────────────────────────── funding ───────────────────────────────────────

    /// @inheritdoc IBurnEngine
    function deposit() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    /// @inheritdoc IBurnEngine
    function pendingEth() external view returns (uint256) {
        return address(this).balance;
    }

    // ─────────────────────────────────── buyback ───────────────────────────────────────

    /// @inheritdoc IBurnEngine
    /// @dev See the contract-level dev note for the full defensive design. Order of
    ///      operations: checks → rate-limit latch → size target → swap in own unlock →
    ///      burn 100% → keeper tip. No retirement: when there is no burnable excess the call
    ///      reverts early (`NoBurnableExcess`) and the engine simply waits for the next unbind.
    function executeBuyback(uint256 maxEthToSpend) external {
        if (!poolSet) revert PoolNotSet();
        // SYS-1 keeper clarity: WordToken.burn requires the seal, so a pre-seal buyback can
        // never succeed. Fail fast with an unambiguous signal — before the swap and before
        // the rate-limit latch, so a doomed call neither moves the pool nor consumes the
        // block's buyback slot. The burn slice accrues from trading-live (Phase 2); burning
        // begins the moment the seal (Phase 3) lands.
        if (!wordToken.mintingSealed()) revert MintingNotSealedYet();
        // Dynamic floor: nothing to burn right now (supply is at the live backing floor). Clean
        // early revert — burning resumes automatically once a later unbind lowers the floor.
        // Checked before the rate-limit latch so a no-excess call never consumes the slot.
        if (wordToken.burnableExcess() == 0) revert NoBurnableExcess();
        if (lastBuybackBlock == block.number) revert BuybackRateLimited();
        lastBuybackBlock = block.number;

        uint256 balance = address(this).balance;
        uint256 spendBudget = maxEthToSpend < balance ? maxEthToSpend : balance;
        if (spendBudget > MAX_BUYBACK_ETH) spendBudget = MAX_BUYBACK_ETH;
        uint256 minSpend = balance < MIN_BUYBACK_ETH ? balance : MIN_BUYBACK_ETH;
        if (spendBudget < minSpend || spendBudget == 0) revert SpendBelowMinimum();

        // The budget must cover the swap cost plus the tip on it.
        uint256 swapBudget = spendBudget * BPS / (BPS + TIP_BPS);

        (uint256 target, uint256 maxEthCost) = _sizeTarget(swapBudget);
        if (target == 0) revert NothingToBuy();

        // The swap runs inside our own unlock — its OWN transaction context, never a
        // re-entry from a hook callback (the FeeHook holds no swap logic at all).
        bytes memory result = poolManager.unlock(abi.encode(target, maxEthCost));
        (uint256 ethCost, uint256 wordBought) = abi.decode(result, (uint256, uint256));

        // Burn 100% of what was bought. WordToken re-checks the dynamic floor atomically and
        // lands supply exactly on the floor on the call that consumes the last of the excess.
        wordToken.burn(wordBought);

        // Keeper tip: proportional to ETH actually spent, off the top.
        uint256 tip = ethCost * TIP_BPS / BPS;
        if (tip > 0) {
            (bool ok,) = msg.sender.call{value: tip}("");
            if (!ok) revert EthTransferFailed();
        }

        emit BuybackExecuted(msg.sender, ethCost, wordBought, tip);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Exact-output buy of `target` WORD: swap, enforce the spot-derived cost ceiling,
    ///      settle ETH, take WORD. Reverts atomically on guard violation — no partial fills.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 target, uint256 maxEthCost) = abi.decode(data, (uint256, uint256));

        BalanceDelta delta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, // ETH (currency0) in, WORD (currency1) out
                amountSpecified: int256(target), // positive = exact output
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        // delta is OUR net position: amount0 is the full ETH owed (pool input + hook skim,
        // both charged to the swapper), amount1 the WORD received (= target, exact output).
        uint256 ethCost = uint256(uint128(-delta.amount0()));
        uint256 wordBought = uint256(uint128(delta.amount1()));

        // On-chain slippage guard. An over-tolerance cost — own impact or interference —
        // reverts the whole buyback rather than partially filling.
        if (ethCost > maxEthCost) revert SlippageExceeded(ethCost, maxEthCost);

        poolManager.settle{value: ethCost}();
        poolManager.take(poolKey.currency1, address(this), wordBought);

        return abi.encode(ethCost, wordBought);
    }

    /// @notice Onward-sweeps the engine's ETH to the RewardsDistributor when there is no
    ///         burnable excess (supply at the live floor) — the no-stranding backstop.
    ///         Permissionless. Reverts while WORD is still burnable, so it can never divert
    ///         ETH that the buyback should be spending; in normal operation the FeeHook's
    ///         dynamic routing already withholds the burn slice when there is no excess, so
    ///         this only ever moves donations / a flush that raced an unbind.
    /// @dev    There is no permanent retirement: if a later unbind frees excess, the burn
    ///         slice simply resumes funding the engine.
    function sweepResidual() external {
        if (wordToken.burnableExcess() != 0) revert ExcessStillBurnable();
        uint256 balance = address(this).balance;
        if (balance > 0) {
            rewardsDistributor.deposit{value: balance}();
            emit ResidualSwept(balance);
        }
    }

    // ──────────────────────────────── bounded admin ────────────────────────────────────

    /// @notice Wires the canonical ETH/WORD pool. One-time: the hook address is mined after
    ///         this contract deploys, so the key arrives post-construction.
    /// @dev    Beyond the shape checks, the key must be the canonical pool of a FeeHook that
    ///         points back at THIS engine (overseer review R-1): a compromised-or-mistaken
    ///         admin cannot misdirect the burn stream to a foreign pool — the binding is
    ///         mutual and verified on-chain, not merely script-ordered.
    function setPool(PoolKey calldata key) external onlyOwner {
        if (poolSet) revert PoolAlreadySet();
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != address(wordToken)
                || address(key.hooks) == address(0)
        ) revert InvalidPoolKey();
        IFeeHookView hook = IFeeHookView(address(key.hooks));
        if (hook.burnEngine() != address(this)) revert InvalidPoolKey();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(hook.canonicalPoolId())) revert InvalidPoolKey();
        poolKey = key;
        poolSet = true;
        emit PoolSet(key.toId());
    }

    /// @notice Tunes the slippage tolerance within (0, MAX_SLIPPAGE_BPS]. The hardcoded
    ///         ceiling means this can never be loosened into a free sandwich.
    function setMaxSlippageBps(uint16 newMaxSlippageBps) external onlyOwner {
        if (newMaxSlippageBps == 0 || newMaxSlippageBps > MAX_SLIPPAGE_BPS) revert SlippageOutOfBounds();
        maxSlippageBps = newMaxSlippageBps;
        emit MaxSlippageSet(newMaxSlippageBps);
    }

    // ──────────────────────────────────── internal ─────────────────────────────────────

    /// @dev Sizes the exact-output WORD target for `swapBudget` ETH from the pool's current
    ///      spot price, and derives the cost ceiling for the slippage guard.
    ///
    ///      target  = min(remaining-burnable,
    ///                    spotOut(swapBudget) deflated by lpFee + live hook fee + tolerance)
    ///      maxCost = spotCost(target) grossed up by the same three factors
    ///
    ///      Deflating the target by the same margins that gross up the ceiling means a calm
    ///      pool always satisfies the guard, while anything beyond tolerance reverts.
    ///
    ///      ROUNDING (finding INT-1): the ceiling side rounds every division UP. The pool
    ///      rounds an exact-output charge (and its LP fee) up, so a floor-rounded ceiling
    ///      can sit 1–2 wei below the actual charge when the target is wei-dust — stalling the
    ///      buyback (`SlippageExceeded`) on a dust remainder. Ceiling-rounding adds at most a
    ///      few wei to `maxEthCost` — pure integer-rounding correction, not a looser percentage
    ///      tolerance; normal-scale buybacks are unaffected. The `target` deflation stays
    ///      floor-rounded (conservative direction).
    function _sizeTarget(uint256 swapBudget) internal view returns (uint256 target, uint256 maxEthCost) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        if (sqrtPriceX96 == 0) revert PoolNotSet();

        // Dynamic floor: the live burnable amount (totalSupply − totalAlive×1000e18), which
        // WordToken.burn re-checks atomically. Caps the exact-output target so a buyback can
        // never overshoot the backing floor.
        uint256 remaining = wordToken.burnableExcess();

        uint256 lpFeePips = poolKey.fee; // pips: 1e6 = 100%
        uint256 hookFeeBps = IFeeHookView(address(poolKey.hooks)).feeBps();

        // Spot WORD out for the budget: budget × price, price = (sqrtP/2^96)^2 (token1/token0).
        uint256 spotOut = FullMath.mulDiv(
            FullMath.mulDiv(swapBudget, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96
        );
        // Deflate by LP fee, hook fee, and tolerance so the sized swap fits the budget.
        target = spotOut * (1e6 - lpFeePips) / 1e6;
        target = target * (BPS - hookFeeBps - maxSlippageBps) / BPS;
        if (target > remaining) target = remaining;
        if (target == 0) return (0, 0);

        // Spot ETH cost of the target, grossed up by the same factors — the guard ceiling.
        // Every step rounds UP (see ROUNDING note above).
        uint256 spotCost = FullMath.mulDivRoundingUp(
            FullMath.mulDivRoundingUp(target, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
        );
        maxEthCost = (spotCost * (1e6 + lpFeePips) + 1e6 - 1) / 1e6;
        maxEthCost = (maxEthCost * (BPS + hookFeeBps + maxSlippageBps) + BPS - 1) / BPS;
    }
}
