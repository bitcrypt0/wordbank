// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IBountyEngine — daily commit-reveal sentence bounties
/// @notice FROZEN at interfaces-v1. Do not edit without overseer approval and a tag bump.
/// @dev    Implemented by agent 4 (bounty). Consumed by:
///           - FeeHook (agent 5): deposit (the bounty slice: 25% at launch, default 30% post-burn).
///           - RewardsDistributor (agent 3): deposit (dust sweep destination).
///           - Frontend (agent 8): the full game console drives off this surface + events.
///         Template administration and tier-menu administration are BountyEngine-internal
///         admin surface, intentionally absent here (shape is agent 4's discretion within
///         the normative bounds: MAX 7 slots, tiers 0.1–0.5 ETH, admin sets menus never draws).
interface IBountyEngine {
    // ──────────────────────────────────── events ───────────────────────────────────────

    /// @notice ETH arrived in the treasury (from FeeHook flush, dust sweep, or donation).
    event TreasuryDeposit(address indexed from, uint256 amount);
    /// @notice A holder committed; the reveal becomes possible after targetBlock.
    event Committed(uint256 indexed eventId, address indexed committer, uint256 targetBlock);
    /// @notice The sentence was generated and the bounty locked. `words` are the resolved
    ///         strings at reveal time (frontend renders history from this without re-reading).
    event SentenceGenerated(
        uint256 indexed eventId,
        uint256[] tokenIds,
        string[] words,
        uint256 templateId,
        uint256 amount,
        uint256 sharePerWord,
        uint256 deadline
    );
    /// @notice An unrevealed commit lapsed past the blockhash window; bond forfeited to treasury.
    event CommitExpired(uint256 indexed eventId, address indexed committer, uint256 bondForfeited);
    /// @notice A word's share was claimed.
    event BountyClaimed(uint256 indexed eventId, uint256 indexed tokenId, address indexed to, uint256 amount);
    /// @notice Post-deadline unclaimed remainder returned to the free treasury.
    event EventSwept(uint256 indexed eventId, uint256 amountReturned);

    // ─────────────────────────────────── mutating ──────────────────────────────────────

    /// @notice Accepts ETH into the treasury. Permissionless (FeeHook is the primary source).
    function deposit() external payable;

    /// @notice Opens a generation event. Caller must hold ≥1 Word NFT; at most one event per
    ///         24h cycle; requires free treasury ≥ the minimum tier and no pending commit.
    /// @dev    msg.value MUST equal the 0.01 ETH bond exactly. Stores
    ///         targetBlock = block.number + REVEAL_DELAY (15 blocks).
    function commit() external payable;

    /// @notice Resolves a pending commit. Callable by ANYONE once block.number > targetBlock,
    ///         while targetBlock is within the 256-block blockhash window. Atomically: picks a
    ///         feasible template, fills slots from the alive registry (deduplicated), draws a
    ///         tier among only affordable tiers, locks the funds, pays the caller the 2%
    ///         reveal reward, refunds the committer's bond, emits SentenceGenerated.
    function reveal() external;

    /// @notice Clears a commit whose targetBlock fell out of the blockhash window unrevealed.
    ///         Callable by anyone; forfeits the bond to the treasury; re-enables commit.
    function expireCommit() external;

    /// @notice Claims one word's share. Requires: tokenId in the event's word set; before the
    ///         7-day deadline; wordBank.ownerOf(tokenId) == msg.sender (claim-time ownership);
    ///         not already claimed.
    function claim(uint256 eventId, uint256 tokenId) external;

    /// @notice Batched claim for multi-word winners. Same checks per id; any failure reverts
    ///         the whole batch.
    function claimMany(uint256 eventId, uint256[] calldata tokenIds) external;

    /// @notice Returns the post-deadline unclaimed remainder of an event's locked funds to the
    ///         free treasury. Callable by anyone. Shares of words burned before claiming fall
    ///         through to this — never redistributed (per-event share math is immutable).
    function sweep(uint256 eventId) external;

    // ──────────────────────────────────── views ────────────────────────────────────────

    /// @notice Single-call buyer/frontend check: true iff tokenId is in the event's set,
    ///         unclaimed, before the deadline, and the token is still alive.
    function isClaimable(uint256 eventId, uint256 tokenId) external view returns (bool);

    /// @notice ETH reserved for revealed-but-unswept events. Free treasury =
    ///         address(this).balance - lockedFunds(). Invariant: lockedFunds() ≤ balance.
    function lockedFunds() external view returns (uint256);

    /// @notice Full event record for frontends and integration tests.
    /// @return tokenIds     the words in sentence order (empty if eventId unknown/unrevealed)
    /// @return sharePerWord immutable per-word payout for this event
    /// @return deadline     claim cutoff timestamp
    /// @return swept        whether the post-deadline sweep has run
    function eventInfo(uint256 eventId)
        external
        view
        returns (uint256[] memory tokenIds, uint256 sharePerWord, uint256 deadline, bool swept);
}
