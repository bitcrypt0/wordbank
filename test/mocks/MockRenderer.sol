// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IRenderer} from "../../src/interfaces/IRenderer.sol";
import {WordData} from "../../src/interfaces/Types.sol";

/// @title  MockRenderer — stand-in for agent 2's Renderer
/// @notice Returns a deterministic marker URI embedding the tokenId and the word it was
///         handed, so WordBank tests can assert that tokenURI delegates with the right data.
contract MockRenderer is IRenderer {
    using Strings for uint256;

    /// @inheritdoc IRenderer
    function tokenURI(uint256 tokenId, WordData calldata data) external pure returns (string memory) {
        return string.concat(
            "mock://",
            tokenId.toString(),
            "/",
            data.word,
            "/",
            uint256(uint8(data.category)).toString(),
            "/",
            data.honors ? "honors" : "standard"
        );
    }

    /// @inheritdoc IRenderer
    function unrevealedTokenURI(uint256 tokenId) external pure returns (string memory) {
        // Trait-free marker: only the tokenId appears, so WordBank tests can assert
        // the pre-reveal path delegates here with no WordData.
        return string.concat("mock://unrevealed/", tokenId.toString());
    }
}
