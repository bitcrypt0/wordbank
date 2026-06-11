// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Category} from "./Types.sol";

/// @title  IWordBank — the cross-contract surface of the ERC-721 + binding vault
/// @notice FROZEN at interfaces-v1. Do not edit without overseer approval and a tag bump.
/// @dev    Implemented by agent 1 (token-bank). Consumed by:
///           - BountyEngine (agent 4): ownerOf, balanceOf, wordOf, categoryOf, aliveCount,
///             aliveAt, isAlive — sentence generation and claim/commit gating.
///           - RewardsDistributor (agent 3): ownerOf, totalAlive — claim auth and accumulator.
///         This is deliberately NOT the full ERC-721 ABI — only what other protocol contracts
///         need. The implementation is additionally a standard ERC-721 + ERC-2981; minting,
///         unbinding, phase admin, and royalty functions are WordBank-internal surface and are
///         intentionally absent here so their shape stays in agent 1's discretion.
interface IWordBank {
    // ─────────────────────────── ownership (ERC-721 subset) ────────────────────────────

    /// @notice Owner of a live token. MUST revert for burned/nonexistent ids (ERC-721
    ///         semantics) — BountyEngine and RewardsDistributor rely on this for claim auth.
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice ERC-721 balance. BountyEngine.commit gates on balanceOf(caller) >= 1.
    function balanceOf(address owner) external view returns (uint256);

    // ──────────────────────────────── word metadata ────────────────────────────────────

    /// @notice The word string of a token. MUST work for any minted id, alive or burned
    ///         (burned words still appear in historical SentenceGenerated events).
    function wordOf(uint256 tokenId) external view returns (string memory);

    /// @notice Part-of-speech category of a token's word.
    function categoryOf(uint256 tokenId) external view returns (Category);

    // ─────────────────────────────── alive registry ────────────────────────────────────

    /// @notice Number of alive (minted, not unbound) tokens in a category.
    function aliveCount(Category category) external view returns (uint256);

    /// @notice TokenId at `index` in the dense alive array for `category`.
    ///         Valid iff index < aliveCount(category). Ordering is arbitrary and changes on
    ///         unbind (swap-and-pop) — callers MUST NOT assume stability across transactions.
    function aliveAt(Category category, uint256 index) external view returns (uint256 tokenId);

    /// @notice Total alive tokens across all categories. Equals the sum of aliveCount over
    ///         every Category member. RewardsDistributor divides deposits by this.
    function totalAlive() external view returns (uint256);

    /// @notice True iff the token is minted and not unbound. Cheaper than try/catch on
    ///         ownerOf; used by BountyEngine.isClaimable.
    function isAlive(uint256 tokenId) external view returns (bool);

    /// @notice Bound WORD backing of a token (1,000e18 while alive, 0 after unbind).
    ///         Exposed for frontends and integration invariants.
    function bondedBalance(uint256 tokenId) external view returns (uint256);
}
