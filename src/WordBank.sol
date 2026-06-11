// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Category, WordData} from "./interfaces/Types.sol";
import {IWordBank} from "./interfaces/IWordBank.sol";
import {IRenderer} from "./interfaces/IRenderer.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import {WordToken} from "./WordToken.sol";

/// @title  WordBank — ERC-721 + binding vault + category-indexed alive registry
/// @author WORDBANK — https://wordbank.fun
/// @notice WORDBANK is a fully onchain word-game protocol on Ethereum: 10,000 unique word NFTs,
///         each permanently backed by 1,000 WORD ERC-20 tokens, with a daily commit-reveal
///         sentence-bounty game, continuous holder rewards, and a buy-and-burn — all funded by a
///         1% swap fee on the WORD/ETH Uniswap V4 pool. This contract is the word NFT itself.
///         dApp: https://wordbank.fun
/// @notice Holds the 10,000 words, their 1,000-WORD-per-NFT bound backing, the alive-word
///         registry the BountyEngine selects from, the two-phase public sale, the 200-token
///         admin reserve, the snipe-proof provenance offset, ERC-2981 royalties, and the
///         unbind (burn) path — the asset core of the WORDBANK protocol.
///
/// @dev    Provenance model: the full shuffled word/trait assignment is uploaded to slots
///         [0, 10_000) and locked behind a provenance hash BEFORE mint opens. Token N maps to
///         slot (N - 1 + wordOffset) % 10_000, where wordOffset comes from a blockhash
///         commit-reveal armed the moment the 9,800-token public allocation sells out. Until
///         that reveal, nobody — including the team — can know which tokenId gets which word.
///
///         Consequence the rest of the protocol should know: tokens minted BEFORE the reveal
///         have no knowable category, so they enter the category-indexed registry via the
///         permissionless, batched `buildRegistry` after the reveal (tokens minted after the
///         reveal register eagerly inside mint). `totalAlive()` is exact at all times; the
///         per-category arrays are complete once `registrySynced()` is true. Unbinding a token
///         is possible only once it is registered — before the reveal there is no pool to exit
///         into anyway. System invariant 4 (category counts sum to totalAlive) holds from the
///         moment `registrySynced()` first returns true, which is before trading/game launch.
contract WordBank is IWordBank, ERC721, ERC2981, Ownable2Step, ReentrancyGuard {
    // ──────────────────────────────────── types ────────────────────────────────────────

    /// @notice Sale state machine. Setup → EarlyBird → (Between ⇄ PublicSale).
    ///         EarlyBird auto-advances to PublicSale when its allocation sells out; the admin
    ///         can instead route through Between, the only state (besides Setup) where sale
    ///         config may change. PublicSale can be paused back to Between to reconfigure.
    enum SalePhase {
        Setup,
        EarlyBird,
        Between,
        PublicSale
    }

    // ─────────────────────────────────── constants ─────────────────────────────────────

    /// @notice Collection size; also the number of word slots.
    uint256 public constant MAX_SUPPLY = 10_000;
    /// @notice Hard admin reserve. The admin can never raise it.
    uint256 public constant ADMIN_RESERVE = 200;
    /// @notice Public-path supply (early bird + public sale). Selling this out arms the
    ///         provenance offset reveal.
    uint256 public constant PUBLIC_SUPPLY = MAX_SUPPLY - ADMIN_RESERVE;
    /// @notice WORD bound behind every NFT, without exception.
    uint256 public constant BACKING_PER_NFT = 1_000e18;
    /// @notice Hardcoded royalty ceiling (10%).
    uint96 public constant MAX_ROYALTY_BPS = 1_000;
    /// @notice Blocks between arming the offset commit and the earliest reveal (~3 minutes).
    uint256 public constant OFFSET_REVEAL_DELAY = 15;

    // ──────────────────────────── immutables & dependencies ────────────────────────────

    /// @notice The WORD ERC-20, deployed by this constructor; this contract is its only
    ///         backing minter.
    WordToken public immutable wordToken;

    /// @notice tokenURI renderer. Set once, before mint opens.
    IRenderer public renderer;

    /// @notice Holder fee-share distributor. Set once, before mint opens.
    IRewardsDistributor public rewardsDistributor;

    // ────────────────────────────────── word slots ─────────────────────────────────────

    /// @dev Slot index → word data. The committed, shuffled assignment list.
    mapping(uint256 => WordData) private _slots;

    /// @notice Length of the contiguously written slot prefix [0, slotsWritten).
    uint256 public slotsWritten;

    /// @notice True once the slot list is complete and permanently locked.
    bool public slotsLocked;

    /// @notice The published commitment to the full shuffled assignment (set at lock).
    bytes32 public provenanceHash;

    // ──────────────────────────────────── sale ─────────────────────────────────────────

    /// @notice Current sale phase.
    SalePhase public phase;

    /// @notice Early bird allocation; with publicAllocation + ADMIN_RESERVE always 10,000.
    uint256 public earlyBirdAllocation;
    /// @notice Public sale allocation.
    uint256 public publicAllocation;
    /// @notice Early bird mint price (wei per NFT).
    uint256 public earlyBirdPrice;
    /// @notice Public sale mint price (wei per NFT).
    uint256 public publicPrice;
    /// @notice Per-wallet mint cap, enforced during the early bird phase ONLY. Literal value:
    ///         a cap of 0 blocks all early bird mints.
    uint256 public earlyBirdWalletCap;

    /// @notice NFTs minted through the early bird phase.
    uint256 public earlyBirdMinted;
    /// @notice NFTs minted through the public sale phase.
    uint256 public publicMinted;
    /// @notice NFTs minted from the admin reserve (≤ ADMIN_RESERVE).
    uint256 public adminMinted;

    /// @notice Early bird mints per wallet (cap accounting; never enforced in public phase).
    mapping(address => uint256) public earlyBirdMintedBy;

    // ─────────────────────────── ids, backing, alive registry ──────────────────────────

    /// @dev Next tokenId to mint; ids run 1..10_000 and are never reused.
    uint256 private _nextId = 1;

    /// @dev Exact count of alive (minted, not unbound) tokens at all times.
    uint256 private _totalAlive;

    /// @inheritdoc IWordBank
    mapping(uint256 => uint256) public bondedBalance;

    /// @dev Dense per-category arrays of alive tokenIds (BountyEngine selection source).
    mapping(Category => uint256[]) private _aliveByCategory;

    /// @dev tokenId → (index in its category array) + 1. Zero means "not registered yet"
    ///      (pre-reveal mints awaiting buildRegistry) or "removed" (unbound).
    mapping(uint256 => uint256) private _indexInCategory;

    // ────────────────────────────── provenance offset ──────────────────────────────────

    /// @notice Block whose hash seeds the offset reveal. Zero until armed at public sellout.
    uint256 public offsetTargetBlock;
    /// @notice True once the global word/trait offset is fixed forever.
    bool public offsetSet;
    /// @notice The revealed global offset in [0, MAX_SUPPLY).
    uint256 public wordOffset;
    /// @notice totalMinted() snapshot at reveal; ids 1..preRevealMinted flow through
    ///         buildRegistry, later ids register eagerly at mint.
    uint256 public preRevealMinted;
    /// @notice Pre-reveal ids [1, registryCursor] already pushed into the category registry.
    uint256 public registryCursor;

    // ──────────────────────────────────── events ───────────────────────────────────────

    /// @notice Renderer dependency set (once).
    event RendererSet(address renderer);
    /// @notice RewardsDistributor dependency set (once).
    event RewardsDistributorSet(address distributor);
    /// @notice A batch of word slots written or overwritten pre-lock.
    event WordSlotsWritten(uint256 indexed start, uint256 count);
    /// @notice Slot list completed and locked behind its provenance hash.
    event SlotsLocked(bytes32 provenanceHash);
    /// @notice Sale configuration changed (only in Setup or Between).
    event SaleConfigUpdated(
        uint256 earlyBirdAllocation,
        uint256 publicAllocation,
        uint256 earlyBirdPrice,
        uint256 publicPrice,
        uint256 earlyBirdWalletCap
    );
    /// @notice Sale phase transition (admin call or early bird sellout auto-advance).
    event PhaseChanged(SalePhase phase);
    /// @notice One NFT minted with its 1,000 WORD backing (every mint path).
    event WordMinted(uint256 indexed tokenId, address indexed to);
    /// @notice Public allocation sold out; offset reveal armed for `targetBlock`.
    event OffsetCommitArmed(uint256 targetBlock);
    /// @notice Reveal window lapsed unrevealed; commit re-armed for a new target block.
    event OffsetCommitRearmed(uint256 targetBlock);
    /// @notice The global word/trait offset is fixed forever.
    event OffsetRevealed(uint256 offset, uint256 preRevealMinted);
    /// @notice buildRegistry progressed: pre-reveal ids [1, builtThrough] are now registered.
    event RegistryBuilt(uint256 builtThrough, uint256 target);
    /// @notice NFT burned; backing released to its final owner.
    event Unbound(uint256 indexed tokenId, address indexed owner);
    /// @notice ERC-2981 default royalty updated (≤ MAX_ROYALTY_BPS).
    event RoyaltySet(address receiver, uint96 bps);
    /// @notice Accumulated mint proceeds withdrawn by the admin.
    event ProceedsWithdrawn(address indexed to, uint256 amount);

    // ──────────────────────────────────── errors ───────────────────────────────────────

    /// @notice Dependency already set (renderer / rewards distributor are set-once).
    error AlreadySet();
    /// @notice Zero address where a real address is required.
    error ZeroAddress();
    /// @notice Slot writes/locks attempted after the permanent lock.
    error SlotsAreLocked();
    /// @notice Batch would leave a gap in the slot prefix.
    error NonContiguousBatch();
    /// @notice Slot index or batch extends past MAX_SUPPLY, or reads past slotsWritten.
    error SlotOutOfRange();
    /// @notice Empty batch / zero count / empty id list.
    error ZeroCount();
    /// @notice A slot word string is empty.
    error EmptyWord();
    /// @notice Locking requires all 10,000 slots written.
    error SlotsIncomplete();
    /// @notice Provenance hash must be nonzero.
    error InvalidProvenanceHash();
    /// @notice Setup incomplete: slots must be locked and both dependencies set.
    error SetupIncomplete();
    /// @notice Sale config can only change in Setup or Between.
    error ConfigLockedDuringSale();
    /// @notice earlyBird + public + ADMIN_RESERVE must equal 10,000 exactly.
    error AllocationInvariantViolated();
    /// @notice An allocation cannot drop below what that phase already minted.
    error AllocationBelowMinted();
    /// @notice Action not valid in the current sale phase.
    error WrongPhase();
    /// @notice Mint count exceeds the phase allocation remainder.
    error ExceedsAllocation();
    /// @notice Early bird per-wallet cap exceeded.
    error ExceedsWalletCap();
    /// @notice msg.value must equal price × count exactly.
    error WrongPayment();
    /// @notice Cumulative admin mints capped at ADMIN_RESERVE.
    error ExceedsAdminReserve();
    /// @notice Offset reveal not armed yet (public allocation not sold out).
    error OffsetNotArmed();
    /// @notice Offset already revealed; it is immutable.
    error OffsetAlreadySet();
    /// @notice Reveal called at or before the target block.
    error RevealTooEarly();
    /// @notice Target blockhash no longer available (256-block window lapsed) — re-arm.
    error RevealWindowExpired();
    /// @notice Re-arm called while the current reveal window is still open.
    error RevealWindowStillOpen();
    /// @notice Word/trait queries require the revealed offset.
    error OffsetNotSet();
    /// @notice All pre-reveal ids are already registered.
    error RegistryAlreadyBuilt();
    /// @notice tokenId was never minted.
    error UnknownToken();
    /// @notice Caller does not own the token.
    error NotTokenOwner();
    /// @notice Token not yet in the category registry (pre-reveal mint awaiting
    ///         buildRegistry); unbind is unavailable until then.
    error TokenNotInRegistry();
    /// @notice Royalty bps above the hardcoded MAX_ROYALTY_BPS ceiling.
    error RoyaltyTooHigh();
    /// @notice WORD transfer to the unbinder failed.
    error BackingTransferFailed();
    /// @notice ETH transfer failed.
    error EthTransferFailed();

    // ───────────────────────────────── construction ────────────────────────────────────

    /// @param admin Protocol admin: sale config, reserve, royalties, proceeds, and the
    ///              WordToken liquidity allotment (passed through as WordToken's owner).
    constructor(address admin) ERC721("WordBank Words", "WORDS") Ownable(admin) {
        wordToken = new WordToken(admin);
    }

    // ───────────────────────────── one-time dependency wiring ──────────────────────────

    /// @notice Sets the tokenURI renderer. One-time; required before the sale can open.
    function setRenderer(address renderer_) external onlyOwner {
        if (address(renderer) != address(0)) revert AlreadySet();
        if (renderer_ == address(0)) revert ZeroAddress();
        renderer = IRenderer(renderer_);
        emit RendererSet(renderer_);
    }

    /// @notice Sets the rewards distributor. One-time; required before any mint.
    function setRewardsDistributor(address distributor_) external onlyOwner {
        if (address(rewardsDistributor) != address(0)) revert AlreadySet();
        if (distributor_ == address(0)) revert ZeroAddress();
        rewardsDistributor = IRewardsDistributor(distributor_);
        emit RewardsDistributorSet(distributor_);
    }

    // ────────────────────────────── word slot management ───────────────────────────────

    /// @notice Writes a batch of the shuffled word/trait assignment into slots
    ///         [start, start + words.length). Admin-only, impossible after lock.
    /// @dev    Batches must keep the written prefix contiguous (start ≤ slotsWritten);
    ///         overwriting earlier slots pre-lock is allowed so upload mistakes are fixable.
    function setWordSlots(uint256 start, WordData[] calldata words) external onlyOwner {
        if (slotsLocked) revert SlotsAreLocked();
        uint256 len = words.length;
        if (len == 0) revert ZeroCount();
        if (start > slotsWritten) revert NonContiguousBatch();
        uint256 end = start + len;
        if (end > MAX_SUPPLY) revert SlotOutOfRange();
        for (uint256 i = 0; i < len; ++i) {
            if (bytes(words[i].word).length == 0) revert EmptyWord();
            _slots[start + i] = words[i];
        }
        if (end > slotsWritten) slotsWritten = end;
        emit WordSlotsWritten(start, len);
    }

    /// @notice Permanently locks the complete slot list and records the provenance hash —
    ///         the public commitment that the assignment can never change after this point.
    function lockSlots(bytes32 provenanceHash_) external onlyOwner {
        if (slotsLocked) revert SlotsAreLocked();
        if (slotsWritten != MAX_SUPPLY) revert SlotsIncomplete();
        if (provenanceHash_ == bytes32(0)) revert InvalidProvenanceHash();
        slotsLocked = true;
        provenanceHash = provenanceHash_;
        emit SlotsLocked(provenanceHash_);
    }

    // ──────────────────────────────── sale administration ──────────────────────────────

    /// @notice Sets allocations, prices, and the early bird wallet cap. Only in Setup or
    ///         Between — never while a sale phase is open.
    /// @dev    Always enforces earlyBird + public + ADMIN_RESERVE == 10,000, and never lets
    ///         an allocation drop below what its phase already minted.
    function setSaleConfig(
        uint256 earlyBirdAllocation_,
        uint256 publicAllocation_,
        uint256 earlyBirdPrice_,
        uint256 publicPrice_,
        uint256 earlyBirdWalletCap_
    ) external onlyOwner {
        if (phase != SalePhase.Setup && phase != SalePhase.Between) {
            revert ConfigLockedDuringSale();
        }
        if (earlyBirdAllocation_ + publicAllocation_ + ADMIN_RESERVE != MAX_SUPPLY) {
            revert AllocationInvariantViolated();
        }
        if (earlyBirdAllocation_ < earlyBirdMinted || publicAllocation_ < publicMinted) {
            revert AllocationBelowMinted();
        }
        earlyBirdAllocation = earlyBirdAllocation_;
        publicAllocation = publicAllocation_;
        earlyBirdPrice = earlyBirdPrice_;
        publicPrice = publicPrice_;
        earlyBirdWalletCap = earlyBirdWalletCap_;
        emit SaleConfigUpdated(
            earlyBirdAllocation_, publicAllocation_, earlyBirdPrice_, publicPrice_, earlyBirdWalletCap_
        );
    }

    /// @notice Opens the early bird phase. Requires completed setup and a configured sale.
    function openEarlyBird() external onlyOwner {
        if (phase != SalePhase.Setup) revert WrongPhase();
        _requireSetup();
        if (earlyBirdAllocation + publicAllocation != PUBLIC_SUPPLY) revert SetupIncomplete();
        phase = SalePhase.EarlyBird;
        emit PhaseChanged(SalePhase.EarlyBird);
    }

    /// @notice Ends the early bird phase before sellout ("admin advances the phase"),
    ///         entering Between, where config may be adjusted before opening the public sale.
    function closeEarlyBird() external onlyOwner {
        if (phase != SalePhase.EarlyBird) revert WrongPhase();
        phase = SalePhase.Between;
        emit PhaseChanged(SalePhase.Between);
    }

    /// @notice Opens the public sale from Between.
    function openPublicSale() external onlyOwner {
        if (phase != SalePhase.Between) revert WrongPhase();
        phase = SalePhase.PublicSale;
        emit PhaseChanged(SalePhase.PublicSale);
    }

    /// @notice Pauses the public sale back to Between so config can be corrected (e.g. fold
    ///         an undersold early bird remainder into the public allocation).
    function pausePublicSale() external onlyOwner {
        if (phase != SalePhase.PublicSale) revert WrongPhase();
        phase = SalePhase.Between;
        emit PhaseChanged(SalePhase.Between);
    }

    // ─────────────────────────────────── minting ───────────────────────────────────────

    /// @notice Early bird mint: cheaper price, per-wallet cap (this phase only).
    ///         Auto-advances to the public sale when the early bird allocation sells out.
    function earlyBirdMint(uint256 count) external payable nonReentrant {
        if (phase != SalePhase.EarlyBird) revert WrongPhase();
        if (count == 0) revert ZeroCount();
        if (earlyBirdMinted + count > earlyBirdAllocation) revert ExceedsAllocation();
        uint256 walletTotal = earlyBirdMintedBy[msg.sender] + count;
        if (walletTotal > earlyBirdWalletCap) revert ExceedsWalletCap();
        if (msg.value != earlyBirdPrice * count) revert WrongPayment();

        earlyBirdMintedBy[msg.sender] = walletTotal;
        earlyBirdMinted += count;
        for (uint256 i = 0; i < count; ++i) {
            _mintWord(msg.sender);
        }
        if (earlyBirdMinted == earlyBirdAllocation) {
            phase = SalePhase.PublicSale;
            emit PhaseChanged(SalePhase.PublicSale);
        }
        _maybeArmOffset();
    }

    /// @notice Public sale mint: higher price, no per-wallet cap. Selling out the public
    ///         allocation arms the provenance offset reveal.
    function publicMint(uint256 count) external payable nonReentrant {
        if (phase != SalePhase.PublicSale) revert WrongPhase();
        if (count == 0) revert ZeroCount();
        if (publicMinted + count > publicAllocation) revert ExceedsAllocation();
        if (msg.value != publicPrice * count) revert WrongPayment();

        publicMinted += count;
        for (uint256 i = 0; i < count; ++i) {
            _mintWord(msg.sender);
        }
        _maybeArmOffset();
    }

    /// @notice Mints from the 200-token admin reserve — any phase, no payment, identical
    ///         core sequence, cumulative hard cap ADMIN_RESERVE.
    function adminMint(uint256 count, address to) external onlyOwner nonReentrant {
        _requireSetup();
        if (count == 0) revert ZeroCount();
        if (adminMinted + count > ADMIN_RESERVE) revert ExceedsAdminReserve();
        adminMinted += count;
        for (uint256 i = 0; i < count; ++i) {
            _mintWord(to);
        }
    }

    /// @dev The core mint sequence — identical for every path, no exception:
    ///      next tokenId → mint NFT → mint 1,000e18 WORD to this vault → record backing →
    ///      register with the RewardsDistributor → enter the alive registry (eagerly when the
    ///      offset is known; via buildRegistry otherwise).
    ///      Uses _mint (no receiver callback) so the sequence cannot be reentered mid-state.
    function _mintWord(address to) internal returns (uint256 tokenId) {
        tokenId = _nextId++;
        _mint(to, tokenId);
        wordToken.mint(address(this), BACKING_PER_NFT);
        bondedBalance[tokenId] = BACKING_PER_NFT;
        _totalAlive += 1;
        rewardsDistributor.register(tokenId);
        if (offsetSet) {
            _registerAlive(tokenId);
        }
        emit WordMinted(tokenId, to);
    }

    /// @dev Slots must be locked and both dependencies wired before anything can mint.
    function _requireSetup() internal view {
        if (!slotsLocked || address(rewardsDistributor) == address(0) || address(renderer) == address(0)) {
            revert SetupIncomplete();
        }
    }

    // ────────────────────────────── provenance commit-reveal ───────────────────────────

    /// @dev Arms the offset reveal the moment the 9,800 public allocation is fully minted.
    ///      Fires exactly once; the admin reserve neither triggers nor delays it.
    function _maybeArmOffset() internal {
        if (offsetSet || offsetTargetBlock != 0) return;
        if (earlyBirdMinted + publicMinted != PUBLIC_SUPPLY) return;
        uint256 target = block.number + OFFSET_REVEAL_DELAY;
        offsetTargetBlock = target;
        emit OffsetCommitArmed(target);
    }

    /// @notice Fixes the global word/trait offset from the target block's hash. Callable by
    ///         anyone once the target block has passed, while its hash is still available
    ///         (256-block window). The offset is immutable once set.
    function revealOffset() external {
        if (offsetSet) revert OffsetAlreadySet();
        uint256 target = offsetTargetBlock;
        if (target == 0) revert OffsetNotArmed();
        if (block.number <= target) revert RevealTooEarly();
        bytes32 bh = blockhash(target);
        if (bh == bytes32(0)) revert RevealWindowExpired();

        wordOffset = uint256(keccak256(abi.encodePacked(bh, address(this)))) % MAX_SUPPLY;
        offsetSet = true;
        preRevealMinted = _nextId - 1;
        emit OffsetRevealed(wordOffset, preRevealMinted);
    }

    /// @notice Re-arms the reveal with a fresh target block if the 256-block window lapsed
    ///         with nobody calling revealOffset. Permissionless, like the reveal itself.
    function rearmOffset() external {
        if (offsetSet) revert OffsetAlreadySet();
        uint256 target = offsetTargetBlock;
        if (target == 0) revert OffsetNotArmed();
        if (block.number <= target || blockhash(target) != bytes32(0)) revert RevealWindowStillOpen();
        uint256 newTarget = block.number + OFFSET_REVEAL_DELAY;
        offsetTargetBlock = newTarget;
        emit OffsetCommitRearmed(newTarget);
    }

    /// @notice Pushes tokens minted before the offset reveal into the category-indexed alive
    ///         registry, in tokenId order, up to maxCount at a time. Permissionless; call
    ///         until registrySynced() is true (10,000 tokens ≈ a handful of batched calls).
    function buildRegistry(uint256 maxCount) external {
        if (!offsetSet) revert OffsetNotSet();
        if (maxCount == 0) revert ZeroCount();
        uint256 cursor = registryCursor;
        uint256 target = preRevealMinted;
        if (cursor >= target) revert RegistryAlreadyBuilt();
        uint256 end = cursor + maxCount;
        if (end > target) end = target;
        for (uint256 id = cursor + 1; id <= end; ++id) {
            _registerAlive(id);
        }
        registryCursor = end;
        emit RegistryBuilt(end, target);
    }

    /// @notice True once every pre-reveal token is in the category registry — from this point
    ///         the per-category counts sum exactly to totalAlive() (system invariant 4).
    function registrySynced() public view returns (bool) {
        return offsetSet && registryCursor == preRevealMinted;
    }

    // ──────────────────────────────────── unbind ───────────────────────────────────────

    /// @notice Burns the caller's NFT and releases its 1,000 bound WORD — the only burn path.
    ///         Order: (1) burn, (2) force-settle pending rewards to the caller, (3) remove
    ///         from the alive registry, (4) zero the bond and transfer the WORD out.
    /// @dev    Requires the token to be in the category registry (always true once
    ///         registrySynced(); pre-reveal tokens cannot unbind — there is nothing to exit
    ///         into before launch). Burned ids can never be reminted: _nextId only grows.
    function unbind(uint256 tokenId) external nonReentrant {
        _unbind(tokenId);
    }

    /// @notice Batched unbind. Reverts atomically if any id is not owned by the caller.
    function unbindMany(uint256[] calldata tokenIds) external nonReentrant {
        uint256 len = tokenIds.length;
        if (len == 0) revert ZeroCount();
        for (uint256 i = 0; i < len; ++i) {
            _unbind(tokenIds[i]);
        }
    }

    /// @dev Ordering (overseer review 2026-06-11, finding 1): the burn comes FIRST. The
    ///      production distributor pays ETH to the burner inside settleAndClose, handing them
    ///      execution mid-unbind; if the token were still live they could transfer/sell it
    ///      before the burn lands (sale proceeds + rewards + backing, buyer left with a burned
    ///      token). Burning first closes every transfer/approval path before any external
    ///      call. Settlement still happens BEFORE the registry pop and totalAlive decrement —
    ///      the substance of system invariant 3: the distributor sees the pre-burn alive
    ///      count, the burned token collects its full share, survivors split everything after.
    function _unbind(uint256 tokenId) internal {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (_indexInCategory[tokenId] == 0) revert TokenNotInRegistry();

        // 1. burn — closes the transfer surface before control can leave this contract.
        _burn(tokenId);

        // 2. force-settle pending rewards to the burner (totalAlive not yet decremented).
        rewardsDistributor.settleAndClose(tokenId, msg.sender);

        // 3. deregister (swap-and-pop), then decrement totalAlive.
        _removeAlive(tokenId);
        _totalAlive -= 1;

        // 4. release the backing.
        bondedBalance[tokenId] = 0;
        emit Unbound(tokenId, msg.sender);
        if (!wordToken.transfer(msg.sender, BACKING_PER_NFT)) revert BackingTransferFailed();
    }

    // ─────────────────────────────── registry internals ────────────────────────────────

    /// @dev O(1) push. Caller guarantees offsetSet and that tokenId is not yet registered.
    function _registerAlive(uint256 tokenId) internal {
        uint256[] storage arr = _aliveByCategory[_slots[_slotIndexOf(tokenId)].category];
        arr.push(tokenId);
        _indexInCategory[tokenId] = arr.length;
    }

    /// @dev O(1) swap-and-pop removal. Caller guarantees tokenId is registered.
    function _removeAlive(uint256 tokenId) internal {
        uint256[] storage arr = _aliveByCategory[_slots[_slotIndexOf(tokenId)].category];
        uint256 idxPlusOne = _indexInCategory[tokenId];
        uint256 lastId = arr[arr.length - 1];
        if (lastId != tokenId) {
            arr[idxPlusOne - 1] = lastId;
            _indexInCategory[lastId] = idxPlusOne;
        }
        arr.pop();
        delete _indexInCategory[tokenId];
    }

    /// @dev tokenId (1-based) → slot index via the provenance offset.
    function _slotIndexOf(uint256 tokenId) internal view returns (uint256) {
        unchecked {
            return (tokenId - 1 + wordOffset) % MAX_SUPPLY;
        }
    }

    // ──────────────────────────── royalties & proceeds ─────────────────────────────────

    /// @notice Sets the ERC-2981 default royalty, hard-capped at MAX_ROYALTY_BPS (10%).
    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        _setDefaultRoyalty(receiver, bps);
        emit RoyaltySet(receiver, bps);
    }

    /// @notice Withdraws all accumulated mint proceeds to `to`. Admin-only.
    function withdrawProceeds(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        emit ProceedsWithdrawn(to, amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    // ──────────────────────────────────── views ────────────────────────────────────────

    /// @inheritdoc IWordBank
    function wordOf(uint256 tokenId) external view returns (string memory) {
        _requireMintedId(tokenId);
        _requireOffset();
        return _slots[_slotIndexOf(tokenId)].word;
    }

    /// @inheritdoc IWordBank
    function categoryOf(uint256 tokenId) external view returns (Category) {
        _requireMintedId(tokenId);
        _requireOffset();
        return _slots[_slotIndexOf(tokenId)].category;
    }

    /// @notice Full word data (word, category, traits) for a minted token, post-reveal.
    ///         Works for burned ids too — historical sentences still need their words.
    function wordDataOf(uint256 tokenId) external view returns (WordData memory) {
        _requireMintedId(tokenId);
        _requireOffset();
        return _slots[_slotIndexOf(tokenId)];
    }

    /// @notice Raw slot data by slot index (pre- or post-reveal) so anyone can verify the
    ///         uploaded assignment against the provenance hash.
    function slotAt(uint256 index) external view returns (WordData memory) {
        if (index >= slotsWritten) revert SlotOutOfRange();
        return _slots[index];
    }

    /// @inheritdoc IWordBank
    function aliveCount(Category category) external view returns (uint256) {
        return _aliveByCategory[category].length;
    }

    /// @inheritdoc IWordBank
    function aliveAt(Category category, uint256 index) external view returns (uint256) {
        return _aliveByCategory[category][index];
    }

    /// @inheritdoc IWordBank
    function totalAlive() external view returns (uint256) {
        return _totalAlive;
    }

    /// @notice The collection's live circulating supply: NFTs currently in existence
    ///         (minted minus unbound), identical to `totalAlive()`. Provided under the
    ///         explorer-standard `totalSupply()` name because WordBank is not ERC721Enumerable
    ///         and the OZ ERC-721 base declares no `totalSupply` — NFT explorers and the dApp
    ///         read this from the concrete ABI. Rises on every mint, falls on every unbind.
    function totalSupply() public view returns (uint256) {
        return _totalAlive;
    }

    /// @inheritdoc IWordBank
    function isAlive(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @notice Total NFTs ever minted (alive + burned). Ids run 1..totalMinted().
    function totalMinted() external view returns (uint256) {
        return _nextId - 1;
    }

    /// @notice 1-based position of a token in its category's alive array; 0 when not (yet)
    ///         registered or already unbound. Exposed for tests and integrations.
    function indexInCategory(uint256 tokenId) external view returns (uint256) {
        return _indexInCategory[tokenId];
    }

    /// @notice Standard ERC-721 tokenURI. Before the offset reveal every token delegates to the
    ///         Renderer's onchain "unrevealed" placeholder (branded art, byte-identical except
    ///         the displayed #id); after it, assembly is delegated to the Renderer with traits.
    /// @dev    The pre-reveal call passes ONLY tokenId — no slot lookup, no trait read — so it
    ///         is structurally incapable of leaking the eventual word/traits (snipe-proof).
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (!offsetSet) {
            return renderer.unrevealedTokenURI(tokenId);
        }
        return renderer.tokenURI(tokenId, _slots[_slotIndexOf(tokenId)]);
    }

    /// @dev Reverts for ids that were never minted; burned ids pass (metadata must outlive
    ///      the token — historical SentenceGenerated events reference burned words).
    function _requireMintedId(uint256 tokenId) internal view {
        if (tokenId == 0 || tokenId >= _nextId) revert UnknownToken();
    }

    /// @dev Word/trait queries are meaningless until the provenance offset is fixed.
    function _requireOffset() internal view {
        if (!offsetSet) revert OffsetNotSet();
    }

    // ─────────────────────────────── inheritance plumbing ──────────────────────────────

    /// @inheritdoc IWordBank
    function ownerOf(uint256 tokenId) public view override(ERC721, IWordBank) returns (address) {
        return super.ownerOf(tokenId);
    }

    /// @inheritdoc IWordBank
    function balanceOf(address owner_) public view override(ERC721, IWordBank) returns (uint256) {
        return super.balanceOf(owner_);
    }

    /// @notice ERC-165: ERC-721 + ERC-2981 + parents.
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
