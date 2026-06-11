// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

import {IntegrationBase} from "./IntegrationBase.sol";
import {Renderer} from "../../src/Renderer.sol";
import {WordData} from "../../src/interfaces/Types.sol";

/// @title  Pre-reveal placeholder — real Renderer, full lifecycle (agent 6)
/// @notice interfaces-v4: `WordBank.tokenURI` delegates to the REAL Renderer's
///         `unrevealedTokenURI` while `!offsetSet` (a branded, trait-free, snipe-proof
///         placeholder), and to the trait-bearing `tokenURI(id, data)` after the provenance
///         reveal. The Renderer is unit-tested in isolation and WordBank's placeholder branch
///         is unit-tested with MockRenderer; this suite proves the wiring END TO END against
///         the real deployed stack with the Renderer content sealed.
contract PrerevealPlaceholderTest is IntegrationBase {
    using LibString for string;

    string internal constant JSON_PREFIX = "data:application/json;base64,";
    string internal constant SVG_PREFIX = "data:image/svg+xml;base64,";

    function setUp() public {
        _deployProtocol();
        _sealRenderer(); // launch-ordering precondition: Renderer sealed before mint opens
    }

    // ─────────────────────────────── decode helpers ────────────────────────────────────
    // Mirror the Renderer unit suite: outer data URI → JSON → embedded SVG.

    function _json(string memory uri) internal pure returns (string memory) {
        require(uri.startsWith(JSON_PREFIX), "bad json prefix");
        return string(Base64.decode(uri.slice(bytes(JSON_PREFIX).length)));
    }

    function _svg(string memory uri) internal view returns (string memory) {
        string memory image = vm.parseJsonString(_json(uri), ".image");
        require(image.startsWith(SVG_PREFIX), "bad svg prefix");
        return string(Base64.decode(image.slice(bytes(SVG_PREFIX).length)));
    }

    // ───────────────────── pre-reveal placeholder → revealed art ───────────────────────

    function test_prereveal_placeholder_thenRevealedArt() public {
        // Open the public sale and mint two tokens BEFORE sellout — the offset is unset.
        vm.startPrank(admin);
        bank.setSaleConfig(0, PUBLIC_SUPPLY, EB_PRICE, PUB_PRICE, 1);
        bank.openEarlyBird();
        bank.closeEarlyBird();
        bank.openPublicSale();
        vm.stopPrank();

        vm.prank(alice);
        bank.publicMint{value: 2 * PUB_PRICE}(2);
        assertFalse(bank.offsetSet(), "still pre-reveal");

        // ── Pre-reveal: tokenURI delegates to the REAL Renderer's unrevealedTokenURI. ──
        uint256 g = gasleft();
        string memory uri1 = bank.tokenURI(1);
        console2.log("pre-reveal tokenURI (unrevealed placeholder)", g - gasleft());
        string memory uri2 = bank.tokenURI(2);

        // Well-formed data:application/json;base64 with an embedded SVG image (NOT the old
        // text-only / no-image placeholder).
        assertTrue(uri1.startsWith(JSON_PREFIX), "json data uri");
        string memory json1 = _json(uri1);
        string memory image1 = vm.parseJsonString(json1, ".image");
        assertTrue(image1.startsWith(SVG_PREFIX), "placeholder carries an SVG image");

        // The WordBank value IS the real Renderer's unrevealedTokenURI output (wiring proof).
        assertEq(uri1, renderer.unrevealedTokenURI(1), "tokenURI delegates to renderer.unrevealedTokenURI");
        assertEq(uri2, renderer.unrevealedTokenURI(2), "id 2 delegates too");

        // Name carries the id + the "Unrevealed" status marker; no word/trait attribute exists.
        assertEq(vm.parseJsonString(json1, ".name"), unicode"WORDBANK #1 — Unrevealed", "name carries #id");
        assertEq(vm.parseJsonString(json1, ".attributes[0].value"), "Unrevealed", "status attr");

        // ── End-to-end zero-leakage: two ids' placeholder art is byte-identical EXCEPT the
        //    `#id` numeral group — structurally incapable of leaking the eventual word/traits. ──
        string memory s1 = _svg(uri1);
        string memory s2 = _svg(uri2);
        uint256 i1 = s1.indexOf('<g id="tok"');
        uint256 i2 = s2.indexOf('<g id="tok"');
        assertTrue(i1 != LibString.NOT_FOUND && i2 != LibString.NOT_FOUND, "id group present");
        assertEq(s1.slice(0, i1), s2.slice(0, i2), "art before the #id is byte-identical across tokens");
        assertTrue(!s1.slice(i1).eq(s2.slice(i2)), "only the #id group differs");

        // ── Full provenance path: sell out the public allocation → reveal → build registry. ──
        uint256 remaining = PUBLIC_SUPPLY - 2;
        while (remaining > 0) {
            uint256 take = remaining < 3_300 ? remaining : 3_300;
            vm.prank(alice);
            bank.publicMint{value: take * PUB_PRICE}(take);
            remaining -= take;
        }
        assertTrue(bank.offsetTargetBlock() != 0, "offset armed at 9,800 sellout");
        vm.roll(bank.offsetTargetBlock() + 1);
        bank.revealOffset();
        while (!bank.registrySynced()) {
            bank.buildRegistry(2_500);
        }
        assertTrue(bank.offsetSet(), "offset revealed");

        // ── The SAME tokens now return trait-bearing art via renderer.tokenURI(id, data). ──
        // Pick an in-range token: the fixture's synthetic trait data (ink = idx%5) can exceed a
        // 4-ink material's table — a fixture artifact, never the real wordlist, which is in-range
        // by construction. The scan finds a token the real Renderer renders.
        uint256 id = _firstInRangeToken();
        g = gasleft();
        string memory art = bank.tokenURI(id);
        console2.log("post-reveal tokenURI (trait-bearing art)   ", g - gasleft());
        assertEq(art, renderer.tokenURI(id, bank.wordDataOf(id)), "post-reveal: trait-bearing Renderer art");
        assertTrue(!art.eq(renderer.unrevealedTokenURI(id)), "no longer the placeholder");
        // The revealed art carries the real word as its first attribute.
        assertEq(vm.parseJsonString(_json(art), ".attributes[0].value"), bank.wordOf(id), "word attribute present");
    }

    /// @dev First minted token whose slot traits are in-range for the real Renderer's
    ///      per-material constraint tables (see note in the test above).
    function _firstInRangeToken() internal view returns (uint256) {
        uint256 minted = bank.totalMinted();
        for (uint256 id = 1; id <= minted; ++id) {
            WordData memory d = bank.wordDataOf(id);
            (uint256 inks, uint256 bgs) = renderer.constraintTableSizes(d.material);
            if (d.ink < inks && d.background < bgs) return id;
        }
        revert("no in-range token");
    }
}

/// @notice Edge / launch-ordering precondition: if the Renderer's content is NOT sealed when a
///         pre-reveal token's `tokenURI` is queried, the call reverts cleanly `NotSealed`. The
///         runbook therefore seals the Renderer BEFORE the mint opens; this pins that ordering.
contract PrerevealUnsealedRendererTest is IntegrationBase {
    function setUp() public {
        _deployProtocol(); // NOTE: _sealRenderer() deliberately NOT called — content unsealed
    }

    function test_prereveal_tokenURI_revertsWhenRendererNotSealed() public {
        // Minting does NOT require a sealed Renderer; only tokenURI does.
        vm.startPrank(admin);
        bank.setSaleConfig(0, PUBLIC_SUPPLY, EB_PRICE, PUB_PRICE, 1);
        bank.openEarlyBird();
        bank.closeEarlyBird();
        bank.openPublicSale();
        vm.stopPrank();
        vm.prank(alice);
        bank.publicMint{value: PUB_PRICE}(1);
        assertFalse(bank.offsetSet());

        // Pre-reveal tokenURI → renderer.unrevealedTokenURI → reverts NotSealed.
        vm.expectRevert(Renderer.NotSealed.selector);
        bank.tokenURI(1);
    }
}
