// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Minimal live read of the WordBank's alive-NFT count for the dynamic burn floor.
///         Deliberately a local, self-contained interface (not the frozen IWordBank) so this
///         token couples to WordBank only through the single view it actually needs. The
///         `wordBank` immutable is the deployer/minter; this is a pure view, no reentrancy risk.
interface ITotalAlive {
    function totalAlive() external view returns (uint256);
}

/// @title  WordToken — WORD ERC-20, 11,000,000e18 minted cap, burnable to a dynamic backing floor
/// @author WORDBANK — https://wordbank.fun
/// @notice WORDBANK is a fully onchain word-game protocol on Ethereum: 10,000 unique word NFTs,
///         each permanently backed by 1,000 WORD ERC-20 tokens, with a daily commit-reveal
///         sentence-bounty game, continuous holder rewards, and a buy-and-burn — all funded by a
///         1% swap fee on the WORD/ETH Uniswap V4 pool. WORD is that backing-and-fee token.
///         dApp: https://wordbank.fun
/// @notice Deliberately vanilla ERC-20: no transfer hooks, no burn-on-transfer in the transfer
///         path. Bound backing is physically held by the WordBank, so liquid WORD circulating
///         in wallets and the pool is a plain token. Minting is hard-capped at 11,000,000e18:
///         10,000,000e18 of backing minted only by the WordBank (10,000 NFTs x 1,000e18) plus
///         a 1,000,000e18 admin allotment for seeding initial pool liquidity. Once both
///         allotments are fully minted, anyone can permanently seal minting.
///
///         Buy-and-burn (interfaces-v3, dynamic floor): after the seal, the BurnEngine — the
///         set-once `burner` — may burn WORD it has bought from the pool, down to a LIVE floor
///         `currentBurnFloor() = WordBank.totalAlive() * 1000e18`. Because the floor is exactly
///         the backing requirement of the still-alive NFTs, the backing can never be eroded.
///         There is no permanent completion: unbinding an NFT lowers totalAlive (and frees its
///         1,000 WORD into circulation), which lowers the floor and makes that freed WORD
///         burnable. Burning pauses at the floor and resumes after the next unbind.
///         Post-seal invariant: `totalAlive*1000e18 <= totalSupply <= 11M`, both supply and
///         floor monotonically non-increasing (system invariant 2).
/// @dev    Deployed by the WordBank's constructor, which makes `wordBank` a true immutable —
///         no setter, no circular-address dance, and it doubles as the live-floor oracle
///         (read via ITotalAlive). The admin (Ownable owner) controls only the liquidity
///         allotment and the one-time burner wiring; it cannot touch backing mints, exceed the
///         1M liquidity cap, or burn below the floor.
///
///         Renounceability (scanner hygiene, owner-mandated): once `burner` is set, liquidity
///         is fully minted, and minting is sealed, no owner-gated function is ever needed
///         again — the launch runbook calls renounceOwnership() so token scanners read
///         owner = 0x0. Every owner-gated path here (mintLiquidity, setBurner) is dead by
///         construction at that point; `burn` and all views are owner-independent.
///
///         Conforms exactly to the frozen `IWordToken` ABI but does not inherit it: the frozen
///         interface is deliberately self-contained and re-declares the ERC-20 events, which
///         Solidity rejects as duplicates next to OZ's IERC20. ABI conformance is enforced by
///         the unit tests, which drive this contract exclusively through `IWordToken`.
contract WordToken is ERC20, Ownable2Step {
    // ─────────────────────────────────── constants ─────────────────────────────────────

    /// @notice Maximum cumulative backing mints: 10,000 NFTs x 1,000e18.
    uint256 public constant BACKING_CAP = 10_000_000e18;

    /// @notice Maximum cumulative admin liquidity mints.
    uint256 public constant LIQUIDITY_CAP = 1_000_000e18;

    /// @notice WORD bound behind every alive NFT (mirrors WordBank.BACKING_PER_NFT); the
    ///         per-NFT multiplier of the dynamic burn floor.
    uint256 public constant BACKING_PER_NFT = 1_000e18;

    /// @notice The hard minted supply cap (11,000,000e18 = 10M backing + 1M liquidity).
    ///         `totalSupply()` starts here once minting is sealed and only ever falls from
    ///         this point, via buy-and-burn. Exposed for marketcap / fully-diluted-value tools.
    uint256 public constant MAX_SUPPLY = BACKING_CAP + LIQUIDITY_CAP;

    // ──────────────────────────────────── storage ──────────────────────────────────────

    /// @notice The WordBank — the only address allowed to mint backing tokens.
    address public immutable wordBank;

    /// @notice Cumulative backing minted via the WordBank (≤ BACKING_CAP).
    uint256 public backingMinted;

    /// @notice Cumulative amount minted from the liquidity allotment (≤ LIQUIDITY_CAP).
    uint256 public liquidityMinted;

    /// @notice True once minting is permanently sealed.
    bool public mintingSealed;

    /// @notice The only address permitted to call `burn` — the BurnEngine. Set once,
    ///         post-deploy, by the admin; never zero, never re-set.
    address public burner;

    /// @notice Cumulative WORD burned via buy-and-burn.
    uint256 public burnedTotal;

    // ──────────────────────────────────── events ───────────────────────────────────────
    // Declared locally (signatures identical to the frozen IWordToken — see contract @dev).

    /// @notice Emitted when the admin mints from the liquidity allotment.
    event LiquidityMinted(address indexed to, uint256 amount, uint256 liquidityMintedTotal);
    /// @notice Emitted exactly once, when minting is permanently sealed.
    event MintingSealed(uint256 finalTotalSupply);
    /// @notice Emitted once, when the burner address is wired.
    event BurnerSet(address indexed burner);
    /// @notice Emitted on every buy-and-burn.
    event Burned(address indexed burner, uint256 amount, uint256 newTotalSupply);

    // ──────────────────────────────────── errors ───────────────────────────────────────

    /// @notice Caller of mint() is not the WordBank.
    error NotWordBank();
    /// @notice Mint would push cumulative backing past BACKING_CAP.
    error BackingCapExceeded();
    /// @notice Mint would push cumulative liquidity past LIQUIDITY_CAP.
    error LiquidityCapExceeded();
    /// @notice Minting has been permanently sealed.
    error MintingIsSealed();
    /// @notice Seal requires both allotments fully minted (totalSupply == 11,000,000e18).
    error SealPreconditionsNotMet();
    /// @notice The burner address is already set (set-once).
    error BurnerAlreadySet();
    /// @notice Zero address where a real address is required.
    error ZeroAddress();
    /// @notice Caller of burn() is not the burner.
    error NotBurner();
    /// @notice burn() called before minting was sealed.
    error MintingNotSealed();
    /// @notice Burn would push totalSupply below the live backing floor (currentBurnFloor()).
    error BurnFloorBreached();

    // ───────────────────────────────── construction ────────────────────────────────────

    /// @param admin The protocol admin; owner of the liquidity allotment.
    /// @dev   msg.sender is the deploying WordBank and becomes the sole backing minter.
    constructor(address admin) ERC20("WordBank WORD", "WORD") Ownable(admin) {
        wordBank = msg.sender;
    }

    // ──────────────────────────────────── minting ──────────────────────────────────────

    /// @notice Mints backing tokens. Callable ONLY by the WordBank, always 1,000e18 per NFT
    ///         minted, always to the WordBank itself.
    /// @dev    Cumulative cap BACKING_CAP. The seal check is defense in depth — the cap alone
    ///         already prevents post-seal backing mints.
    function mint(address to, uint256 amount) external {
        if (msg.sender != wordBank) revert NotWordBank();
        if (mintingSealed) revert MintingIsSealed();
        uint256 newBacking = backingMinted + amount;
        if (newBacking > BACKING_CAP) revert BackingCapExceeded();
        backingMinted = newBacking;
        _mint(to, amount);
    }

    /// @notice Mints from the admin liquidity allotment for seeding the canonical pool.
    /// @dev    Admin-only. Cumulative cap LIQUIDITY_CAP — reverts beyond it, even for the admin.
    function mintLiquidity(address to, uint256 amount) external onlyOwner {
        if (mintingSealed) revert MintingIsSealed();
        uint256 newLiquidity = liquidityMinted + amount;
        if (newLiquidity > LIQUIDITY_CAP) revert LiquidityCapExceeded();
        liquidityMinted = newLiquidity;
        _mint(to, amount);
        emit LiquidityMinted(to, amount, newLiquidity);
    }

    /// @notice Permanently seals all minting. Callable once, only after both allotments are
    ///         fully minted. After this, totalSupply() starts at 11,000,000e18 and can only
    ///         decrease toward the live backing floor via buy-and-burn — never rise again.
    /// @dev Permissionless on purpose: the preconditions are objective (both allotments fully
    ///      minted), so requiring an admin key adds liveness risk without adding safety. After
    ///      this fires, the post-seal supply invariant `currentBurnFloor() <= totalSupply <= 11M`
    ///      holds, and supply is monotonically non-increasing (the only state-changing supply
    ///      path left is the burner-gated `burn`). The floor itself also only falls (totalAlive
    ///      only decreases post-launch, via unbind).
    ///
    ///      Timing note (overseer review, finding 2): the backing allotment completes only
    ///      when all 10,000 NFTs exist, INCLUDING the 200-token admin reserve — an unminted
    ///      reserve delays the seal indefinitely. Supply safety never depends on the seal
    ///      (both caps bind regardless); only the public "sealed at 11M" signal waits. The
    ///      deploy runbook must mint out the reserve before announcing the seal.
    function sealMinting() external {
        if (mintingSealed) revert MintingIsSealed();
        if (backingMinted != BACKING_CAP || liquidityMinted != LIQUIDITY_CAP) {
            revert SealPreconditionsNotMet();
        }
        mintingSealed = true;
        emit MintingSealed(totalSupply());
    }

    // ──────────────────────────────── buy-and-burn (v3) ────────────────────────────────

    /// @notice Wires the BurnEngine as the sole `burner`. Admin-only, set-once, never zero.
    /// @dev    The last owner-gated action of the token's life: once this is set, liquidity
    ///         minted, and minting sealed, the admin renounces ownership and no owner path is
    ///         ever needed again (scanner hygiene). Deliberately separate from the constructor
    ///         because the BurnEngine is deployed after the token (it needs the token address).
    function setBurner(address burner_) external onlyOwner {
        if (burner != address(0)) revert BurnerAlreadySet();
        if (burner_ == address(0)) revert ZeroAddress();
        burner = burner_;
        emit BurnerSet(burner_);
    }

    /// @notice The live supply floor: `WordBank.totalAlive() * BACKING_PER_NFT`. Burning can
    ///         never drop totalSupply below this, so the backing of every alive NFT is always
    ///         fully covered. The floor falls as NFTs unbind.
    function currentBurnFloor() public view returns (uint256) {
        return ITotalAlive(wordBank).totalAlive() * BACKING_PER_NFT;
    }

    /// @notice WORD currently burnable: `totalSupply - currentBurnFloor()`, or 0 at the floor.
    /// @dev    `totalSupply >= currentBurnFloor()` is a standing invariant (the WordBank holds
    ///         exactly `totalAlive * BACKING_PER_NFT` of backing, and totalSupply includes it),
    ///         so the subtraction never underflows in practice; the explicit guard keeps the
    ///         view total even if that ever changed.
    function burnableExcess() public view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 floor = currentBurnFloor();
        return supply > floor ? supply - floor : 0;
    }

    /// @notice Burns `amount` WORD from the burner's own balance. Callable ONLY by `burner`.
    /// @dev    Gated on `mintingSealed`: burning is allowed only after the supply is fixed at
    ///         11M (the BurnEngine only operates post-launch anyway, so the gate is free).
    ///         Reverts if the burn would drop totalSupply below the LIVE floor
    ///         `currentBurnFloor()` — equivalently if `amount > burnableExcess()`. There is no
    ///         permanent completion: at the floor `burn` simply reverts until a later unbind
    ///         lowers `totalAlive` (and the floor), freeing that NFT's released WORD to be
    ///         burned. Burns from the burner's balance (reverts if it holds too little).
    function burn(uint256 amount) external {
        if (msg.sender != burner) revert NotBurner();
        if (!mintingSealed) revert MintingNotSealed();
        if (amount > burnableExcess()) revert BurnFloorBreached();

        burnedTotal += amount;
        _burn(msg.sender, amount); // reverts if the burner's balance is insufficient
        emit Burned(msg.sender, amount, totalSupply());
    }
}
