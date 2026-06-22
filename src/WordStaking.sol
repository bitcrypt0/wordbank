// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IWordStaking} from "./interfaces/IWordStaking.sol";

/// @title  WordStaking — stake WORD, earn ETH from the swap fee
/// @author WORDBANK — https://wordbank.fun
/// @notice The "token side" of the relaunch: 50% of the WORD/ETH pool's 1% fee (in ETH) flows
///         here via FeeHookV2.flush() and is streamed pro-rata to WORD stakers. Staking gives
///         the standalone WORD a reason to be HELD rather than dumped, and is itself a sink that
///         removes float from the market — the direct fix for the dump-on-unbind problem.
///
/// @dev    Classic rewards-per-share accumulator (the same O(1) pattern as RewardsDistributor,
///         keyed to staked balance instead of NFTs): no loops over stakers, no snapshots.
///
///         PRECISION (no stranded ETH): `accRewardPerShare` is 1e18-scaled. Per-user debt and
///         accrual are kept in SCALED units and only floored to wei at `claim()`, where the
///         sub-wei remainder is RETAINED for the user's next claim — so a user loses nothing.
///         On the deposit side the sub-share remainder (the part of a deposit too small to raise
///         the per-share accumulator by a whole unit across `totalStaked`) is carried in
///         `pendingUndistributed` and folded into the next deposit. Net: every wei is eventually
///         distributed; nothing strands.
///
///         ZERO-STAKE deposits: a deposit arriving while `totalStaked == 0` is HELD and DEFERRED
///         (never reverted) — `deposit()` is on the permissionless fee-routing path and must be
///         unbrickable. The buffer folds into the next deposit made while someone is staked; a
///         zero-value `deposit()` is the permissionless kick that distributes it.
///
///         TOKEN ASSUMPTION: the staking token MUST be a STANDARD ERC-20 — no fee-on-transfer
///         and no rebasing/elastic balance. `staked[user]` and `totalStaked` are credited with
///         the exact amount requested, so a fee-on-transfer token would over-credit stakes (the
///         contract would owe more WORD than it holds) and a rebasing token would desync the
///         ledger from the real balance. WordTokenV2 (the only intended token) is plain vanilla
///         and satisfies this; never point this at a non-standard token.
contract WordStaking is IWordStaking, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @dev Accumulator scale. 1e18 keeps per-deposit rounding sub-wei even at large stakes.
    uint256 private constant ACC_PRECISION = 1e18;

    /// @notice The staking token (the relaunch WORD), exposed via `stakingToken()`.
    IERC20 private immutable _token;

    /// @notice 1e18-scaled cumulative ETH rewards per staked token-wei.
    uint256 public accRewardPerShare;

    /// @inheritdoc IWordStaking
    uint256 public override totalStaked;

    /// @notice WORD staked per user.
    mapping(address => uint256) public staked;

    /// @notice Per-user accumulator checkpoint, in SCALED units (staked × accRewardPerShare at
    ///         the user's last settle). Pending-since = staked × acc − rewardDebt.
    mapping(address => uint256) public rewardDebt;

    /// @notice Per-user accrued-but-unclaimed rewards, in SCALED units. Floored to wei only at
    ///         claim(), with the sub-wei remainder retained here for next time.
    mapping(address => uint256) public accruedScaled;

    /// @notice ETH from deposits that arrived while nothing was staked, plus the carried
    ///         deposit-side rounding remainder. Folds into the next non-empty deposit.
    uint256 public pendingUndistributed;

    /// @notice Aggregate outstanding entitlement to stakers, in SCALED units. Increases by
    ///         exactly what each deposit accrues (perShare × totalStaked) and decreases by the
    ///         scaled amount each claim pays. Invariant: equals Σ over users of
    ///         (accruedScaled + staked×acc − rewardDebt). `ceil(totalOwedScaled / 1e18)` is the
    ///         wei reserve `sweep()` honors so it can never touch owed rewards.
    uint256 public totalOwedScaled;

    /// @notice Zero address given where a real one is required.
    error ZeroAddress();
    /// @notice deposit() with no value and no buffer to fold.
    error ZeroDeposit();
    /// @notice stake()/unstake() with a zero amount.
    error ZeroAmount();
    /// @notice unstake() for more than the caller has staked.
    error InsufficientStake();
    /// @notice ETH payout failed (recipient reverted or has no payable path).
    error EthTransferFailed(address to, uint256 amount);
    /// @notice sweep() found no provably-stranded ETH to recover.
    error NoStrandedEth();

    /// @notice Force-sent ETH (in excess of owed + buffer) was recovered into the staker pool.
    event Swept(address indexed caller, uint256 amount);

    /// @param token The relaunch WORD token (immutable; this contract has no owner or upgrade).
    constructor(address token) {
        if (token == address(0)) revert ZeroAddress();
        _token = IERC20(token);
    }

    // ─────────────────────────────────── mutating ──────────────────────────────────────

    /// @inheritdoc IWordStaking
    /// @dev Permissionless (fee router + donations). Defers while nothing is staked; otherwise
    ///      raises the accumulator and carries the sub-share remainder forward.
    function deposit() external payable override nonReentrant {
        uint256 amount = msg.value + pendingUndistributed;
        if (amount == 0) revert ZeroDeposit();

        uint256 ts = totalStaked;
        uint256 perShare = ts == 0 ? 0 : (amount * ACC_PRECISION) / ts;
        if (perShare == 0) {
            // Nothing staked, or amount too small to move the accumulator — hold it.
            pendingUndistributed = amount;
            emit DepositDeferred(msg.sender, msg.value, amount);
            return;
        }

        accRewardPerShare += perShare;
        uint256 distributedScaled = perShare * ts;
        totalOwedScaled += distributedScaled; // exactly what this deposit accrues to stakers
        uint256 distributed = distributedScaled / ACC_PRECISION; // ≤ amount
        pendingUndistributed = amount - distributed; // carry the sub-share remainder
        emit Deposited(msg.sender, amount, accRewardPerShare);
    }

    /// @inheritdoc IWordStaking
    function stake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _settle(msg.sender);
        staked[msg.sender] += amount;
        totalStaked += amount;
        rewardDebt[msg.sender] = staked[msg.sender] * accRewardPerShare;
        emit Staked(msg.sender, amount, totalStaked);
        // CEI: state is final before the external token pull.
        _token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @inheritdoc IWordStaking
    function unstake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (staked[msg.sender] < amount) revert InsufficientStake();
        _settle(msg.sender);
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        rewardDebt[msg.sender] = staked[msg.sender] * accRewardPerShare;
        emit Unstaked(msg.sender, amount, totalStaked);
        // CEI: state is final before the external token return.
        _token.safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc IWordStaking
    function claim() external override nonReentrant {
        _settle(msg.sender);
        uint256 scaled = accruedScaled[msg.sender];
        uint256 payout = scaled / ACC_PRECISION;
        if (payout != 0) {
            // Retain the sub-wei remainder for the next claim — nothing is lost.
            accruedScaled[msg.sender] = scaled - payout * ACC_PRECISION;
            totalOwedScaled -= payout * ACC_PRECISION; // release the scaled amount paid
            emit Claimed(msg.sender, payout);
            _pay(msg.sender, payout);
        }
    }

    /// @notice Recovers ETH force-sent to this contract (e.g. via `selfdestruct`, bypassing
    ///         `deposit()`) by folding it back into the staker pool. Permissionless.
    /// @dev    Provably cannot touch owed rewards or the undistributed buffer: it only moves the
    ///         balance in EXCESS of `pendingUndistributed + ceil(totalOwedScaled / 1e18)` into
    ///         `pendingUndistributed`, from where the next `deposit()` distributes it to stakers.
    ///         The ceiling reserve guarantees the floored per-user pendings are always fully
    ///         covered. No path ever sends ETH OUT of the staker pool — recovered ETH stays with
    ///         stakers. A second call immediately reverts (nothing left to recover).
    function sweep() external nonReentrant {
        uint256 reserved = pendingUndistributed + (totalOwedScaled + ACC_PRECISION - 1) / ACC_PRECISION;
        uint256 balance = address(this).balance;
        if (balance <= reserved) revert NoStrandedEth();
        uint256 stranded = balance - reserved;
        pendingUndistributed += stranded;
        emit Swept(msg.sender, stranded);
    }

    // ──────────────────────────────────── views ────────────────────────────────────────

    /// @inheritdoc IWordStaking
    function stakingToken() external view override returns (address) {
        return address(_token);
    }

    /// @inheritdoc IWordStaking
    function stakedOf(address user) external view override returns (uint256) {
        return staked[user];
    }

    /// @inheritdoc IWordStaking
    function pendingRewards(address user) external view override returns (uint256) {
        uint256 s = staked[user];
        uint256 owed = accruedScaled[user];
        if (s != 0) owed += s * accRewardPerShare - rewardDebt[user];
        return owed / ACC_PRECISION;
    }

    // ─────────────────────────────────── internal ──────────────────────────────────────

    /// @dev Moves rewards accrued since the user's last checkpoint into `accruedScaled` (in
    ///      scaled units, lossless) and re-checkpoints `rewardDebt` to the user's CURRENT stake.
    ///      Callers that then change `staked[user]` must reset `rewardDebt[user]` afterward.
    function _settle(address user) internal {
        uint256 s = staked[user];
        if (s != 0) {
            uint256 owed = s * accRewardPerShare - rewardDebt[user];
            if (owed != 0) accruedScaled[user] += owed;
        }
        rewardDebt[user] = s * accRewardPerShare;
    }

    /// @dev ETH out via call (no transfer()); reverts on failure so a non-payable recipient
    ///      fails only its own claim.
    function _pay(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed(to, amount);
    }
}
