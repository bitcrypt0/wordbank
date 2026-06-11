// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Renderer} from "../../src/Renderer.sol";
import {Category, WordData} from "../../src/interfaces/Types.sol";
import {RendererAssets} from "../utils/RendererAssets.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

contract RendererTest is Test {
    using LibString for string;
    using LibString for uint256;

    Renderer internal renderer;

    string internal constant JSON_PREFIX = "data:application/json;base64,";
    string internal constant SVG_PREFIX = "data:image/svg+xml;base64,";

    function setUp() public {
        renderer = new Renderer();
        RendererAssets.loadAll(renderer);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _wd(string memory word, Category cat, uint8 mat, uint8 ink, uint8 bg, bool honors)
        internal
        pure
        returns (WordData memory)
    {
        return WordData({word: word, category: cat, material: mat, ink: ink, background: bg, honors: honors});
    }

    /// @dev Decodes the outer data URI into the metadata JSON string.
    function _json(string memory uri) internal pure returns (string memory) {
        require(uri.startsWith(JSON_PREFIX), "bad json prefix");
        return string(Base64.decode(uri.slice(bytes(JSON_PREFIX).length)));
    }

    /// @dev Extracts and decodes the SVG from a tokenURI.
    function _svg(string memory uri) internal view returns (string memory) {
        string memory json = _json(uri);
        string memory image = vm.parseJsonString(json, ".image");
        require(image.startsWith(SVG_PREFIX), "bad svg prefix");
        return string(Base64.decode(image.slice(bytes(SVG_PREFIX).length)));
    }

    function _count(string memory haystack, string memory needle) internal pure returns (uint256 n) {
        uint256 from;
        while (true) {
            uint256 i = haystack.indexOf(needle, from);
            if (i == LibString.NOT_FOUND) break;
            ++n;
            from = i + 1;
        }
    }

    // ------------------------------------------------------------------
    // tokenURI shape
    // ------------------------------------------------------------------

    function test_tokenURI_jsonWellFormed() public view {
        string memory uri = renderer.tokenURI(42, _wd("ember", Category.NOUN, 0, 1, 0, false));
        string memory json = _json(uri);

        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "ember", "word attr");
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), "Noun", "category attr");
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), "Paper", "material attr");
        assertEq(vm.parseJsonString(json, ".attributes[3].value"), "India Ink", "ink attr");
        assertEq(vm.parseJsonString(json, ".attributes[4].value"), "Umber", "background attr");
        assertEq(vm.parseJsonString(json, ".attributes[5].value"), "Common", "tier attr");
        assertEq(vm.parseJsonString(json, ".attributes[6].value"), "No", "honors attr");
        assertTrue(vm.parseJsonString(json, ".name").startsWith("WORDBANK #42"), "name");
        // The no-gameplay-effect invariant must be stated in the collection description.
        assertTrue(vm.parseJsonString(json, ".description").contains("zero effect on gameplay"), "invariant note");
    }

    function test_tokenURI_svgStructure() public view {
        string memory uri = renderer.tokenURI(1, _wd("wander", Category.VERB, 0, 0, 2, false));
        string memory svg = _svg(uri);

        assertTrue(svg.startsWith("<svg xmlns="), "svg open");
        assertTrue(svg.endsWith("</svg>"), "svg close");
        assertTrue(svg.contains("@font-face{font-family:'WB'"), "embedded font");
        assertTrue(svg.contains(">wander</text>"), "word text");
        assertTrue(svg.contains('fill="#c2552e"'), "verb-vivid backdrop color (Persimmon)");
        // Exactly one full-canvas solid background rect, no gradients anywhere.
        assertEq(_count(svg, '<rect width="1000" height="1000"'), 1, "single backdrop rect");
        assertEq(_count(svg, "Gradient"), 0, "no gradients");
    }

    function test_tokenURI_fontSizeScalesDown() public view {
        string memory shortSvg = _svg(renderer.tokenURI(1, _wd("ox", Category.NOUN, 0, 0, 0, false)));
        string memory longSvg = _svg(renderer.tokenURI(2, _wd("immeasurable", Category.ADJ, 0, 0, 0, false)));
        assertTrue(shortSvg.contains('font-size="190"'), "short word capped at 190");
        assertTrue(longSvg.contains('font-size="190"') == false, "long word shrinks");
    }

    function test_tokenURI_allCategoriesNamed() public view {
        assertEq(
            vm.parseJsonString(
                _json(renderer.tokenURI(1, _wd("a", Category.NOUN, 0, 0, 0, false))), ".attributes[1].value"
            ),
            "Noun"
        );
        assertEq(
            vm.parseJsonString(
                _json(renderer.tokenURI(1, _wd("a", Category.VERB, 0, 0, 0, false))), ".attributes[1].value"
            ),
            "Verb"
        );
        assertEq(
            vm.parseJsonString(
                _json(renderer.tokenURI(1, _wd("a", Category.ADJ, 0, 0, 0, false))), ".attributes[1].value"
            ),
            "Adjective"
        );
        assertEq(
            vm.parseJsonString(
                _json(renderer.tokenURI(1, _wd("a", Category.ADV, 0, 0, 0, false))), ".attributes[1].value"
            ),
            "Adverb"
        );
    }

    // ------------------------------------------------------------------
    // Honors path
    // ------------------------------------------------------------------

    function test_honors_rendersBespokeArt() public {
        Renderer r = new Renderer();
        RendererAssets.loadFont(r);
        RendererAssets.loadMaterials(r);
        r.addHonorsArt("Moon", bytes("<g id='honors-moon'><circle cx='500' cy='500' r='200'/></g>"));
        r.seal();

        string memory svg = _svg(r.tokenURI(9999, _wd("Moon", Category.NOUN, 0, 0, 0, true)));
        assertTrue(svg.contains("id='honors-moon'"), "bespoke art embedded");
        assertEq(_count(svg, "<text"), 0, "no standard text element on honors");
        assertTrue(r.hasHonorsArt("Moon"));
        assertFalse(r.hasHonorsArt("Pepe"));
    }

    function test_honors_missingArtReverts() public {
        vm.expectRevert(Renderer.HonorsArtMissing.selector);
        renderer.tokenURI(1, _wd("NotAnHonorsWord", Category.NOUN, 0, 0, 0, true));
    }

    // ------------------------------------------------------------------
    // Pre-reveal "unrevealed" placeholder (interfaces-v4)
    // ------------------------------------------------------------------

    /// @dev Decodes the unrevealed token's data URI down to its SVG.
    function _unrevealedSvg(uint256 id) internal view returns (string memory) {
        return _svg(renderer.unrevealedTokenURI(id));
    }

    function test_unrevealed_jsonShape() public view {
        string memory json = _json(renderer.unrevealedTokenURI(42));
        assertEq(vm.parseJsonString(json, ".name"), unicode"WORDBANK #42 — Unrevealed", "name carries id");
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "Unrevealed", "status attr");
        assertTrue(vm.parseJsonString(json, ".description").contains("snipe-proof"), "sealed description");
        // Zero trait leakage: none of the post-reveal trait attributes appear.
        assertFalse(json.contains('"trait_type":"Word"'), "no Word attr");
        assertFalse(json.contains('"trait_type":"Material"'), "no Material attr");
        assertFalse(json.contains('"trait_type":"1/1"'), "no 1/1 attr");
    }

    function test_unrevealed_svgStructure() public view {
        string memory svg = _unrevealedSvg(7);
        assertTrue(svg.startsWith("<svg xmlns="), "svg open");
        assertTrue(svg.endsWith("</svg>"), "svg close");
        assertTrue(svg.contains("@font-face{font-family:'WB'"), "reuses embedded font");
        assertTrue(svg.contains(">WORDBANK</text>"), "wordmark");
        assertTrue(svg.contains(">UNREVEALED</text>"), "unrevealed label");
        assertTrue(svg.contains('<g id="tok"'), "numeral run present");
        // Single solid backdrop, no gradients — same discipline as the real art.
        assertEq(_count(svg, '<rect width="1000" height="1000"'), 1, "single backdrop rect");
        assertEq(_count(svg, "Gradient"), 0, "no gradients");
    }

    /// @notice The core provenance guarantee: two different tokenIds produce art
    ///         that is byte-identical everywhere EXCEPT the `#id` numeral run — no
    ///         trait divergence is even possible, since no trait is an input.
    function test_unrevealed_differsOnlyByIdText() public view {
        string memory a = _unrevealedSvg(1);
        string memory b = _unrevealedSvg(4242);

        // Everything up to the token-id group is identical, byte for byte.
        uint256 ia = a.indexOf('<g id="tok"');
        uint256 ib = b.indexOf('<g id="tok"');
        assertTrue(ia != LibString.NOT_FOUND && ib != LibString.NOT_FOUND, "id group present");
        assertEq(a.slice(0, ia), b.slice(0, ib), "art before the id is identical across tokens");

        // And the id groups themselves differ (different digits drawn).
        assertTrue(!a.slice(ia).eq(b.slice(ib)), "id group differs by id");

        // Suffix after the id group is just the closing tag — identical.
        assertTrue(a.endsWith("</g></svg>"), "id group is the last element");
        assertTrue(b.endsWith("</g></svg>"), "id group is the last element");
    }

    function test_unrevealed_deterministicBytes() public view {
        assertTrue(renderer.unrevealedTokenURI(99).eq(renderer.unrevealedTokenURI(99)), "stable bytes");
    }

    function test_unrevealed_revertsBeforeSeal() public {
        Renderer r = new Renderer();
        vm.expectRevert(Renderer.NotSealed.selector);
        r.unrevealedTokenURI(1);
    }

    /// @notice Writes the placeholder SVG (single- and multi-digit ids) to the
    ///         snapshot dir for eyeballing alongside the per-material snapshots.
    function test_unrevealed_snapshot() public {
        vm.createDir("test/snapshots", true);
        uint256[3] memory ids = [uint256(1), 888, 10000];
        for (uint256 i; i < ids.length; ++i) {
            string memory svg = _unrevealedSvg(ids[i]);
            assertTrue(svg.endsWith("</svg>"), "closed");
            vm.writeFile(string.concat("test/snapshots/unrevealed_", ids[i].toString(), ".svg"), svg);
        }
    }

    // ------------------------------------------------------------------
    // Constraint enforcement (MUST revert on out-of-range)
    // ------------------------------------------------------------------

    function test_revert_materialOutOfRange() public {
        (uint256 mats) = renderer.materialCount();
        vm.expectRevert(Renderer.TraitOutOfRange.selector);
        renderer.tokenURI(1, _wd("ember", Category.NOUN, uint8(mats), 0, 0, false));
    }

    function test_revert_inkOutOfRange() public {
        (uint256 inks,) = renderer.constraintTableSizes(0);
        vm.expectRevert(Renderer.TraitOutOfRange.selector);
        renderer.tokenURI(1, _wd("ember", Category.NOUN, 0, uint8(inks), 0, false));
    }

    function test_revert_backgroundOutOfRange() public {
        (, uint256 bgs) = renderer.constraintTableSizes(0);
        vm.expectRevert(Renderer.TraitOutOfRange.selector);
        renderer.tokenURI(1, _wd("ember", Category.NOUN, 0, 0, uint8(bgs), false));
    }

    function testFuzz_inRangeAlwaysRenders(uint8 inkIdx, uint8 bgIdx, uint8 wordLen) public view {
        (uint256 inks, uint256 bgs) = renderer.constraintTableSizes(0);
        inkIdx = uint8(bound(inkIdx, 0, inks - 1));
        bgIdx = uint8(bound(bgIdx, 0, bgs - 1));
        wordLen = uint8(bound(wordLen, 1, 15));
        bytes memory w = new bytes(wordLen);
        for (uint256 i; i < wordLen; ++i) {
            w[i] = bytes1(uint8(97 + (uint256(keccak256(abi.encode(inkIdx, bgIdx, i))) % 26)));
        }
        string memory svg = _svg(renderer.tokenURI(1, _wd(string(w), Category.ADV, 0, inkIdx, bgIdx, false)));
        assertTrue(svg.contains(string.concat(">", string(w), "</text>")), "word rendered");
        assertTrue(svg.endsWith("</svg>"), "closed");
    }

    // ------------------------------------------------------------------
    // Loading lifecycle
    // ------------------------------------------------------------------

    function test_lifecycle_notSealedReverts() public {
        Renderer r = new Renderer();
        vm.expectRevert(Renderer.NotSealed.selector);
        r.tokenURI(1, _wd("ember", Category.NOUN, 0, 0, 0, false));
    }

    function test_lifecycle_sealRequiresAssets() public {
        Renderer r = new Renderer();
        vm.expectRevert(Renderer.InvalidAsset.selector);
        r.seal();
    }

    function test_lifecycle_loadersRevertAfterSeal() public {
        bytes[] memory chunks = new bytes[](1);
        chunks[0] = hex"01";
        vm.expectRevert(Renderer.Sealed.selector);
        renderer.addFontChunks(chunks);
        vm.expectRevert(Renderer.Sealed.selector);
        renderer.addHonorsArt("Moon", bytes("<g></g>"));
        vm.expectRevert(Renderer.Sealed.selector);
        renderer.seal();
    }

    function test_lifecycle_onlyAdmin() public {
        Renderer r = new Renderer();
        bytes[] memory chunks = new bytes[](1);
        chunks[0] = hex"01";
        vm.prank(address(0xBEEF));
        vm.expectRevert(Renderer.NotAdmin.selector);
        r.addFontChunks(chunks);
    }

    function test_fontData_roundTrips() public view {
        bytes memory onchain = renderer.fontData();
        assertGt(onchain.length, 5000, "font present");
        // WOFF2 magic: "wOF2"
        assertEq(uint8(onchain[0]), 0x77);
        assertEq(uint8(onchain[1]), 0x4F);
        assertEq(uint8(onchain[2]), 0x46);
        assertEq(uint8(onchain[3]), 0x32);
    }

    // ------------------------------------------------------------------
    // Snapshots â€” every permitted combination for every material
    // ------------------------------------------------------------------

    function test_snapshot_everyPermittedCombination() public {
        vm.createDir("test/snapshots", true);
        uint256 mats = renderer.materialCount();
        string[4] memory words = ["ember", "wander", "luminous", "softly"];
        uint256 total;
        for (uint8 m; m < mats; ++m) {
            (string memory matName,) = renderer.materialInfo(m);
            (uint256 inks, uint256 bgs) = renderer.constraintTableSizes(m);
            for (uint8 i; i < inks; ++i) {
                for (uint8 b; b < bgs; ++b) {
                    string memory word = words[(uint256(m) + i + b) % 4];
                    Category cat = Category((uint256(m) + i + b) % 4);
                    string memory svg = _svg(renderer.tokenURI(1, _wd(word, cat, m, i, b, false)));
                    assertTrue(svg.endsWith("</svg>"), "closed");
                    vm.writeFile(
                        string.concat(
                            "test/snapshots/",
                            matName.lower(),
                            "_i",
                            uint256(i).toString(),
                            "_b",
                            uint256(b).toString(),
                            ".svg"
                        ),
                        svg
                    );
                    ++total;
                }
            }
        }
        console2.log("snapshot combinations rendered:", total);
    }

    // ------------------------------------------------------------------
    // Gas documentation (storage writes are one-time deploy cost)
    // ------------------------------------------------------------------

    function test_gas_assetLoading() public {
        Renderer r = new Renderer();
        uint256 g0 = gasleft();
        RendererAssets.loadFont(r);
        uint256 gFont = g0 - gasleft();
        g0 = gasleft();
        RendererAssets.loadMaterials(r);
        uint256 gMats = g0 - gasleft();
        g0 = gasleft();
        RendererAssets.loadHonors(r);
        uint256 gHonors = g0 - gasleft();
        console2.log("gas: font storage", gFont);
        console2.log("gas: material storage", gMats);
        console2.log("gas: honors storage", gHonors);
    }
}
