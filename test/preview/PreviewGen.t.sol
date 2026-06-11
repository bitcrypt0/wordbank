// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Renderer} from "../../src/Renderer.sol";
import {Category, WordData} from "../../src/interfaces/Types.sol";
import {RendererAssets} from "../utils/RendererAssets.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @notice Generates the owner preview gallery's raw material: every preview URI
///         is the REAL `tokenURI` output of the sealed Renderer, captured here and
///         decoded into browsable SVGs by tools/preview/build_gallery.py. There is
///         deliberately no second rendering code path - what the owner previews is
///         exactly what mints.
/// @dev    Runs as part of `forge test`, so the manifest refreshes on every visual
///         change. Build the gallery with:
///           forge test --match-contract PreviewGen && python tools/preview/build_gallery.py
contract PreviewGen is Test {
    using LibString for string;
    using LibString for uint256;

    Renderer internal renderer;
    string internal entries;

    /// @dev Words used for non-honors previews, one per category.
    string[4] internal sampleWords = ["ember", "wander", "luminous", "softly"];

    function setUp() public {
        renderer = new Renderer();
        RendererAssets.loadAll(renderer);
    }

    function _add(string memory file, WordData memory data, string memory note) internal {
        (string memory matName,) = renderer.materialInfo(data.material);
        (string memory inkName,) = renderer.inkAt(data.material, data.ink);
        if (data.honors) inkName = "Bespoke Lettering";
        (string memory bgName,) = renderer.backgroundAt(data.material, data.background);
        string memory uri = renderer.tokenURI(1, data);
        string memory entry = string.concat(
            '{"file":"',
            file,
            '","word":"',
            data.word,
            '","category":"',
            _cat(data.category),
            '","material":"',
            matName,
            '","ink":"',
            inkName,
            '","background":"',
            bgName,
            '","honors":',
            data.honors ? "true" : "false",
            ',"note":"',
            note,
            '","uri":"',
            uri,
            '"}'
        );
        entries = bytes(entries).length == 0 ? entry : string.concat(entries, ",", entry);
    }

    /// @dev Adds the pre-reveal placeholder, decoded from the real
    ///      `unrevealedTokenURI` (no WordData) so the owner previews exactly what
    ///      mints during the mint window.
    function _addUnrevealed(string memory file, uint256 tokenId) internal {
        string memory uri = renderer.unrevealedTokenURI(tokenId);
        string memory entry = string.concat(
            '{"file":"',
            file,
            '","word":"WORDBANK #',
            tokenId.toString(),
            '","category":"Pre-reveal","material":"Sealed specimen card","ink":"Embedded font",'
            '"background":"India Ink","honors":false,"note":"unrevealed","uri":"',
            uri,
            '"}'
        );
        entries = bytes(entries).length == 0 ? entry : string.concat(entries, ",", entry);
    }

    function _cat(Category c) internal pure returns (string memory) {
        if (c == Category.NOUN) return "Noun";
        if (c == Category.VERB) return "Verb";
        if (c == Category.ADJ) return "Adjective";
        return "Adverb";
    }

    function test_generateOwnerPreviewManifest() public {
        vm.createDir("assets/previews", true);
        uint256 mats = renderer.materialCount();

        // 1. Every material: one preview per ink (cycling backgrounds) - the
        //    representative ink/background coverage the owner signs off on.
        for (uint8 m; m < mats; ++m) {
            (string memory matName,) = renderer.materialInfo(m);
            (uint256 inks, uint256 bgs) = renderer.constraintTableSizes(m);
            for (uint8 i; i < inks; ++i) {
                uint8 b = uint8((uint256(m) + i) % bgs);
                Category cat = Category((uint256(m) + i) % 4);
                _add(
                    string.concat("material_", matName.lower(), "_ink", uint256(i).toString()),
                    WordData(sampleWords[uint256(cat)], cat, m, i, b, false),
                    "material coverage"
                );
            }
        }

        // 2. One example per part-of-speech category on material 0, each with a
        //    background from its biased palette group (paper: NOUN 0/1, VERB 2/3,
        //    ADJ 4/5, ADV 6/7 - see assets/traits/materials.json bias tags).
        for (uint8 c; c < 4; ++c) {
            _add(
                string.concat("category_", _cat(Category(c)).lower()),
                WordData(sampleWords[c], Category(c), 0, 1, uint8(c * 2), false),
                "palette bias example"
            );
        }

        // 3. All loaded honors words, on their curated surfaces.
        RendererAssets.HonorsEntry[] memory honors = RendererAssets.honorsList();
        for (uint256 h; h < honors.length; ++h) {
            if (!renderer.hasHonorsArt(honors[h].word)) continue;
            _add(
                string.concat("honors_", honors[h].word.lower()),
                WordData(
                    honors[h].word, Category(honors[h].category), honors[h].material, 0, honors[h].background, true
                ),
                "honors 1/1"
            );
        }

        // 4. The pre-reveal "unrevealed" placeholder — trait-free, identical for
        //    every token but the #id. Decoded from the real unrevealedTokenURI.
        _addUnrevealed("unrevealed", 1234);

        vm.writeFile("assets/previews/manifest.json", string.concat('{"previews":[', entries, "]}"));
    }
}
