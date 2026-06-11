// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRenderer} from "./interfaces/IRenderer.sol";
import {Category, WordData} from "./interfaces/Types.sol";
import {Numerals} from "./libraries/Numerals.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SSTORE2} from "solady/utils/SSTORE2.sol";

/// @title  Renderer — fully onchain tokenURI assembly for WORDBANK
/// @author Agent 2 (renderer-art)
/// @notice Holds the collection's shared visual assets — the subsetted Fraunces
///         (SIL OFL 1.1) font in SSTORE2 chunks, one reusable SVG fragment per
///         material, the validInks/validBackgrounds constraint tables, and the
///         25 bespoke honors path artworks — and assembles a self-contained
///         `data:application/json;base64` URI per token. No per-token state:
///         everything token-specific arrives in `WordData` (frozen interface).
/// @dev    Asset loading is admin-only and one-way sealed: after `seal()` the
///         contract is immutable content. Visual traits NEVER influence gameplay
///         (system invariant 6) — nothing here is read by BountyEngine or
///         RewardsDistributor.
contract Renderer is IRenderer {
    using LibString for uint256;
    using LibString for string;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    /// @notice One permitted ink for a material: display name + SVG fill color.
    struct Ink {
        string name;
        string color; // "#rrggbb"
    }

    /// @notice One permitted backdrop color for a material (always a solid rect).
    struct Background {
        string name;
        string color; // "#rrggbb"
    }

    /// @notice A material surface: display name, rarity tier, SSTORE2-stored SVG fragment,
    ///         and the usable text width of its writing area (inset materials like the
    ///         stained-glass pane are narrower than a full sheet).
    struct Material {
        string name;
        uint8 tier; // index into _TIERS
        uint16 safeWidth; // max word width in px (canvas is 1000 wide)
        address fragment; // SSTORE2 pointer to the <g>…</g> SVG fragment
    }

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    /// @notice Caller is not the admin.
    error NotAdmin();
    /// @notice Asset loading attempted after `seal()`.
    error Sealed();
    /// @notice tokenURI requested before all assets were loaded and sealed.
    error NotSealed();
    /// @notice Trait index outside the material's constraint table (or unknown material).
    error TraitOutOfRange();
    /// @notice Honors token whose bespoke artwork was never loaded.
    error HonorsArtMissing();
    /// @notice Loader argument invalid (empty data, bad tier, length mismatch).
    error InvalidAsset();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// @notice Font chunk appended (SSTORE2).
    event FontChunkAdded(uint256 indexed index, uint256 bytes_);
    /// @notice Material registered with its constraint tables.
    event MaterialAdded(uint8 indexed id, string name, uint8 tier, uint256 inks, uint256 backgrounds);
    /// @notice Bespoke honors artwork stored for a word.
    event HonorsArtAdded(string word, uint256 bytes_);
    /// @notice Content permanently sealed.
    event ContentSealed(uint256 materials, uint256 fontChunks);

    // ------------------------------------------------------------------
    // Storage (write-once, then sealed)
    // ------------------------------------------------------------------

    /// @notice Deployer; may load assets until sealed. Holds no power afterwards.
    address public immutable admin;

    /// @notice True once content is frozen forever.
    bool public contentSealed;

    /// @notice SSTORE2 pointers to the subsetted WOFF2 font, in order.
    address[] public fontChunks;

    /// @notice Registered materials, index == `WordData.material`.
    Material[] private _materials;

    /// @notice materialId => permitted inks (index == `WordData.ink`).
    mapping(uint256 => Ink[]) private _inks;

    /// @notice materialId => permitted backdrop colors (index == `WordData.background`).
    mapping(uint256 => Background[]) private _backgrounds;

    /// @notice keccak256(word) => SSTORE2 pointer to the bespoke honors SVG fragment.
    mapping(bytes32 => address) private _honorsArt;

    string private constant _SVG_HEADER =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000" width="1000" height="1000">';

    // ------------------------------------------------------------------
    // Construction / loading
    // ------------------------------------------------------------------

    constructor() {
        admin = msg.sender;
    }

    modifier onlyAdminUnsealed() {
        if (msg.sender != admin) revert NotAdmin();
        if (contentSealed) revert Sealed();
        _;
    }

    /// @notice Appends font data chunks (subsetted WOFF2 bytes, split offchain at 24,575 bytes).
    /// @param  chunks Raw byte chunks, concatenated in order at render time.
    function addFontChunks(bytes[] calldata chunks) external onlyAdminUnsealed {
        for (uint256 i; i < chunks.length; ++i) {
            if (chunks[i].length == 0) revert InvalidAsset();
            fontChunks.push(SSTORE2.write(chunks[i]));
            emit FontChunkAdded(fontChunks.length - 1, chunks[i].length);
        }
    }

    /// @notice Registers the next material (id = current count) with its SVG fragment
    ///         and full ink/background constraint tables.
    /// @param  name      Display name, e.g. "Paper".
    /// @param  tier      0 Common, 1 Uncommon, 2 Rare, 3 Epic, 4 Legendary.
    /// @param  safeWidth Usable text width of the writing area in px (300–760).
    /// @param  fragment  The material's `<g>…</g>` SVG fragment (drawn between the
    ///                   backdrop rect and the word text).
    /// @param  inks      Permitted inks; `WordData.ink` indexes this array.
    /// @param  bgs       Permitted backdrop colors; `WordData.background` indexes this array.
    function addMaterial(
        string calldata name,
        uint8 tier,
        uint16 safeWidth,
        bytes calldata fragment,
        Ink[] calldata inks,
        Background[] calldata bgs
    ) external onlyAdminUnsealed {
        if (bytes(name).length == 0 || fragment.length == 0 || inks.length == 0 || bgs.length == 0 || tier > 4) {
            revert InvalidAsset();
        }
        if (safeWidth < 300 || safeWidth > 760) revert InvalidAsset();
        uint8 id = uint8(_materials.length);
        _materials.push(Material({name: name, tier: tier, safeWidth: safeWidth, fragment: SSTORE2.write(fragment)}));
        for (uint256 i; i < inks.length; ++i) {
            _inks[id].push(inks[i]);
        }
        for (uint256 i; i < bgs.length; ++i) {
            _backgrounds[id].push(bgs[i]);
        }
        emit MaterialAdded(id, name, tier, inks.length, bgs.length);
    }

    /// @notice Stores the bespoke 1/1 SVG fragment for one honors word.
    /// @param  word The exact stored word string (e.g. "Rekt"); lookup key at render time.
    /// @param  art  Full-canvas `<g>…</g>` path artwork replacing the standard text element.
    function addHonorsArt(string calldata word, bytes calldata art) external onlyAdminUnsealed {
        if (bytes(word).length == 0 || art.length == 0) revert InvalidAsset();
        _honorsArt[keccak256(bytes(word))] = SSTORE2.write(art);
        emit HonorsArtAdded(word, art.length);
    }

    /// @notice Permanently freezes all content. Irreversible; required before tokenURI serves.
    function seal() external onlyAdminUnsealed {
        if (fontChunks.length == 0 || _materials.length == 0) revert InvalidAsset();
        contentSealed = true;
        emit ContentSealed(_materials.length, fontChunks.length);
    }

    // ------------------------------------------------------------------
    // IRenderer
    // ------------------------------------------------------------------

    /// @inheritdoc IRenderer
    function tokenURI(uint256 tokenId, WordData calldata data) external view returns (string memory) {
        if (!contentSealed) revert NotSealed();
        if (data.material >= _materials.length) revert TraitOutOfRange();
        Material storage mat = _materials[data.material];
        if (data.ink >= _inks[data.material].length) revert TraitOutOfRange();
        if (data.background >= _backgrounds[data.material].length) revert TraitOutOfRange();
        Ink storage ink = _inks[data.material][data.ink];
        Background storage bg = _backgrounds[data.material][data.background];

        string memory svg = _buildSVG(data, mat, ink, bg);
        string memory json = _buildJSON(tokenId, data, mat, ink, bg, svg);
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @inheritdoc IRenderer
    function unrevealedTokenURI(uint256 tokenId) external view returns (string memory) {
        if (!contentSealed) revert NotSealed();
        // No trait inputs at all: the art is identical for every token, varying
        // only by the displayed #id — structurally incapable of leaking the
        // eventual word/traits (the snipe-proof guarantee).
        string memory svg = _buildUnrevealedSVG(tokenId);
        string memory json = _buildUnrevealedJSON(tokenId, svg);
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // ------------------------------------------------------------------
    // Views (verification / frontend)
    // ------------------------------------------------------------------

    /// @notice Number of registered materials.
    function materialCount() external view returns (uint256) {
        return _materials.length;
    }

    /// @notice Material display name and rarity tier.
    function materialInfo(uint8 id) external view returns (string memory name, uint8 tier) {
        if (id >= _materials.length) revert TraitOutOfRange();
        Material storage m = _materials[id];
        return (m.name, m.tier);
    }

    /// @notice Sizes of a material's constraint tables.
    /// @dev    Not named `table*` — Foundry treats that prefix as a table-test marker.
    function constraintTableSizes(uint8 id) external view returns (uint256 inks, uint256 backgrounds) {
        if (id >= _materials.length) revert TraitOutOfRange();
        return (_inks[id].length, _backgrounds[id].length);
    }

    /// @notice Permitted ink at `validInks[material][i]`.
    function inkAt(uint8 material, uint8 i) external view returns (string memory name, string memory color) {
        if (material >= _materials.length || i >= _inks[material].length) revert TraitOutOfRange();
        Ink storage k = _inks[material][i];
        return (k.name, k.color);
    }

    /// @notice Permitted backdrop at `validBackgrounds[material][i]`.
    function backgroundAt(uint8 material, uint8 i) external view returns (string memory name, string memory color) {
        if (material >= _materials.length || i >= _backgrounds[material].length) revert TraitOutOfRange();
        Background storage b = _backgrounds[material][i];
        return (b.name, b.color);
    }

    /// @notice True if a bespoke honors artwork is stored for `word`.
    function hasHonorsArt(string calldata word) external view returns (bool) {
        return _honorsArt[keccak256(bytes(word))] != address(0);
    }

    /// @notice The full subsetted font bytes (concatenated chunks), for offchain verification.
    function fontData() public view returns (bytes memory data) {
        uint256 n = fontChunks.length;
        for (uint256 i; i < n; ++i) {
            data = bytes.concat(data, SSTORE2.read(fontChunks[i]));
        }
    }

    // ------------------------------------------------------------------
    // Internal assembly
    // ------------------------------------------------------------------

    function _buildSVG(WordData calldata data, Material storage mat, Ink storage ink, Background storage bg)
        internal
        view
        returns (string memory)
    {
        string memory wordMark;
        if (data.honors) {
            address art = _honorsArt[keccak256(bytes(data.word))];
            if (art == address(0)) revert HonorsArtMissing();
            wordMark = string(SSTORE2.read(art));
        } else {
            wordMark = string.concat(
                '<text x="500" y="528" text-anchor="middle" font-family="WB,serif" font-size="',
                _fontSize(bytes(data.word).length, mat.safeWidth).toString(),
                '" fill="',
                ink.color,
                '">',
                data.word,
                "</text>"
            );
        }

        return string.concat(
            _SVG_HEADER,
            "<defs><style>@font-face{font-family:'WB';src:url(data:font/woff2;base64,",
            Base64.encode(fontData()),
            ") format('woff2')}</style></defs>",
            '<rect width="1000" height="1000" fill="',
            bg.color,
            '"/>',
            string(SSTORE2.read(mat.fragment)),
            wordMark,
            "</svg>"
        );
    }

    function _buildJSON(
        uint256 tokenId,
        WordData calldata data,
        Material storage mat,
        Ink storage ink,
        Background storage bg,
        string memory svg
    ) internal view returns (string memory) {
        string memory attrs = string.concat(
            '[{"trait_type":"Word","value":"',
            data.word,
            '"},{"trait_type":"Category","value":"',
            _categoryName(data.category),
            '"},{"trait_type":"Material","value":"',
            mat.name,
            '"},{"trait_type":"Ink","value":"',
            data.honors ? "Bespoke Lettering" : ink.name,
            '"},{"trait_type":"Background","value":"',
            bg.name,
            '"},{"trait_type":"Rarity Tier","value":"',
            _tierName(mat.tier),
            '"},{"trait_type":"1/1","value":"',
            data.honors ? "Yes" : "No",
            '"}]'
        );

        return string.concat(
            '{"name":"WORDBANK #',
            tokenId.toString(),
            unicode" — ",
            data.word,
            '","description":"',
            _description(),
            '","attributes":',
            attrs,
            ',"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '"}'
        );
    }

    function _description() internal pure returns (string memory) {
        return "One of 10,000 words stored and rendered fully onchain, backed by 1,000 bound WORD. "
            "Visual rarity (material, ink, background, 1/1 lettering) is purely aesthetic and has zero effect on gameplay: "
            "bounty odds, rewards, and backing are identical for every word.";
    }

    // ------------------------------------------------------------------
    // Pre-reveal placeholder assembly
    // ------------------------------------------------------------------

    /// @dev The sealed "specimen card": ink ground, a double keyline frame, the
    ///      WORDBANK wordmark and an UNREVEALED label set in the shared onchain
    ///      WB font, a three-dot seal, and the token's #id drawn from the baked
    ///      Fraunces numeral outlines. Matches the dApp's "Before the Reveal"
    ///      mint card (app/app/mint/page.tsx). Colors are the brand palette
    ///      (app globals.css), themselves sampled from the Renderer's own tables.
    function _buildUnrevealedSVG(uint256 tokenId) internal view returns (string memory) {
        return string.concat(
            _SVG_HEADER,
            "<defs><style>@font-face{font-family:'WB';src:url(data:font/woff2;base64,",
            Base64.encode(fontData()),
            ") format('woff2')}",
            ".wb{font-family:'WB',serif;fill:#d8cdb0;text-anchor:middle}</style></defs>",
            '<rect width="1000" height="1000" fill="#1b1b22"/>',
            '<rect x="60" y="60" width="880" height="880" rx="22" fill="none" stroke="#f6f1e4" stroke-opacity="0.30" stroke-width="2.5"/>',
            '<rect x="84" y="84" width="832" height="832" rx="14" fill="none" stroke="#f6f1e4" stroke-opacity="0.14" stroke-width="1.5"/>',
            '<text class="wb" x="500" y="300" font-size="46" letter-spacing="18">WORDBANK</text>',
            '<g fill="#f6f1e4"><circle cx="454" cy="470" r="13"/><circle cx="500" cy="470" r="13"/><circle cx="546" cy="470" r="13"/></g>',
            '<text class="wb" x="500" y="575" font-size="30" letter-spacing="14">UNREVEALED</text>',
            '<line x1="430" y1="662" x2="570" y2="662" stroke="#f6f1e4" stroke-opacity="0.22" stroke-width="1.5"/>',
            _numeralRun(tokenId),
            "</svg>"
        );
    }

    /// @dev Draws `#<id>` from the baked Fraunces numeral outlines (Numerals lib),
    ///      laid out by integer pen-advance and centered on x=500 at baseline 760.
    ///      The WB font subset carries no digits, so the id cannot use `<text>`.
    function _numeralRun(uint256 tokenId) internal pure returns (string memory) {
        uint256 nDigits = 1;
        for (uint256 t = tokenId; t >= 10; t /= 10) {
            ++nDigits;
        }
        uint256[] memory digits = new uint256[](nDigits);
        uint256 v = tokenId;
        for (uint256 i = nDigits; i > 0; --i) {
            digits[i - 1] = v % 10;
            v /= 10;
        }

        // Total pen width = '#' glyph + each digit, for centering.
        uint256 total = Numerals.hashAdvance();
        for (uint256 i; i < nDigits; ++i) {
            total += Numerals.advance(digits[i]);
        }
        uint256 startX = 500 - total / 2;

        // The '#' sits at the pen origin; digits follow at the running advance.
        string memory glyphs = string.concat("<path d='", Numerals.hashPath(), "'/>");
        uint256 pen = Numerals.hashAdvance();
        for (uint256 i; i < nDigits; ++i) {
            glyphs = string.concat(
                glyphs, "<path transform='translate(", pen.toString(), " 0)' d='", Numerals.path(digits[i]), "'/>"
            );
            pen += Numerals.advance(digits[i]);
        }
        return
            string.concat(
                '<g id="tok" fill="#f6f1e4" transform="translate(', startX.toString(), ' 760)">', glyphs, "</g>"
            );
    }

    function _buildUnrevealedJSON(uint256 tokenId, string memory svg) internal pure returns (string memory) {
        return string.concat(
            '{"name":"WORDBANK #',
            tokenId.toString(),
            unicode" — Unrevealed",
            '","description":"',
            _unrevealedDescription(),
            '","attributes":[{"trait_type":"Status","value":"Unrevealed"}]',
            ',"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '"}'
        );
    }

    function _unrevealedDescription() internal pure returns (string memory) {
        return "Sealed until the collection's provenance offset is fixed. Until then no one - including the team - "
            "can know which of the 10,000 words or which visual traits this token holds: the assignment is committed "
            "in advance and snipe-proof. Its 1,000 bound WORD backing is already in place. The full word art renders "
            "here, fully onchain, the moment the offset is revealed.";
    }

    /// @dev Display size that keeps any word inside the material's writing area:
    ///      size = safeWidth / (0.55 * len), Fraunces at wght 564 averaging ~0.55em
    ///      advance per glyph, capped at 190 for short words.
    function _fontSize(uint256 len, uint16 safeWidth) internal pure returns (uint256) {
        if (len == 0) len = 1;
        uint256 size = (uint256(safeWidth) * 1818) / (len * 1000);
        return size > 190 ? 190 : size;
    }

    function _categoryName(Category c) internal pure returns (string memory) {
        if (c == Category.NOUN) return "Noun";
        if (c == Category.VERB) return "Verb";
        if (c == Category.ADJ) return "Adjective";
        return "Adverb";
    }

    function _tierName(uint8 t) internal pure returns (string memory) {
        if (t == 0) return "Common";
        if (t == 1) return "Uncommon";
        if (t == 2) return "Rare";
        if (t == 3) return "Epic";
        return "Legendary";
    }
}
