// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IBountyEngine} from "./interfaces/IBountyEngine.sol";
import {IWordBank} from "./interfaces/IWordBank.sol";
import {Category} from "./interfaces/Types.sol";

/// @dev Minimal view of the WordBank's registry-sync flag (SPEC-3 game-start gate).
///      `registrySynced()` is WordBank-internal surface, deliberately absent from the frozen
///      IWordBank (interfaces-v2) — local-interface cast is the project's established pattern
///      for that (see Agent 5's IFeeHookView in BurnEngine.sol). True once every minted word
///      is in `aliveByCategory` post-provenance-reveal; while false, mid-mint registry
///      reshaping could steer reveal draws (TM-R6), so the game must not start.
interface IRegistrySync {
    function registrySynced() external view returns (bool);
}

/// @title  BountyEngine — daily commit-reveal sentence bounties
/// @notice Owns the bounty treasury (the bounty slice of the 1% swap fee: 25% at launch while
///         buy-and-burn is active, default 30% after — this contract is agnostic to the slice
///         size), the sentence templates, the daily commit-reveal cycle, claims, and sweeps.
///
///         Treasury model: ETH arrives permissionlessly via deposit()/receive(). Free treasury =
///         balance − lockedFunds − (pending commit ? BOND : 0); the bond is the committer's
///         refundable money, never the game's. lockedFunds covers exactly the unclaimed remainder
///         of every revealed-but-unswept event, so `lockedFunds <= balance` always (system
///         invariant 5) and per-event share math is immutable once revealed.
///
/// @dev    Documented micro-decisions (delegated to agent 4):
///
///         (a) REVEAL REWARD SOURCE — additional treasury draw, NOT carved from the locked
///         prize. sharePerWord stays exactly `tier / slotCount` as the frozen interface
///         documents, and the advertised tier is what the words actually share. To protect
///         invariant 5, a tier is affordable only if free >= tier + 2% reward, and commit gates
///         on the cheapest tier's full cost (tier + reward). Free treasury can never decrease
///         between commit and reveal (claims reduce balance and lockedFunds equally;
///         deposits/sweeps/expiry only add), so against a fixed tier menu a committed event
///         always finds an affordable tier. The one reachable exception: an admin setTiers()
///         between commit and reveal can raise the CHEAPEST tier above what the treasury
///         covers — that path takes the same clean abort as (b) (bond refunded, cycle
///         unconsumed), so a mid-cycle retier can inconvenience one round but never strand
///         funds or the commit.
///
///         (b) CLEAN ABORT when no template is selectable (every template's category
///         requirements exceed current alive counts, or the template list is empty): reveal()
///         clears the commit, refunds the bond, locks nothing, pays no reveal reward, emits
///         RevealAborted, and does NOT consume the 24h cycle — the committer is not at fault
///         for registry drain. The eventId is consumed and never gets an event record
///         (eventInfo returns empty, matching "unknown/unrevealed"). Reverting instead would
///         strand the commit until the blockhash window lapses and unfairly forfeit the bond.
///
///         Further documented choices within charter discretion:
///         - The 24h cycle gate keys off lastEventTimestamp, set only on SUCCESSFUL reveal.
///           Expired and aborted commits do not consume the cycle, so the game never loses a
///           day to a lapse — the bond forfeiture is the whole penalty.
///         - Exactly sharePerWord * slotCount is locked; the sub-slotCount division remainder
///           of the drawn tier (< 7 wei) simply stays in the free treasury.
///         - Bond refund failure (a committer contract rejecting ETH) does NOT revert reveal:
///           the bond is forfeited to the free treasury and BondRefundFailed is emitted.
///           Reverting would let a refund-rejecting committer suppress everyone's reveal for
///           the whole blockhash window — the exact griefing the open reveal exists to prevent.
///         - Tier menu is admin-mutable but hard-bounded to [0.05 ether, 0.5 ether], strictly
///           ascending (tiers[0] is the commit-gate minimum), at most 16 entries (invariant 7:
///           bounded admin). Template ids are array indices and unstable across removeTemplate
///           (swap-and-pop) — like aliveAt ordering, callers must not assume stability.
///         - Entropy seam: _blockhash() is an internal virtual wrapper around the production
///           `blockhash` opcode; tests override it. The seed derivation itself —
///           keccak256(abi.encode(blockhash(targetBlock), address(this), eventId)) — is exactly
///           the architecture spec and is NOT overridable.
///
///         Selection reads ONLY categories and alive counts — never visual traits (system
///         invariant 6). Admin sets the template list and tier menu, never the draw.
contract BountyEngine is IBountyEngine, Ownable, ReentrancyGuardTransient {
    // ─────────────────────────────────── types ─────────────────────────────────────────

    /// @notice A sentence template: ordered category slots plus the literal text around them.
    ///         Rendered sentence = fragments[0] + word(slots[0]) + fragments[1] + ... +
    ///         word(slots[n-1]) + fragments[n], so fragments.length == slots.length + 1.
    struct Template {
        Category[] slots;
        string[] fragments;
    }

    /// @notice The single pending commit. committer == address(0) ⇔ no commit pending.
    struct PendingCommit {
        address committer;
        uint64 targetBlock;
        uint256 eventId;
    }

    /// @notice A revealed generation event. remaining tracks the still-locked unclaimed ETH;
    ///         tokenIds, sharePerWord, and deadline are immutable once written (invariant 5).
    struct BountyEvent {
        uint256[] tokenIds;
        uint128 sharePerWord;
        uint64 deadline;
        bool swept;
        uint128 remaining;
    }

    // ─────────────────────────────────── errors ────────────────────────────────────────

    /// @notice Zero address given where a real one is required.
    error ZeroAddress();
    /// @notice deposit() called with no value.
    error ZeroDeposit();
    /// @notice commit() before the WordBank's alive registry is fully built (SPEC-3 gate):
    ///         the game cannot legitimately run until every minted word is registered.
    error RegistryNotSynced();
    /// @notice commit() while another commit is pending.
    error CommitPending();
    /// @notice commit() before 24h have passed since the last successful reveal.
    error CycleActive(uint256 nextCommitTime);
    /// @notice commit() caller holds no Word NFT.
    error NotHolder();
    /// @notice commit() msg.value is not exactly the 0.01 ETH bond.
    error WrongBond(uint256 sent);
    /// @notice Free treasury cannot cover the cheapest tier plus its reveal reward.
    error InsufficientTreasury(uint256 free, uint256 required);
    /// @notice reveal()/expireCommit() with no commit pending.
    error NoPendingCommit();
    /// @notice reveal() at or before targetBlock.
    error RevealTooEarly(uint256 targetBlock);
    /// @notice reveal() after targetBlock fell out of the 256-block blockhash window.
    error RevealWindowExpired(uint256 lastRevealBlock);
    /// @notice expireCommit() while the reveal window is still open.
    error RevealWindowStillOpen(uint256 lastRevealBlock);
    /// @notice Operation on an eventId with no revealed record.
    error UnknownEvent(uint256 eventId);
    /// @notice claim() for a tokenId that is not in the event's sentence.
    error NotInEvent(uint256 eventId, uint256 tokenId);
    /// @notice claim() for an already-claimed share.
    error AlreadyClaimed(uint256 eventId, uint256 tokenId);
    /// @notice claim() after the event's deadline.
    error DeadlinePassed(uint256 deadline);
    /// @notice claim() caller does not own the token at claim time.
    error NotTokenOwner(uint256 tokenId);
    /// @notice claimMany() with an empty id array.
    error EmptyClaim();
    /// @notice sweep() at or before the deadline.
    error DeadlineNotPassed(uint256 deadline);
    /// @notice sweep() on an already-swept event.
    error AlreadySwept(uint256 eventId);
    /// @notice Template validation failed (slot count not in [1, MAX_SLOTS] or fragments
    ///         length != slots length + 1).
    error InvalidTemplate();
    /// @notice addTemplate() when the menu already holds MAX_TEMPLATES entries (04-1).
    error TooManyTemplates();
    /// @notice removeTemplate() with an out-of-range id.
    error UnknownTemplate(uint256 templateId);
    /// @notice Tier menu validation failed (empty, too long, out of hard bounds, or not
    ///         strictly ascending).
    error InvalidTiers();
    /// @notice ETH payout failed (recipient reverted or has no payable path).
    error EthTransferFailed(address to, uint256 amount);

    // ─────────────────────────────────── events ────────────────────────────────────────

    /// @notice reveal() found no selectable template (or no affordable tier — defensive);
    ///         the commit was cleared and the bond refunded. No event record exists.
    event RevealAborted(uint256 indexed eventId, address indexed committer);
    /// @notice The committer's bond refund call failed; the bond stays in the free treasury.
    event BondRefundFailed(address indexed committer, uint256 amount);
    /// @notice A template was added. templateId is the array index and is unstable across
    ///         removals (swap-and-pop).
    event TemplateAdded(uint256 indexed templateId, Category[] slots, string[] fragments);
    /// @notice A template was removed; the last template (if any) moved into its slot.
    event TemplateRemoved(uint256 indexed templateId);
    /// @notice The tier menu was replaced.
    event TiersSet(uint256[] tiers);

    // ─────────────────────────────────── constants ─────────────────────────────────────

    /// @notice Commit bond, exact (normative).
    uint256 public constant BOND = 0.01 ether;
    /// @notice Blocks between commit and the entropy block (normative, ~3 min mainnet).
    uint256 public constant REVEAL_DELAY = 15;
    /// @notice The EVM blockhash lifetime; the reveal grace period is its natural remainder
    ///         after targetBlock (~241 blocks ≈ 48 min) — deliberately not a separate knob.
    uint256 public constant BLOCKHASH_WINDOW = 256;
    /// @notice Claim window after reveal (normative).
    uint256 public constant CLAIM_WINDOW = 7 days;
    /// @notice Minimum spacing between successful reveals; commit gates on it.
    uint256 public constant CYCLE_LENGTH = 24 hours;
    /// @notice Hardcoded maximum word slots per template (normative).
    uint256 public constant MAX_SLOTS = 7;
    /// @notice Reveal reward: 2% of the drawn prize (normative), drawn from the free
    ///         treasury in addition to the locked prize (micro-decision a).
    uint256 public constant REVEAL_REWARD_BPS = 200;
    /// @dev Basis-point denominator.
    uint256 private constant BPS = 10_000;
    /// @notice Hard lower bound for any admin-set tier value (invariant 7: bounded admin).
    ///         Lowered from 0.1 to 0.05 ETH by owner decision (2026-06-13) so the daily game
    ///         stays runnable on a thin treasury: the cheapest full event (tier + 2% reveal
    ///         reward) now costs 0.051 ETH. Worst case at the floor, a 7-word sentence pays
    ///         ~0.0071 ETH/word — still claimable at normal mainnet gas; claimMany batches
    ///         multi-word wins through gas spikes.
    uint256 public constant MIN_TIER_VALUE = 0.05 ether;
    /// @notice Hard upper bound for any admin-set tier value.
    uint256 public constant MAX_TIER_VALUE = 0.5 ether;
    /// @notice Hard cap on tier menu length.
    uint256 public constant MAX_TIERS = 16;
    /// @notice Hard cap on the template menu (security finding 04-1, invariant 7: bounded
    ///         admin). reveal()'s feasibility scan walks every template, so an uncapped menu
    ///         is an admin-inflicted gas DoS on the game's core loop. 32 is several times
    ///         the sentence variety a daily game needs (the tier menu beside it caps at 16),
    ///         while 32 scans of a ≤7-slot template are dwarfed by reveal()'s registry reads
    ///         — orders of magnitude below any block gas concern.
    uint256 public constant MAX_TEMPLATES = 32;

    /// @dev Category cardinality. Must equal uint256(type(Category).max) + 1 — solc rejects
    ///      that expression as an array length, so the constructor asserts the match (the
    ///      frozen enum cannot change without an interface tag bump anyway).
    uint256 private constant NUM_CATEGORIES = 4;

    /// @dev Seed domain separators: one independent draw stream per decision.
    uint256 private constant DOMAIN_TEMPLATE = 0;
    uint256 private constant DOMAIN_SLOT = 1;
    uint256 private constant DOMAIN_TIER = 2;

    // ─────────────────────────────────── storage ───────────────────────────────────────

    /// @notice The ERC-721 + binding vault: holder gate, alive registry, claim-auth oracle.
    IWordBank public immutable wordBank;

    /// @inheritdoc IBountyEngine
    uint256 public override lockedFunds;

    /// @notice The single pending commit (committer == 0 ⇔ none).
    PendingCommit public currentCommit;

    /// @notice Next eventId to assign at commit. Starts at 1 so eventId 0 is never valid.
    uint256 public nextEventId = 1;

    /// @notice Timestamp of the last SUCCESSFUL reveal; commit requires 24h elapsed.
    ///         Aborts and expiries do not touch it (documented choice).
    uint256 public lastEventTimestamp;

    /// @notice Revealed events by id.
    mapping(uint256 => BountyEvent) private _events;

    /// @notice claimed[eventId][tokenId] — a word's share is claimable exactly once.
    mapping(uint256 => mapping(uint256 => bool)) public claimed;

    /// @dev Sentence templates; ids are indices, unstable across removals.
    Template[] private _templates;

    /// @dev Strictly ascending tier menu, each within [MIN_TIER_VALUE, MAX_TIER_VALUE].
    uint256[] private _tiers;

    // ────────────────────────────────── constructor ────────────────────────────────────

    /// @param wordBank_ The WordBank (immutable; no upgradeability anywhere).
    /// @param owner_    Admin for template/tier menus — never the draw.
    constructor(address wordBank_, address owner_) Ownable(owner_) {
        if (wordBank_ == address(0)) revert ZeroAddress();
        assert(NUM_CATEGORIES == uint256(type(Category).max) + 1); // frozen-enum guard
        wordBank = IWordBank(wordBank_);

        // Launch tier menu: the six normative values plus the 0.05 thin-treasury floor
        // (owner decision 2026-06-13 — active out of the box, not merely allowed).
        // Admin-replaceable within hard bounds.
        uint256[] memory launchTiers = new uint256[](7);
        launchTiers[0] = 0.05 ether;
        launchTiers[1] = 0.1 ether;
        launchTiers[2] = 0.2 ether;
        launchTiers[3] = 0.25 ether;
        launchTiers[4] = 0.3 ether;
        launchTiers[5] = 0.4 ether;
        launchTiers[6] = 0.5 ether;
        _tiers = launchTiers;
        emit TiersSet(launchTiers);
    }

    // ─────────────────────────────────── treasury ──────────────────────────────────────

    /// @inheritdoc IBountyEngine
    function deposit() external payable {
        if (msg.value == 0) revert ZeroDeposit();
        emit TreasuryDeposit(msg.sender, msg.value);
    }

    /// @notice Plain ETH transfers are donations to the treasury.
    receive() external payable {
        emit TreasuryDeposit(msg.sender, msg.value);
    }

    // ────────────────────────────────── game cycle ─────────────────────────────────────

    /// @inheritdoc IBountyEngine
    /// @dev Gate order: registry synced (SPEC-3: the game must not run while the alive
    ///      registry is still being built during the open mint — TM-R6 draw steering), then
    ///      single pending commit, 24h since last successful reveal, holder, exact bond, and
    ///      treasury. The treasury gate requires the CHEAPEST FULL EVENT COST (minimum tier +
    ///      its 2% reveal reward, micro-decision a) so that a committed event is always
    ///      revealable — free treasury cannot decrease before its reveal.
    function commit() external payable nonReentrant {
        if (!IRegistrySync(address(wordBank)).registrySynced()) revert RegistryNotSynced();
        if (currentCommit.committer != address(0)) revert CommitPending();
        uint256 nextCommitTime = lastEventTimestamp + CYCLE_LENGTH;
        // lastEventTimestamp == 0 ⇔ no successful reveal yet: the first cycle is free
        if (lastEventTimestamp != 0 && block.timestamp < nextCommitTime) revert CycleActive(nextCommitTime);
        if (wordBank.balanceOf(msg.sender) == 0) revert NotHolder();
        if (msg.value != BOND) revert WrongBond(msg.value);

        uint256 eventId = nextEventId++;
        uint256 targetBlock = block.number + REVEAL_DELAY;
        currentCommit = PendingCommit({committer: msg.sender, targetBlock: uint64(targetBlock), eventId: eventId});

        uint256 minTier = _tiers[0];
        uint256 minCost = minTier + (minTier * REVEAL_REWARD_BPS) / BPS;
        uint256 free = freeTreasury(); // bond already in balance, excluded via currentCommit
        if (free < minCost) revert InsufficientTreasury(free, minCost);

        emit Committed(eventId, msg.sender, targetBlock);
    }

    /// @inheritdoc IBountyEngine
    /// @dev Seed is exactly the architecture spec:
    ///      keccak256(abi.encode(blockhash(targetBlock), address(this), eventId)).
    ///      All state is final before any ETH moves (CEI + transient reentrancy guard).
    ///      Reverts only on timing; infeasibility aborts cleanly (micro-decision b).
    function reveal() external nonReentrant {
        PendingCommit memory c = currentCommit;
        if (c.committer == address(0)) revert NoPendingCommit();
        if (block.number <= c.targetBlock) revert RevealTooEarly(c.targetBlock);
        uint256 lastRevealBlock = uint256(c.targetBlock) + BLOCKHASH_WINDOW;
        if (block.number > lastRevealBlock) revert RevealWindowExpired(lastRevealBlock);

        bytes32 seed = keccak256(abi.encode(_blockhash(c.targetBlock), address(this), c.eventId));

        uint256[NUM_CATEGORIES] memory alive;
        for (uint256 i; i < NUM_CATEGORIES; ++i) {
            alive[i] = wordBank.aliveCount(Category(i));
        }

        (bool templateFound, uint256 templateId) = _drawTemplate(seed, alive);
        if (!templateFound) {
            _abort(c);
            return;
        }

        uint256[] memory tokenIds = _fillSlots(seed, _templates[templateId].slots, alive);

        (bool tierFound, uint256 amount) = _drawTier(seed);
        if (!tierFound) {
            // Reachable only if an admin setTiers() between commit and reveal raised the
            // cheapest tier above the free treasury — the commit gate rules out every other
            // path (free treasury never decreases between commit and reveal). Same clean
            // abort as the no-template case: bond refunded, cycle unconsumed.
            _abort(c);
            return;
        }

        uint256 n = tokenIds.length;
        uint256 sharePerWord = amount / n;
        uint256 lockAmount = sharePerWord * n; // division remainder (< n wei) stays free
        uint256 deadline = block.timestamp + CLAIM_WINDOW;

        BountyEvent storage ev = _events[c.eventId];
        ev.tokenIds = tokenIds;
        ev.sharePerWord = uint128(sharePerWord);
        ev.deadline = uint64(deadline);
        ev.remaining = uint128(lockAmount);
        lockedFunds += lockAmount;
        lastEventTimestamp = block.timestamp;
        delete currentCommit;

        string[] memory words = new string[](n);
        for (uint256 i; i < n; ++i) {
            words[i] = wordBank.wordOf(tokenIds[i]);
        }
        emit SentenceGenerated(c.eventId, tokenIds, words, templateId, lockAmount, sharePerWord, deadline);

        _pay(msg.sender, (amount * REVEAL_REWARD_BPS) / BPS);
        _refundBond(c.committer);
    }

    /// @inheritdoc IBountyEngine
    /// @dev The forfeited bond needs no accounting move: with the commit cleared it is no
    ///      longer excluded from the free treasury. The 24h cycle is NOT consumed — a fresh
    ///      commit is allowed immediately, so a lapse never costs the game a day.
    function expireCommit() external {
        PendingCommit memory c = currentCommit;
        if (c.committer == address(0)) revert NoPendingCommit();
        uint256 lastRevealBlock = uint256(c.targetBlock) + BLOCKHASH_WINDOW;
        if (block.number <= lastRevealBlock) revert RevealWindowStillOpen(lastRevealBlock);
        delete currentCommit;
        emit CommitExpired(c.eventId, c.committer, BOND);
    }

    // ──────────────────────────────────── claims ───────────────────────────────────────

    /// @inheritdoc IBountyEngine
    function claim(uint256 eventId, uint256 tokenId) external nonReentrant {
        uint256 amount = _claimOne(eventId, tokenId);
        _pay(msg.sender, amount);
    }

    /// @inheritdoc IBountyEngine
    /// @dev Duplicate ids in one batch revert on AlreadyClaimed — nothing is skipped
    ///      silently. Single ETH transfer at the end; all state final before it.
    function claimMany(uint256 eventId, uint256[] calldata tokenIds) external nonReentrant {
        uint256 len = tokenIds.length;
        if (len == 0) revert EmptyClaim();
        uint256 total;
        for (uint256 i; i < len; ++i) {
            total += _claimOne(eventId, tokenIds[i]);
        }
        _pay(msg.sender, total);
    }

    /// @dev Shared per-token claim path. Claim-time ownership: wordBank.ownerOf reverts for
    ///      burned ids (frozen IWordBank guarantee), which is exactly how an unbound word's
    ///      share becomes permanently unclaimable and falls through to the sweep.
    function _claimOne(uint256 eventId, uint256 tokenId) private returns (uint256 sharePerWord) {
        BountyEvent storage ev = _events[eventId];
        if (ev.deadline == 0) revert UnknownEvent(eventId);
        if (block.timestamp > ev.deadline) revert DeadlinePassed(ev.deadline);
        if (!_inEvent(ev, tokenId)) revert NotInEvent(eventId, tokenId);
        if (claimed[eventId][tokenId]) revert AlreadyClaimed(eventId, tokenId);
        if (wordBank.ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);

        claimed[eventId][tokenId] = true;
        sharePerWord = ev.sharePerWord;
        ev.remaining -= uint128(sharePerWord);
        lockedFunds -= sharePerWord;
        emit BountyClaimed(eventId, tokenId, msg.sender, sharePerWord);
    }

    /// @inheritdoc IBountyEngine
    /// @dev Second sweep reverts (AlreadySwept) — documented choice over silent no-op so
    ///      keeper scripts learn they are wasting gas.
    function sweep(uint256 eventId) external {
        BountyEvent storage ev = _events[eventId];
        if (ev.deadline == 0) revert UnknownEvent(eventId);
        if (block.timestamp <= ev.deadline) revert DeadlineNotPassed(ev.deadline);
        if (ev.swept) revert AlreadySwept(eventId);

        ev.swept = true;
        uint256 amountReturned = ev.remaining;
        ev.remaining = 0;
        lockedFunds -= amountReturned;
        emit EventSwept(eventId, amountReturned);
    }

    // ──────────────────────────────────── admin ────────────────────────────────────────

    /// @notice Adds a sentence template. Slots are part-of-speech categories in sentence
    ///         order; fragments are the literal text around them (fragments.length ==
    ///         slots.length + 1, empty strings allowed).
    /// @dev    Bounded by the hardcoded MAX_SLOTS = 7 (normative) per template and
    ///         MAX_TEMPLATES = 32 templates total (04-1, invariant 7 — reveal() scans the
    ///         whole menu, so its length must be hard-capped). Admin shapes the menu,
    ///         never the draw.
    /// @return templateId The new template's id (current array index).
    function addTemplate(Category[] calldata slots, string[] calldata fragments)
        external
        onlyOwner
        returns (uint256 templateId)
    {
        if (_templates.length == MAX_TEMPLATES) revert TooManyTemplates();
        uint256 n = slots.length;
        if (n == 0 || n > MAX_SLOTS || fragments.length != n + 1) revert InvalidTemplate();
        templateId = _templates.length;
        Template storage t = _templates.push();
        t.slots = slots;
        // element-wise: string[] calldata → storage is unimplemented in the legacy codegen
        for (uint256 i; i <= n; ++i) {
            t.fragments.push(fragments[i]);
        }
        emit TemplateAdded(templateId, slots, fragments);
    }

    /// @notice Removes a template by id (swap-and-pop: the last template takes its id).
    function removeTemplate(uint256 templateId) external onlyOwner {
        uint256 len = _templates.length;
        if (templateId >= len) revert UnknownTemplate(templateId);
        uint256 last = len - 1;
        if (templateId != last) {
            _templates[templateId] = _templates[last];
        }
        _templates.pop();
        emit TemplateRemoved(templateId);
    }

    /// @notice Replaces the tier menu. Strictly ascending, 1–16 entries, every value within
    ///         the hardcoded [0.05 ether, 0.5 ether] bounds — the admin can tune the menu but
    ///         never exceed the normative range or influence the draw.
    function setTiers(uint256[] calldata tiers_) external onlyOwner {
        uint256 len = tiers_.length;
        if (len == 0 || len > MAX_TIERS) revert InvalidTiers();
        uint256 prev;
        for (uint256 i; i < len; ++i) {
            uint256 tier = tiers_[i];
            if (tier < MIN_TIER_VALUE || tier > MAX_TIER_VALUE || tier <= prev) revert InvalidTiers();
            prev = tier;
        }
        _tiers = tiers_;
        emit TiersSet(tiers_);
    }

    // ──────────────────────────────────── views ────────────────────────────────────────

    /// @inheritdoc IBountyEngine
    function isClaimable(uint256 eventId, uint256 tokenId) external view returns (bool) {
        BountyEvent storage ev = _events[eventId];
        if (ev.deadline == 0 || block.timestamp > ev.deadline) return false;
        if (claimed[eventId][tokenId]) return false;
        if (!_inEvent(ev, tokenId)) return false;
        return wordBank.isAlive(tokenId);
    }

    /// @inheritdoc IBountyEngine
    function eventInfo(uint256 eventId)
        external
        view
        returns (uint256[] memory tokenIds, uint256 sharePerWord, uint256 deadline, bool swept)
    {
        BountyEvent storage ev = _events[eventId];
        return (ev.tokenIds, ev.sharePerWord, ev.deadline, ev.swept);
    }

    /// @notice Still-locked unclaimed ETH of one event (0 once swept). The sum over all
    ///         events equals lockedFunds at all times — the invariant tests lean on this.
    function remainingLocked(uint256 eventId) external view returns (uint256) {
        return _events[eventId].remaining;
    }

    /// @notice Spendable treasury: balance minus locked event funds minus a pending
    ///         committer's refundable bond.
    function freeTreasury() public view returns (uint256) {
        uint256 reserved = lockedFunds;
        if (currentCommit.committer != address(0)) reserved += BOND;
        return address(this).balance - reserved;
    }

    /// @notice Number of templates currently in the menu.
    function templateCount() external view returns (uint256) {
        return _templates.length;
    }

    /// @notice One template's slots and literal fragments.
    function getTemplate(uint256 templateId)
        external
        view
        returns (Category[] memory slots, string[] memory fragments)
    {
        if (templateId >= _templates.length) {
            revert UnknownTemplate(templateId);
        }
        Template storage t = _templates[templateId];
        return (t.slots, t.fragments);
    }

    /// @notice The current tier menu, strictly ascending.
    function tiers() external view returns (uint256[] memory) {
        return _tiers;
    }

    // ─────────────────────────────────── internal ──────────────────────────────────────

    /// @dev Entropy seam: production blockhash, overridable ONLY in test harnesses. The
    ///      timing checks in reveal() guarantee a nonzero hash on mainnet.
    function _blockhash(uint256 blockNumber) internal view virtual returns (bytes32) {
        return blockhash(blockNumber);
    }

    /// @dev Uniform draw over the feasible templates (those whose per-category slot
    ///      requirements all fit within current alive counts). found == false ⇔ none.
    function _drawTemplate(bytes32 seed, uint256[NUM_CATEGORIES] memory alive)
        private
        view
        returns (bool found, uint256 templateId)
    {
        uint256 len = _templates.length;
        uint256[] memory feasible = new uint256[](len);
        uint256 feasibleCount;
        for (uint256 t; t < len; ++t) {
            if (_isFeasible(_templates[t].slots, alive)) {
                feasible[feasibleCount++] = t;
            }
        }
        if (feasibleCount == 0) return (false, 0);
        uint256 pick = uint256(keccak256(abi.encode(seed, DOMAIN_TEMPLATE))) % feasibleCount;
        return (true, feasible[pick]);
    }

    /// @dev A template is feasible iff, for every category, the number of slots demanding
    ///      that category does not exceed its alive count — the condition that makes the
    ///      dedup re-draw provably terminate.
    function _isFeasible(Category[] storage slots, uint256[NUM_CATEGORIES] memory alive) private view returns (bool) {
        uint256[NUM_CATEGORIES] memory need;
        uint256 n = slots.length;
        for (uint256 i; i < n; ++i) {
            uint256 c = uint256(slots[i]);
            if (++need[c] > alive[c]) return false;
        }
        return true;
    }

    /// @dev Fills each slot with a uniform draw over its category's alive array, dedup by
    ///      deterministic index stepping: on collision advance (idx + 1) % count. Each
    ///      tokenId occupies one unique index and at most 6 prior draws exist, so the walk
    ///      passes at most 6 occupied indices before a free one — bounded, always terminates
    ///      (feasibility guarantees count >= draws needed per category).
    function _fillSlots(bytes32 seed, Category[] storage slots, uint256[NUM_CATEGORIES] memory alive)
        private
        view
        returns (uint256[] memory tokenIds)
    {
        uint256 n = slots.length;
        tokenIds = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            Category cat = slots[i];
            uint256 count = alive[uint256(cat)];
            uint256 idx = uint256(keccak256(abi.encode(seed, DOMAIN_SLOT, i))) % count;
            uint256 tokenId = wordBank.aliveAt(cat, idx);
            while (_alreadyDrawn(tokenIds, i, tokenId)) {
                idx = (idx + 1) % count;
                tokenId = wordBank.aliveAt(cat, idx);
            }
            tokenIds[i] = tokenId;
        }
    }

    /// @dev True iff tokenId is among the first `drawnCount` entries of ids.
    function _alreadyDrawn(uint256[] memory ids, uint256 drawnCount, uint256 tokenId) private pure returns (bool) {
        for (uint256 j; j < drawnCount; ++j) {
            if (ids[j] == tokenId) return true;
        }
        return false;
    }

    /// @dev Uniform draw over only the tiers whose full cost (tier + 2% reveal reward,
    ///      micro-decision a) fits in the free treasury. found == false ⇔ none affordable.
    function _drawTier(bytes32 seed) private view returns (bool found, uint256 amount) {
        uint256 free = freeTreasury();
        uint256 len = _tiers.length;
        uint256[] memory affordable = new uint256[](len);
        uint256 affordableCount;
        for (uint256 i; i < len; ++i) {
            uint256 tier = _tiers[i];
            if (free >= tier + (tier * REVEAL_REWARD_BPS) / BPS) {
                affordable[affordableCount++] = tier;
            }
        }
        if (affordableCount == 0) return (false, 0);
        uint256 pick = uint256(keccak256(abi.encode(seed, DOMAIN_TIER))) % affordableCount;
        return (true, affordable[pick]);
    }

    /// @dev Clean abort (micro-decision b): clear the commit, refund the bond, lock nothing,
    ///      pay no reveal reward, leave the 24h cycle unconsumed. The eventId never gets a
    ///      record.
    function _abort(PendingCommit memory c) private {
        delete currentCommit;
        emit RevealAborted(c.eventId, c.committer);
        _refundBond(c.committer);
    }

    /// @dev Bond refund tolerates failure (forfeits to the free treasury) so a
    ///      refund-rejecting committer can never block reveal — see contract NatSpec.
    function _refundBond(address committer) private {
        (bool ok,) = committer.call{value: BOND}("");
        if (!ok) emit BondRefundFailed(committer, BOND);
    }

    /// @dev Membership scan over the event's word set (<= 7 entries).
    function _inEvent(BountyEvent storage ev, uint256 tokenId) private view returns (bool) {
        uint256 n = ev.tokenIds.length;
        for (uint256 i; i < n; ++i) {
            if (ev.tokenIds[i] == tokenId) return true;
        }
        return false;
    }

    /// @dev ETH out via call (convention: no transfer()); reverts on failure — a recipient
    ///      that cannot receive ETH fails only its own claim/reveal.
    function _pay(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed(to, amount);
    }
}
