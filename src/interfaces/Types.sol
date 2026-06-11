// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  WORDBANK shared types
/// @notice FROZEN at interfaces-v1. Do not edit without overseer approval and a tag bump
///         (see root AGENTS.md, "Interface protocol"). Multiple agents compile against this file.

/// @notice Part-of-speech category of a word. Drives sentence-slot filling and palette bias.
/// @dev    Frozen at four categories for v1. Agent 2 (renderer-art) may propose additions via
///         the overseer; appending new members is ABI-compatible, reordering is NOT — never
///         reorder. The alive registry, templates, and trait palettes are all keyed by this enum.
enum Category {
    NOUN,
    VERB,
    ADJ,
    ADV
}

/// @notice Everything the Renderer needs to assemble tokenURI for one word.
/// @dev    Produced by WordBank from its per-token storage; consumed by IRenderer.tokenURI.
///         Trait fields are indices into the Renderer's fragment/constraint tables, assigned
///         via the provenance offset. Visual traits MUST never be read by BountyEngine or
///         RewardsDistributor (system invariant 6).
struct WordData {
    /// @notice The word itself, stored fully onchain.
    string word;
    /// @notice Part-of-speech category (also biases background palette — color only, never odds).
    Category category;
    /// @notice Index into the Renderer's material fragment table (the surface the word is on).
    uint8 material;
    /// @notice Index into validInks[material] (NOT a global ink id — material-relative).
    uint8 ink;
    /// @notice Index into validBackgrounds[material] (material-relative; always a solid color).
    uint8 background;
    /// @notice True for the 25 one-of-one honors words rendered as bespoke SVG path art.
    bool honors;
}
