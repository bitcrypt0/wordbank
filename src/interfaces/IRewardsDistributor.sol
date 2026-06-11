// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IRewardsDistributor — equal fee-share across alive NFTs (accumulator pattern)
/// @notice FROZEN at interfaces-v1. Do not edit without overseer approval and a tag bump.
/// @dev    Implemented by agent 3 (rewards). Consumed by:
///           - WordBank (agent 1): register on mint, settleAndClose on unbind.
///           - FeeHook (agent 5): deposit (the rewards slice: 50% at launch, default 70% post-burn).
///           - BurnEngine (agent 5): deposit (residual-ETH sweep at retirement).
///           - Frontend (agent 8): pendingRewards, claimRewards, events.
///         All accounting is keyed by tokenId, never by owner — rewards travel with the NFT.
interface IRewardsDistributor {
    // ──────────────────────────────────── events ───────────────────────────────────────

    /// @notice ETH arrived and was spread over `totalAlive` shares.
    event Deposited(address indexed from, uint256 amount, uint256 accRewardPerNFT);
    /// @notice Token registered at mint with its debt checkpointed to the current accumulator.
    event Registered(uint256 indexed tokenId);
    /// @notice Pending rewards paid to the token's owner via claimRewards.
    event Claimed(uint256 indexed tokenId, address indexed to, uint256 amount);
    /// @notice Token force-settled and permanently closed during unbind.
    event SettledAndClosed(uint256 indexed tokenId, address indexed to, uint256 amount);
    /// @notice Provable rounding dust swept to the BountyEngine treasury.
    event DustSwept(address indexed to, uint256 amount);

    // ─────────────────────────────────── mutating ──────────────────────────────────────

    /// @notice Accepts ETH and accrues it equally to all currently-alive tokens:
    ///         accRewardPerNFT += amount * 1e18 / wordBank.totalAlive().
    /// @dev    Called by the FeeHook's flush; MUST be permissionless (donations are fine).
    ///         Behavior at totalAlive == 0 is the implementer's documented choice (charter).
    function deposit() external payable;

    /// @notice Registers a freshly minted token. WordBank-only, called inside every mint.
    /// @dev    MUST set rewardDebt[tokenId] = accRewardPerNFT so mid-stream mints cannot
    ///         claim fees that arrived before they existed. MUST revert on re-registration
    ///         and on previously closed ids.
    function register(uint256 tokenId) external;

    /// @notice Force-settles and permanently closes a token during unbind. WordBank-only.
    /// @param  to Recipient of the pending payout (the burner — claim-time owner).
    /// @dev    WordBank calls this BEFORE removing the token from the alive registry, so the
    ///         token receives its full share of every deposit up to the burn and survivors
    ///         split everything after (settle-before-decrement, system invariant 3).
    ///         Closed ids can never accrue, claim, or re-register.
    function settleAndClose(uint256 tokenId, address to) external;

    /// @notice Batched pull-payment claim. For each id: requires
    ///         wordBank.ownerOf(tokenId) == msg.sender; pays pending; advances rewardDebt.
    /// @dev    No deadline — this stream accrues continuously. MUST skip nothing silently:
    ///         a non-owned or closed id reverts the whole batch.
    function claimRewards(uint256[] calldata tokenIds) external;

    // ──────────────────────────────────── views ────────────────────────────────────────

    /// @notice Exact pending (unclaimed) rewards for a token, in wei. Returns 0 for closed
    ///         ids. The buyer-due-diligence view: marketplaces price listings off this.
    function pendingRewards(uint256 tokenId) external view returns (uint256);

    /// @notice Current accumulator value (1e18-scaled rewards per alive NFT), for frontends
    ///         and invariant tests.
    function accRewardPerNFT() external view returns (uint256);
}
