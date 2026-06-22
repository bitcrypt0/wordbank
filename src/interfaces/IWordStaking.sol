// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IWordStaking — ETH fee-share staking for the relaunch WORD token
/// @notice The "token side" sink of FeeHookV2: receives 50% of the 1% swap fee (in ETH) and
///         streams it pro-rata to WORD stakers. Consumed by FeeHookV2 (deposit) and the
///         frontend (stake/unstake/claim/pendingRewards/views).
interface IWordStaking {
    // ──────────────────────────────────── events ───────────────────────────────────────

    /// @notice ETH arrived and was spread over `totalStaked` (or deferred if none staked).
    event Deposited(address indexed from, uint256 amount, uint256 accRewardPerShare);
    /// @notice A deposit arrived while nothing was staked and was held for the next staker.
    event DepositDeferred(address indexed from, uint256 amount, uint256 buffered);
    /// @notice WORD staked.
    event Staked(address indexed user, uint256 amount, uint256 totalStaked);
    /// @notice WORD unstaked.
    event Unstaked(address indexed user, uint256 amount, uint256 totalStaked);
    /// @notice Accrued ETH rewards claimed.
    event Claimed(address indexed user, uint256 amount);

    // ─────────────────────────────────── mutating ──────────────────────────────────────

    /// @notice Accepts ETH and accrues it to stakers: accRewardPerShare += amount*1e18/totalStaked.
    /// @dev    MUST be permissionless (the fee router and donations both call it). Behavior at
    ///         totalStaked == 0 is the implementer's documented choice (defer, never revert).
    function deposit() external payable;

    /// @notice Stakes `amount` WORD (pulls via transferFrom), settling pending rewards first.
    function stake(uint256 amount) external;

    /// @notice Unstakes `amount` WORD back to the caller, settling pending rewards first.
    function unstake(uint256 amount) external;

    /// @notice Pays the caller's accrued ETH rewards.
    function claim() external;

    // ──────────────────────────────────── views ────────────────────────────────────────

    /// @notice The staking token (the relaunch WORD).
    function stakingToken() external view returns (address);

    /// @notice WORD currently staked by `user`.
    function stakedOf(address user) external view returns (uint256);

    /// @notice Total WORD staked across everyone.
    function totalStaked() external view returns (uint256);

    /// @notice Exact pending (unclaimed) ETH rewards for `user`, in wei.
    function pendingRewards(address user) external view returns (uint256);
}
