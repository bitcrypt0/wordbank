// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IWordToken — WORD ERC-20, 11,000,000e18 minted cap, burnable to a dynamic backing floor
/// @notice v3 IN PROGRESS (interfaces-v3, 2026-06-13). Do not edit without overseer approval and
///         a tag bump. This file lands together with WordToken (agent 1) and the BurnEngine/FeeHook
///         rewire (agent 5); the tag bumps to v3 once both are in.
/// @dev    Implemented by agent 1 (token-bank). Consumed by WordBank (backing mints, unbind
///         release), the BurnEngine (buy-and-burn), and deployment scripts (liquidity mint).
///         No transfer hooks, no burn-on-transfer — bound backing is physically held by
///         WordBank, so liquid WORD is a plain ERC-20. The ONLY burn path is `burn`, callable
///         solely by the BurnEngine and floored at the LIVE backing requirement so the NFT
///         backing is never eroded. Interface is self-contained (no OZ import) so the freeze
///         does not depend on library paths; the implementation should use OZ v5.
///
///         v2 change (2026-06-12): added the buy-and-burn surface (`burn`, `BURN_FLOOR`,
///         `burner`, `burnedTotal`, `burnComplete`).
///         v3 change (2026-06-13): the burn floor is now DYNAMIC — it tracks the live backing
///         requirement `WordBank.totalAlive() * 1000e18` instead of a fixed 10,000,000e18.
///         Unbinding an NFT lowers `totalAlive` and frees its 1,000 WORD into circulation, so
///         that freed WORD becomes burnable. There is no permanent completion: burning pauses
///         when `totalSupply == currentBurnFloor()` and resumes when a later unbind lowers the
///         floor. Removed `BURN_FLOOR()`/`burnComplete()`/`BurnComplete`; added
///         `currentBurnFloor()`/`burnableExcess()`. Post-seal invariant:
///         `totalAlive*1000e18 <= totalSupply <= 11,000,000e18`, both supply and floor
///         monotonically non-increasing.
interface IWordToken {
    // ───────────────────────────── standard ERC-20 surface ─────────────────────────────

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);

    // ───────────────────────────── WORDBANK-specific surface ───────────────────────────

    /// @notice Emitted when the admin mints from the liquidity allotment.
    event LiquidityMinted(address indexed to, uint256 amount, uint256 liquidityMintedTotal);
    /// @notice Emitted exactly once, when minting is permanently sealed.
    event MintingSealed(uint256 finalTotalSupply);
    /// @notice Emitted on every buy-and-burn.
    event Burned(address indexed burner, uint256 amount, uint256 newTotalSupply);

    /// @notice Mints backing tokens. Callable ONLY by WordBank, ONLY during the NFT mint
    ///         phase, always 1,000e18 per NFT minted, always to the WordBank itself.
    /// @dev    Cumulative backing mints can never exceed 10,000,000e18 (10,000 × 1,000e18).
    function mint(address to, uint256 amount) external;

    /// @notice Mints from the admin liquidity allotment for seeding the canonical pool.
    /// @dev    Admin-only. Cumulative cap 1,000,000e18 — reverts beyond it, even for the admin.
    function mintLiquidity(address to, uint256 amount) external;

    /// @notice Permanently seals all minting. Callable once, only after the NFT mint phase has
    ///         closed AND the liquidity allotment is fully minted. After this, totalSupply()
    ///         starts at 11_000_000e18 and only ever decreases via `burn` toward the live
    ///         backing floor — it can never rise again.
    function sealMinting() external;

    /// @notice Cumulative amount minted from the liquidity allotment (≤ 1,000,000e18).
    function liquidityMinted() external view returns (uint256);

    /// @notice True once minting is permanently sealed.
    function mintingSealed() external view returns (bool);

    // ───────────────────────────── buy-and-burn surface (v3) ───────────────────────────

    /// @notice The only address permitted to call `burn` — the BurnEngine.
    function burner() external view returns (address);

    /// @notice The live supply floor: `WordBank.totalAlive() * 1000e18`. Burning can never
    ///         drop totalSupply below this, so every alive NFT's 1,000-WORD backing is always
    ///         fully covered. The floor falls as NFTs unbind (each unbind frees 1,000 WORD into
    ///         circulation and lowers totalAlive), which is exactly what makes that freed WORD
    ///         burnable.
    function currentBurnFloor() external view returns (uint256);

    /// @notice WORD currently burnable: `totalSupply - currentBurnFloor()`, or 0 when supply is
    ///         already at the floor. The amount the BurnEngine may still buy and destroy.
    function burnableExcess() external view returns (uint256);

    /// @notice Burns `amount` WORD from the caller's balance. Callable ONLY by `burner`.
    /// @dev    MUST revert if `totalSupply() - amount < currentBurnFloor()` (equivalently,
    ///         `amount > burnableExcess()`). There is NO permanent completion: when supply
    ///         reaches the floor, burning simply pauses until a later unbind lowers the floor,
    ///         at which point `burn` works again. Burns only from the burner's own balance.
    function burn(uint256 amount) external;

    /// @notice Cumulative WORD burned via buy-and-burn.
    function burnedTotal() external view returns (uint256);
}
