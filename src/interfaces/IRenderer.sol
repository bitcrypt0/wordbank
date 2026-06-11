// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {WordData} from "./Types.sol";

/// @title  IRenderer — stateless onchain tokenURI assembly
/// @notice FROZEN at interfaces-v4. Do not edit without overseer approval and a tag bump.
/// @dev    Implemented by agent 2 (renderer-art). Consumed by WordBank (agent 1), which
///         delegates its ERC-721 tokenURI to this single call. The Renderer holds the
///         subsetted OFL font (SSTORE2 chunks), material SVG fragments, the
///         validInks/validBackgrounds constraint tables, and the 25 honors path artworks —
///         but no per-token state: everything token-specific arrives in `data`.
interface IRenderer {
    /// @notice Assembles the pre-reveal "unrevealed" placeholder metadata for one token.
    /// @param  tokenId The token's id, shown as `WORDBANK #<id>` on a sealed specimen card.
    /// @return uri     A fully self-contained data URI: `data:application/json;base64,...`
    ///         whose `image` is a `data:image/svg+xml;base64,...` — no IPFS, no external refs.
    /// @dev    Called by WordBank's `tokenURI` while the provenance offset is unset, so every
    ///         minted token shows branded art (not a marketplace gray box) during the mint
    ///         window. Takes ONLY `tokenId` — never `WordData`, no trait, no slot lookup — so
    ///         it is structurally incapable of leaking the eventual word/traits: the snipe-proof
    ///         guarantee. The art is byte-identical for every token except the displayed `#id`.
    function unrevealedTokenURI(uint256 tokenId) external view returns (string memory uri);

    /// @notice Assembles the complete ERC-721 metadata for one word.
    /// @param  tokenId Used only for display (name/description) — never for trait derivation;
    ///         all traits arrive pre-assigned in `data` via WordBank's provenance offset.
    /// @param  data    Word, category, and trait indices (see Types.sol). `data.ink` and
    ///         `data.background` are indices INTO the material's constraint tables, so any
    ///         in-range value renders a legible, coherent combination by construction.
    /// @return uri     A fully self-contained data URI: `data:application/json;base64,...`
    ///         whose `image` is a `data:image/svg+xml;base64,...` — no IPFS, no external refs.
    /// @dev    MUST revert on out-of-range trait indices rather than render incoherently.
    ///         View-only; gas is soft (offchain eth_call) but implementations should stay
    ///         within ~30M gas for node compatibility at worst-case traits (honors + largest
    ///         material fragment).
    function tokenURI(uint256 tokenId, WordData calldata data) external view returns (string memory uri);
}
