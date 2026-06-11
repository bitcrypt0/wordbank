// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BountyEngine} from "../../src/BountyEngine.sol";
import {IBountyEngine} from "../../src/interfaces/IBountyEngine.sol";
import {Category} from "../../src/interfaces/Types.sol";
import {MockWordBankRegistry} from "../mocks/MockWordBankRegistry.sol";

/// @dev Entropy seam for tests: overrides ONLY the _blockhash wrapper. The seed derivation
///      (keccak256(abi.encode(blockhash, address(this), eventId))) stays production code.
contract BountyEngineHarness is BountyEngine {
    bytes32 private _forced;
    bool private _useForced;

    constructor(address bank, address owner) BountyEngine(bank, owner) {}

    function setBlockhash(bytes32 h) external {
        _forced = h;
        _useForced = true;
    }

    function _blockhash(uint256 blockNumber) internal view override returns (bytes32) {
        return _useForced ? _forced : blockhash(blockNumber);
    }
}

/// @dev A committer contract that rejects ETH — its bond refund must fail without blocking
///      reveal (the engine forfeits the bond instead).
contract RejectingCommitter {
    BountyEngine private immutable engine;

    constructor(BountyEngine engine_) {
        engine = engine_;
    }

    function doCommit() external payable {
        engine.commit{value: msg.value}();
    }
    // no receive(): all ETH sends to this contract revert
}

/// @dev A claimant contract that rejects ETH — its own claim must revert (EthTransferFailed),
///      harming nobody else.
contract RejectingClaimer {
    BountyEngine private immutable engine;

    constructor(BountyEngine engine_) {
        engine = engine_;
    }

    function doClaim(uint256 eventId, uint256 tokenId) external {
        engine.claim(eventId, tokenId);
    }
}

// ═══════════════════════════════════════ base ═══════════════════════════════════════════

abstract contract BountyEngineTestBase is Test {
    uint256 internal constant BOND = 0.01 ether;
    uint256 internal constant MIN_TIER = 0.05 ether;
    /// @dev Cheapest full event cost: min tier + its 2% reveal reward (micro-decision a).
    uint256 internal constant MIN_COST = 0.051 ether;

    BountyEngineHarness internal engine;
    MockWordBankRegistry internal bank;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice"); // default holder of every word
    address internal bob = makeAddr("bob"); // default revealer, holds nothing
    address internal carol = makeAddr("carol"); // transferee in ownership tests

    /// @dev Tests sometimes reveal as the test contract itself — accept the reveal reward.
    receive() external payable {}

    function setUp() public virtual {
        bank = new MockWordBankRegistry();
        engine = new BountyEngineHarness(address(bank), admin);

        // Populations: 5 nouns, 3 verbs, 3 adjectives, 1 adverb — all alice's.
        bank.mint(1, Category.NOUN, "moon", alice);
        bank.mint(2, Category.NOUN, "rug", alice);
        bank.mint(3, Category.NOUN, "dev", alice);
        bank.mint(4, Category.NOUN, "floor", alice);
        bank.mint(5, Category.NOUN, "gas", alice);
        bank.mint(11, Category.VERB, "pumps", alice);
        bank.mint(12, Category.VERB, "dumps", alice);
        bank.mint(13, Category.VERB, "sweeps", alice);
        bank.mint(21, Category.ADJ, "liquid", alice);
        bank.mint(22, Category.ADJ, "rare", alice);
        bank.mint(23, Category.ADJ, "golden", alice);
        bank.mint(31, Category.ADV, "quickly", alice);

        // Template 0: "The {ADJ} {NOUN} {VERB} daily." — 3 slots.
        Category[] memory slots = new Category[](3);
        slots[0] = Category.ADJ;
        slots[1] = Category.NOUN;
        slots[2] = Category.VERB;
        vm.prank(admin);
        engine.addTemplate(slots, _fragments4("The ", " ", " ", " daily."));

        vm.deal(address(this), 1000 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 1 ether);
        vm.deal(carol, 1 ether);
    }

    // ─────────────────────────────────── helpers ───────────────────────────────────────

    function _fragments4(string memory a, string memory b, string memory c, string memory d)
        internal
        pure
        returns (string[] memory frags)
    {
        frags = new string[](4);
        frags[0] = a;
        frags[1] = b;
        frags[2] = c;
        frags[3] = d;
    }

    function _fund(uint256 amount) internal {
        engine.deposit{value: amount}();
    }

    /// @dev Commits as `who`, warping past the 24h cycle if needed.
    function _commit(address who) internal returns (uint256 eventId, uint256 targetBlock) {
        uint256 nextCommitTime = engine.lastEventTimestamp() + engine.CYCLE_LENGTH();
        if (block.timestamp < nextCommitTime) vm.warp(nextCommitTime);
        eventId = engine.nextEventId();
        vm.prank(who);
        engine.commit{value: BOND}();
        targetBlock = block.number + engine.REVEAL_DELAY();
    }

    /// @dev Rolls past targetBlock and reveals as bob with forced entropy `h`.
    function _reveal(bytes32 h) internal {
        (, uint64 targetBlock,) = engine.currentCommit();
        engine.setBlockhash(h);
        vm.roll(uint256(targetBlock) + 1);
        vm.prank(bob);
        engine.reveal();
    }

    function _runCycle(bytes32 h) internal returns (uint256 eventId) {
        (eventId,) = _commit(alice);
        _reveal(h);
    }

    /// @dev Recovers the drawn tier from the immutable share (menu values are distinct
    ///      after division by any n <= 7).
    function _tierFromShare(uint256 sharePerWord, uint256 n) internal view returns (uint256) {
        uint256[] memory menu = engine.tiers();
        for (uint256 i; i < menu.length; ++i) {
            if (menu[i] / n == sharePerWord) return menu[i];
        }
        revert("tier not found in menu");
    }
}

// ══════════════════════════════ commit / reveal / expire ════════════════════════════════

contract BountyEngineCycleTest is BountyEngineTestBase {
    function test_CommitStoresStateAndEmits() public {
        _fund(1 ether);
        vm.expectEmit(true, true, true, true);
        emit IBountyEngine.Committed(1, alice, block.number + 15);
        vm.prank(alice);
        engine.commit{value: BOND}();

        (address committer, uint64 targetBlock, uint256 eventId) = engine.currentCommit();
        assertEq(committer, alice);
        assertEq(targetBlock, block.number + 15);
        assertEq(eventId, 1);
        assertEq(engine.nextEventId(), 2);
        // the bond is the committer's money, not the game's
        assertEq(engine.freeTreasury(), 1 ether);
    }

    function test_CommitRevert_RegistryNotSynced() public {
        // SPEC-3 game-start gate: while the WordBank's alive registry is still being built
        // (open mint), commit must fail fast — before any other gate is even evaluated.
        _fund(1 ether);
        bank.setRegistrySynced(false);
        vm.prank(alice);
        vm.expectRevert(BountyEngine.RegistryNotSynced.selector);
        engine.commit{value: BOND}();

        // flip synced: the identical commit now passes the gate and succeeds
        bank.setRegistrySynced(true);
        vm.prank(alice);
        engine.commit{value: BOND}();
        (address committer,,) = engine.currentCommit();
        assertEq(committer, alice);
    }

    function test_CommitRevert_NotHolder() public {
        _fund(1 ether);
        vm.prank(bob);
        vm.expectRevert(BountyEngine.NotHolder.selector);
        engine.commit{value: BOND}();
    }

    function test_CommitRevert_WrongBond() public {
        _fund(1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.WrongBond.selector, BOND + 1));
        engine.commit{value: BOND + 1}();
    }

    function test_CommitRevert_DoublePending() public {
        _fund(1 ether);
        _commit(alice);
        vm.prank(alice);
        vm.expectRevert(BountyEngine.CommitPending.selector);
        engine.commit{value: BOND}();
    }

    function test_CommitGate_ExactlyMinimumCost() public {
        _fund(MIN_COST - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.InsufficientTreasury.selector, MIN_COST - 1, MIN_COST));
        engine.commit{value: BOND}();

        _fund(1); // top up to exactly MIN_COST
        vm.prank(alice);
        engine.commit{value: BOND}();
    }

    function test_RevealRevert_NoCommit() public {
        vm.expectRevert(BountyEngine.NoPendingCommit.selector);
        engine.reveal();
    }

    function test_RevealRevert_TooEarly() public {
        _fund(1 ether);
        (, uint256 targetBlock) = _commit(alice);
        vm.roll(targetBlock); // exactly targetBlock: still too early
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.RevealTooEarly.selector, targetBlock));
        engine.reveal();
    }

    function test_RevealRevert_WindowExpired() public {
        _fund(1 ether);
        (, uint256 targetBlock) = _commit(alice);
        vm.roll(targetBlock + 257);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.RevealWindowExpired.selector, targetBlock + 256));
        engine.reveal();
    }

    function test_RevealAtWindowEdgeWorks() public {
        _fund(1 ether);
        (uint256 eventId, uint256 targetBlock) = _commit(alice);
        engine.setBlockhash(keccak256("edge"));
        vm.roll(targetBlock + 256); // last revealable block
        engine.reveal();
        (, uint256 sharePerWord,,) = engine.eventInfo(eventId);
        assertGt(sharePerWord, 0);
    }

    function test_RevealHappyPath() public {
        _fund(1 ether);
        (uint256 eventId,) = _commit(alice);

        uint256 aliceBefore = alice.balance; // bond already posted
        uint256 bobBefore = bob.balance;

        vm.recordLogs();
        _reveal(keccak256("happy"));

        // event record
        (uint256[] memory tokenIds, uint256 sharePerWord, uint256 deadline, bool swept) = engine.eventInfo(eventId);
        assertEq(tokenIds.length, 3);
        assertEq(deadline, block.timestamp + 7 days);
        assertFalse(swept);

        // slots match template 0's categories and every word is alive
        assertEq(uint256(bank.categoryOf(tokenIds[0])), uint256(Category.ADJ));
        assertEq(uint256(bank.categoryOf(tokenIds[1])), uint256(Category.NOUN));
        assertEq(uint256(bank.categoryOf(tokenIds[2])), uint256(Category.VERB));
        for (uint256 i; i < 3; ++i) {
            assertTrue(bank.isAlive(tokenIds[i]));
            assertTrue(engine.isClaimable(eventId, tokenIds[i]));
        }

        // share math: tier / n, locked = share * n
        uint256 tier = _tierFromShare(sharePerWord, 3);
        assertEq(sharePerWord, tier / 3);
        assertEq(engine.lockedFunds(), sharePerWord * 3);
        assertEq(engine.remainingLocked(eventId), sharePerWord * 3);

        // payouts: 2% reveal reward to bob (additional treasury draw), bond back to alice
        assertEq(bob.balance - bobBefore, (tier * 200) / 10_000);
        assertEq(alice.balance - aliceBefore, BOND);

        // commit cleared, cycle consumed
        (address committer,,) = engine.currentCommit();
        assertEq(committer, address(0));
        assertEq(engine.lastEventTimestamp(), block.timestamp);

        // SentenceGenerated carries the resolved words
        _assertSentenceLog(eventId, tokenIds, sharePerWord);
    }

    function _assertSentenceLog(uint256 eventId, uint256[] memory tokenIds, uint256 sharePerWord) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("SentenceGenerated(uint256,uint256[],string[],uint256,uint256,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            found = true;
            assertEq(uint256(logs[i].topics[1]), eventId);
            (uint256[] memory ids, string[] memory words, uint256 templateId, uint256 amount, uint256 share,) =
                abi.decode(logs[i].data, (uint256[], string[], uint256, uint256, uint256, uint256));
            assertEq(templateId, 0);
            assertEq(amount, sharePerWord * 3);
            assertEq(share, sharePerWord);
            for (uint256 j; j < ids.length; ++j) {
                assertEq(ids[j], tokenIds[j]);
                assertEq(words[j], bank.wordOf(tokenIds[j]));
            }
        }
        assertTrue(found, "SentenceGenerated not emitted");
    }

    function test_RevealCallableByAnyone() public {
        _fund(1 ether);
        (uint256 eventId, uint256 targetBlock) = _commit(alice);
        engine.setBlockhash(keccak256("anyone"));
        vm.roll(targetBlock + 1);
        vm.prank(carol); // neither committer nor holder
        engine.reveal();
        (, uint256 sharePerWord,,) = engine.eventInfo(eventId);
        assertGt(sharePerWord, 0);
    }

    function test_CycleConsumedOnlyOnSuccessfulReveal() public {
        _fund(1 ether);
        _runCycle(keccak256("cycle"));
        uint256 revealedAt = engine.lastEventTimestamp();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.CycleActive.selector, revealedAt + 24 hours));
        engine.commit{value: BOND}();

        vm.warp(revealedAt + 24 hours - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.CycleActive.selector, revealedAt + 24 hours));
        engine.commit{value: BOND}();

        vm.warp(revealedAt + 24 hours);
        vm.prank(alice);
        engine.commit{value: BOND}();
    }

    function test_ExpireRevert_WindowStillOpen() public {
        _fund(1 ether);
        (, uint256 targetBlock) = _commit(alice);
        vm.roll(targetBlock + 256); // last revealable block: still open
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.RevealWindowStillOpen.selector, targetBlock + 256));
        engine.expireCommit();
    }

    function test_ExpireRevert_NoCommit() public {
        vm.expectRevert(BountyEngine.NoPendingCommit.selector);
        engine.expireCommit();
    }

    function test_ExpireForfeitsBondAndUnblocksWithoutConsumingCycle() public {
        _fund(1 ether);
        (uint256 eventId, uint256 targetBlock) = _commit(alice);
        uint256 freeBefore = engine.freeTreasury();

        vm.roll(targetBlock + 257);
        vm.expectEmit(true, true, true, true);
        emit IBountyEngine.CommitExpired(eventId, alice, BOND);
        engine.expireCommit();

        // bond forfeited into the free treasury; no locked funds
        assertEq(engine.freeTreasury(), freeBefore + BOND);
        assertEq(engine.lockedFunds(), 0);

        // fresh commit allowed immediately — a lapse never costs the game a day
        vm.prank(alice);
        engine.commit{value: BOND}();
    }

    function test_RevealRevert_AfterExpire() public {
        _fund(1 ether);
        (, uint256 targetBlock) = _commit(alice);
        vm.roll(targetBlock + 257);
        engine.expireCommit();
        vm.expectRevert(BountyEngine.NoPendingCommit.selector);
        engine.reveal();
    }

    function test_ProductionBlockhashPath() public {
        // plain engine (no harness): the production blockhash opcode feeds the seed
        BountyEngine prod = new BountyEngine(address(bank), admin);
        Category[] memory slots = new Category[](1);
        slots[0] = Category.NOUN;
        string[] memory frags = new string[](2);
        frags[0] = "Just ";
        frags[1] = ".";
        vm.prank(admin);
        prod.addTemplate(slots, frags);
        prod.deposit{value: 1 ether}();

        vm.prank(alice);
        prod.commit{value: BOND}();
        uint256 targetBlock = block.number + 15;
        vm.roll(targetBlock + 1);
        vm.setBlockhash(targetBlock, keccak256("mainnet"));
        prod.reveal();

        (uint256[] memory ids, uint256 sharePerWord,,) = prod.eventInfo(1);
        assertEq(ids.length, 1);
        assertGt(sharePerWord, 0);
    }
}

// ═══════════════════════════════════ tier selection ═════════════════════════════════════

contract BountyEngineTierTest is BountyEngineTestBase {
    function test_OnlyMinimumTierAffordable() public {
        _fund(MIN_COST); // exactly the cheapest full event cost
        uint256 eventId = _runCycle(keccak256("min-tier"));
        (, uint256 sharePerWord,,) = engine.eventInfo(eventId);
        assertEq(sharePerWord, MIN_TIER / 3); // 0.05 ETH floor tier forced
        assertEq(engine.lockedFunds(), (MIN_TIER / 3) * 3);
    }

    function testFuzz_DrawnTierAlwaysAffordable(uint96 funding, bytes32 h) public {
        uint256 amount = bound(uint256(funding), MIN_COST, 20 ether);
        _fund(amount);
        (uint256 eventId,) = _commit(alice);
        uint256 freeBefore = engine.freeTreasury(); // bond excluded — equals free at reveal
        _reveal(h);

        (uint256[] memory ids, uint256 sharePerWord,,) = engine.eventInfo(eventId);
        uint256 tier = _tierFromShare(sharePerWord, ids.length);
        uint256 reward = (tier * 200) / 10_000;

        // the drawn tier's full cost fit in the free treasury
        assertLe(tier + reward, freeBefore);
        assertEq(engine.lockedFunds(), sharePerWord * ids.length);
        assertLe(engine.lockedFunds(), address(engine).balance);
    }

    function test_AllTiersReachableWithDeepTreasury() public {
        _fund(100 ether);
        uint256[] memory menu = engine.tiers();
        uint256 seen;
        for (uint256 i; i < 64 && seen != (1 << menu.length) - 1; ++i) {
            uint256 eventId = _runCycle(keccak256(abi.encode("grind", i)));
            (uint256[] memory ids, uint256 sharePerWord,,) = engine.eventInfo(eventId);
            uint256 tier = _tierFromShare(sharePerWord, ids.length);
            for (uint256 t; t < menu.length; ++t) {
                if (menu[t] == tier) seen |= (1 << t);
            }
        }
        assertEq(seen, (1 << menu.length) - 1, "not every tier drawn in 64 cycles");
    }

    function test_TreasuryGrowsIntoLargerTiers() public {
        // with exactly 0.204 free, tiers 0.05, 0.1, and 0.2 are affordable, 0.25+ never
        _fund(0.204 ether);
        for (uint256 i; i < 16; ++i) {
            uint256 eventId = _runCycle(keccak256(abi.encode("grow", i)));
            (uint256[] memory ids, uint256 sharePerWord,,) = engine.eventInfo(eventId);
            uint256 tier = _tierFromShare(sharePerWord, ids.length);
            assertLe(tier, 0.2 ether);
            // restore treasury for the next cycle: re-deposit what the event consumed
            uint256 spent = sharePerWord * ids.length + (tier * 200) / 10_000;
            _fund(spent);
            vm.warp(block.timestamp + 1); // sweep below needs deadline passed later; just claim back
            vm.prank(alice);
            engine.claimMany(eventId, ids);
        }
    }
}

// ═══════════════════════════ templates, dedup, abort path ═══════════════════════════════

contract BountyEngineTemplateTest is BountyEngineTestBase {
    function testFuzz_DedupNeverRepeatsToken(bytes32 h) public {
        // 3-noun template alongside the default; 5 nouns alive
        Category[] memory slots = new Category[](3);
        slots[0] = Category.NOUN;
        slots[1] = Category.NOUN;
        slots[2] = Category.NOUN;
        vm.prank(admin);
        engine.addTemplate(slots, _fragments4("", " ", " ", "!"));

        _fund(1 ether);
        uint256 eventId = _runCycle(h);
        (uint256[] memory ids,,,) = engine.eventInfo(eventId);
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j = i + 1; j < ids.length; ++j) {
                assertNotEq(ids[i], ids[j], "duplicate tokenId in sentence");
            }
        }
    }

    function testFuzz_DedupWithExactPopulation(bytes32 h) public {
        // leave EXACTLY 3 nouns alive, template needs all 3 — re-draw must walk to a
        // permutation of {1,2,3} from any starting index
        vm.prank(admin);
        engine.removeTemplate(0);
        Category[] memory slots = new Category[](3);
        slots[0] = Category.NOUN;
        slots[1] = Category.NOUN;
        slots[2] = Category.NOUN;
        vm.prank(admin);
        engine.addTemplate(slots, _fragments4("", " ", " ", "!"));
        bank.unbind(4);
        bank.unbind(5);

        _fund(1 ether);
        uint256 eventId = _runCycle(h);
        (uint256[] memory ids,,,) = engine.eventInfo(eventId);
        assertEq(ids.length, 3);
        // permutation of {1,2,3}: distinct, each in range
        uint256 mask;
        for (uint256 i; i < 3; ++i) {
            assertTrue(ids[i] >= 1 && ids[i] <= 3);
            mask |= (1 << ids[i]);
        }
        assertEq(mask, 0xE, "not a permutation of {1,2,3}");
    }

    function testFuzz_InfeasibleTemplateSkipped(bytes32 h) public {
        // template 1 demands 3 nouns but only 2 stay alive → only template 0 selectable
        Category[] memory slots = new Category[](3);
        slots[0] = Category.NOUN;
        slots[1] = Category.NOUN;
        slots[2] = Category.NOUN;
        vm.prank(admin);
        engine.addTemplate(slots, _fragments4("", " ", " ", "!"));
        bank.unbind(3);
        bank.unbind(4);
        bank.unbind(5);

        _fund(1 ether);
        uint256 eventId = _runCycle(h);
        (uint256[] memory ids,,,) = engine.eventInfo(eventId);
        // template 0's signature: ADJ NOUN VERB
        assertEq(uint256(bank.categoryOf(ids[0])), uint256(Category.ADJ));
        assertEq(uint256(bank.categoryOf(ids[1])), uint256(Category.NOUN));
        assertEq(uint256(bank.categoryOf(ids[2])), uint256(Category.VERB));
    }

    function test_AbortWhenNoTemplateSelectable() public {
        // drain every noun: the only template (ADJ NOUN VERB) becomes infeasible
        for (uint256 id = 1; id <= 5; ++id) {
            bank.unbind(id);
        }
        _fund(1 ether);
        (uint256 eventId, uint256 targetBlock) = _commit(alice);
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        engine.setBlockhash(keccak256("abort"));
        vm.roll(targetBlock + 1);
        vm.expectEmit(true, true, true, true);
        emit BountyEngine.RevealAborted(eventId, alice);
        vm.prank(bob);
        engine.reveal();

        // bond refunded, no reward, nothing locked, no event record
        assertEq(alice.balance - aliceBefore, BOND);
        assertEq(bob.balance, bobBefore);
        assertEq(engine.lockedFunds(), 0);
        (uint256[] memory ids, uint256 sharePerWord, uint256 deadline,) = engine.eventInfo(eventId);
        assertEq(ids.length, 0);
        assertEq(sharePerWord, 0);
        assertEq(deadline, 0);

        // commit cleared and the 24h cycle NOT consumed — recommit immediately
        (address committer,,) = engine.currentCommit();
        assertEq(committer, address(0));
        vm.prank(alice);
        engine.commit{value: BOND}();
    }

    function test_AbortWhenMidCycleRetierMakesNoTierAffordable() public {
        // M-1 (overseer review): the ONLY reachable no-affordable-tier path — an admin
        // setTiers() between commit and reveal raising the cheapest tier above the treasury.
        // Must take the same clean abort as the no-template case.
        _fund(MIN_COST); // covers exactly the 0.05 ETH floor tier + its 2% reward
        (uint256 eventId, uint256 targetBlock) = _commit(alice);

        uint256[] memory steep = new uint256[](1);
        steep[0] = 0.2 ether; // full cost 0.204 ETH > 0.051 ETH free
        vm.prank(admin);
        engine.setTiers(steep);

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        engine.setBlockhash(keccak256("retier"));
        vm.roll(targetBlock + 1);
        vm.expectEmit(true, true, true, true);
        emit BountyEngine.RevealAborted(eventId, alice);
        vm.prank(bob);
        engine.reveal();

        // bond refunded, no reward, nothing locked, no event record, cycle unconsumed
        assertEq(alice.balance - aliceBefore, BOND);
        assertEq(bob.balance, bobBefore);
        assertEq(engine.lockedFunds(), 0);
        (uint256[] memory ids,, uint256 deadline,) = engine.eventInfo(eventId);
        assertEq(ids.length, 0);
        assertEq(deadline, 0);
        assertEq(engine.lastEventTimestamp(), 0);
    }

    function test_AbortWhenNoTemplatesExist() public {
        vm.prank(admin);
        engine.removeTemplate(0);
        _fund(1 ether);
        (uint256 eventId, uint256 targetBlock) = _commit(alice);
        engine.setBlockhash(keccak256("empty-menu"));
        vm.roll(targetBlock + 1);
        vm.expectEmit(true, true, true, true);
        emit BountyEngine.RevealAborted(eventId, alice);
        engine.reveal();
        assertEq(engine.lockedFunds(), 0);
    }
}

// ═══════════════════════════════════════ claims ═════════════════════════════════════════

contract BountyEngineClaimTest is BountyEngineTestBase {
    uint256 internal eventId;
    uint256[] internal ids;
    uint256 internal share;
    uint256 internal deadline;

    function setUp() public override {
        super.setUp();
        _fund(1 ether);
        eventId = _runCycle(keccak256("claims"));
        (uint256[] memory ids_, uint256 share_, uint256 deadline_,) = engine.eventInfo(eventId);
        ids = ids_;
        share = share_;
        deadline = deadline_;
    }

    function test_ClaimHappyPath() public {
        uint256 before = alice.balance;
        vm.expectEmit(true, true, true, true);
        emit IBountyEngine.BountyClaimed(eventId, ids[0], alice, share);
        vm.prank(alice);
        engine.claim(eventId, ids[0]);

        assertEq(alice.balance - before, share);
        assertTrue(engine.claimed(eventId, ids[0]));
        assertFalse(engine.isClaimable(eventId, ids[0]));
        assertEq(engine.lockedFunds(), share * (ids.length - 1));
        assertEq(engine.remainingLocked(eventId), share * (ids.length - 1));
    }

    function test_ClaimRevert_NotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.NotTokenOwner.selector, ids[0]));
        engine.claim(eventId, ids[0]);
    }

    function test_ClaimTimeOwnership() public {
        // the share travels with the NFT: post-reveal transferee claims, seller cannot
        bank.transfer(ids[0], carol);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.NotTokenOwner.selector, ids[0]));
        engine.claim(eventId, ids[0]);

        uint256 before = carol.balance;
        vm.prank(carol);
        engine.claim(eventId, ids[0]);
        assertEq(carol.balance - before, share);
    }

    function test_ClaimRevert_Double() public {
        vm.prank(alice);
        engine.claim(eventId, ids[0]);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.AlreadyClaimed.selector, eventId, ids[0]));
        engine.claim(eventId, ids[0]);
    }

    function test_ClaimDeadlineBoundary() public {
        vm.warp(deadline); // inclusive: claim at exactly the deadline works
        vm.prank(alice);
        engine.claim(eventId, ids[0]);

        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.DeadlinePassed.selector, deadline));
        engine.claim(eventId, ids[1]);
    }

    function test_ClaimRevert_NotInEvent() public {
        // token 31 (the lone ADV) can never be in template 0's sentence
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.NotInEvent.selector, eventId, 31));
        engine.claim(eventId, 31);
    }

    function test_ClaimRevert_UnknownEvent() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.UnknownEvent.selector, 999));
        engine.claim(999, ids[0]);
    }

    function test_ClaimMany() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        engine.claimMany(eventId, ids);
        assertEq(alice.balance - before, share * ids.length);
        assertEq(engine.lockedFunds(), 0);
        assertEq(engine.remainingLocked(eventId), 0);
    }

    function test_ClaimManyRevert_Empty() public {
        vm.prank(alice);
        vm.expectRevert(BountyEngine.EmptyClaim.selector);
        engine.claimMany(eventId, new uint256[](0));
    }

    function test_ClaimManyRevert_DuplicateInBatch() public {
        uint256[] memory dup = new uint256[](2);
        dup[0] = ids[0];
        dup[1] = ids[0];
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.AlreadyClaimed.selector, eventId, ids[0]));
        engine.claimMany(eventId, dup);
    }

    function test_ClaimManyRevert_OneBadIdRevertsBatch() public {
        bank.transfer(ids[2], carol); // alice no longer owns the verb
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.NotTokenOwner.selector, ids[2]));
        engine.claimMany(eventId, ids);
        // nothing was paid or marked
        assertFalse(engine.claimed(eventId, ids[0]));
        assertEq(engine.lockedFunds(), share * ids.length);
    }

    function test_BurnedWordShareFallsToSweep() public {
        // unbind one sentence word after generation: its share is permanently unclaimable
        bank.unbind(ids[1]);
        assertFalse(engine.isClaimable(eventId, ids[1]));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockWordBankRegistry.NonexistentToken.selector, ids[1]));
        engine.claim(eventId, ids[1]);

        // survivors claim; the burned share falls through to the sweep — never redistributed
        vm.startPrank(alice);
        engine.claim(eventId, ids[0]);
        engine.claim(eventId, ids[2]);
        vm.stopPrank();

        uint256 freeBefore = engine.freeTreasury();
        vm.warp(deadline + 1);
        vm.expectEmit(true, true, true, true);
        emit IBountyEngine.EventSwept(eventId, share);
        engine.sweep(eventId);
        assertEq(engine.freeTreasury(), freeBefore + share);
        assertEq(engine.lockedFunds(), 0);
    }

    function test_RejectingClaimerFailsOwnClaimOnly() public {
        RejectingClaimer claimer = new RejectingClaimer(engine);
        bank.transfer(ids[0], address(claimer));
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.EthTransferFailed.selector, address(claimer), share));
        claimer.doClaim(eventId, ids[0]);

        // everyone else unaffected
        vm.prank(alice);
        engine.claim(eventId, ids[1]);
    }

    function test_IsClaimableMatrix() public {
        assertTrue(engine.isClaimable(eventId, ids[0]));
        assertFalse(engine.isClaimable(999, ids[0])); // unknown event
        assertFalse(engine.isClaimable(eventId, 31)); // not in sentence
        vm.prank(alice);
        engine.claim(eventId, ids[0]);
        assertFalse(engine.isClaimable(eventId, ids[0])); // claimed
        bank.unbind(ids[1]);
        assertFalse(engine.isClaimable(eventId, ids[1])); // burned
        assertTrue(engine.isClaimable(eventId, ids[2])); // still good
        vm.warp(deadline + 1);
        assertFalse(engine.isClaimable(eventId, ids[2])); // deadline passed
    }
}

// ═══════════════════════════════════════ sweep ══════════════════════════════════════════

contract BountyEngineSweepTest is BountyEngineTestBase {
    uint256 internal eventId;
    uint256[] internal ids;
    uint256 internal share;
    uint256 internal deadline;

    function setUp() public override {
        super.setUp();
        _fund(1 ether);
        eventId = _runCycle(keccak256("sweep"));
        (uint256[] memory ids_, uint256 share_, uint256 deadline_,) = engine.eventInfo(eventId);
        ids = ids_;
        share = share_;
        deadline = deadline_;
    }

    function test_SweepRevert_BeforeDeadline() public {
        vm.warp(deadline); // inclusive deadline still claimable → not sweepable
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.DeadlineNotPassed.selector, deadline));
        engine.sweep(eventId);
    }

    function test_SweepRevert_Unknown() public {
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.UnknownEvent.selector, 999));
        engine.sweep(999);
    }

    function test_SweepReturnsRemainderAfterPartialClaims() public {
        vm.prank(alice);
        engine.claim(eventId, ids[0]); // 1 of 3 claimed
        uint256 freeBefore = engine.freeTreasury();

        vm.warp(deadline + 1);
        vm.expectEmit(true, true, true, true);
        emit IBountyEngine.EventSwept(eventId, share * 2);
        engine.sweep(eventId);

        assertEq(engine.freeTreasury(), freeBefore + share * 2);
        assertEq(engine.lockedFunds(), 0);
        assertEq(engine.remainingLocked(eventId), 0);
        (,,, bool swept) = engine.eventInfo(eventId);
        assertTrue(swept);
    }

    function test_SweepRevert_Twice() public {
        vm.warp(deadline + 1);
        engine.sweep(eventId);
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.AlreadySwept.selector, eventId));
        engine.sweep(eventId);
    }

    function test_SweepFullyClaimedEventReturnsZero() public {
        vm.prank(alice);
        engine.claimMany(eventId, ids);
        vm.warp(deadline + 1);
        vm.expectEmit(true, true, true, true);
        emit IBountyEngine.EventSwept(eventId, 0);
        engine.sweep(eventId);
    }

    function test_LockedFundsAcrossOverlappingEvents() public {
        // second cycle while the first event's claim window is still open
        uint256 firstLocked = engine.remainingLocked(eventId);
        uint256 eventId2 = _runCycle(keccak256("overlap"));
        (, uint256 share2,,) = engine.eventInfo(eventId2);
        assertEq(engine.lockedFunds(), firstLocked + share2 * 3);
        assertLe(engine.lockedFunds(), address(engine).balance);

        // claim one from each, sweep the first, locked tracks exactly
        vm.prank(alice);
        engine.claim(eventId, ids[0]);
        (uint256[] memory ids2,,,) = engine.eventInfo(eventId2);
        vm.prank(alice);
        engine.claim(eventId2, ids2[0]);

        vm.warp(deadline + 1);
        engine.sweep(eventId);
        assertEq(engine.lockedFunds(), engine.remainingLocked(eventId2));
        assertEq(engine.remainingLocked(eventId2), share2 * 2);
        assertLe(engine.lockedFunds(), address(engine).balance);
    }
}

// ════════════════════════════════ griefing / treasury ═══════════════════════════════════

contract BountyEngineGriefTest is BountyEngineTestBase {
    function test_RefundRejectingCommitterCannotBlockReveal() public {
        RejectingCommitter rc = new RejectingCommitter(engine);
        bank.mint(41, Category.NOUN, "grief", address(rc));
        _fund(1 ether);

        vm.deal(address(this), 1 ether);
        rc.doCommit{value: BOND}();
        (, uint64 targetBlock, uint256 eventId) = engine.currentCommit();

        engine.setBlockhash(keccak256("grief"));
        vm.roll(uint256(targetBlock) + 1);
        vm.expectEmit(true, true, true, true);
        emit BountyEngine.BondRefundFailed(address(rc), BOND);
        vm.prank(bob);
        engine.reveal(); // must NOT revert

        // sentence generated; forfeited bond stays in the free treasury
        (, uint256 sharePerWord,,) = engine.eventInfo(eventId);
        assertGt(sharePerWord, 0);
        assertEq(address(rc).balance, 0);
        assertLe(engine.lockedFunds(), address(engine).balance);
    }

    function test_NoRewardWithoutSuccessfulReveal() public {
        // aborts pay no reveal reward — reward is never free money
        for (uint256 id = 1; id <= 5; ++id) {
            bank.unbind(id);
        }
        _fund(1 ether);
        _commit(alice);
        (, uint64 targetBlock,) = engine.currentCommit();
        engine.setBlockhash(keccak256("no-reward"));
        vm.roll(uint256(targetBlock) + 1);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        engine.reveal();
        assertEq(bob.balance, bobBefore);
    }

    function test_RewardPaidExactlyOncePerEvent() public {
        _fund(1 ether);
        _runCycle(keccak256("once"));
        // the commit is consumed: a second reveal has nothing to draw from
        vm.prank(bob);
        vm.expectRevert(BountyEngine.NoPendingCommit.selector);
        engine.reveal();
    }

    function test_RewardIsExactlyTwoPercentOfDrawnTier() public {
        _fund(1 ether);
        (uint256 eventId,) = _commit(alice);
        uint256 bobBefore = bob.balance;
        _reveal(keccak256("two-percent"));
        (uint256[] memory ids, uint256 sharePerWord,,) = engine.eventInfo(eventId);
        uint256 tier = _tierFromShare(sharePerWord, ids.length);
        assertEq(bob.balance - bobBefore, (tier * 200) / 10_000);
    }
}

// ═══════════════════════════════ treasury / admin / views ═══════════════════════════════

contract BountyEngineAdminTest is BountyEngineTestBase {
    function test_DepositEmitsAndRevertOnZero() public {
        vm.expectEmit(true, true, true, true);
        emit IBountyEngine.TreasuryDeposit(address(this), 1 ether);
        engine.deposit{value: 1 ether}();
        assertEq(engine.freeTreasury(), 1 ether);

        vm.expectRevert(BountyEngine.ZeroDeposit.selector);
        engine.deposit{value: 0}();
    }

    function test_ReceiveAcceptsPlainEth() public {
        vm.expectEmit(true, true, true, true);
        emit IBountyEngine.TreasuryDeposit(address(this), 0.5 ether);
        (bool ok,) = address(engine).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(engine.freeTreasury(), 0.5 ether);
    }

    function test_LaunchTiersAreNormative() public view {
        // the six normative values plus the 0.05 thin-treasury floor (owner, 2026-06-13)
        uint256[] memory menu = engine.tiers();
        assertEq(menu.length, 7);
        assertEq(menu[0], 0.05 ether);
        assertEq(menu[1], 0.1 ether);
        assertEq(menu[2], 0.2 ether);
        assertEq(menu[3], 0.25 ether);
        assertEq(menu[4], 0.3 ether);
        assertEq(menu[5], 0.4 ether);
        assertEq(menu[6], 0.5 ether);
    }

    function test_SetTiersValidation() public {
        vm.startPrank(admin);

        vm.expectRevert(BountyEngine.InvalidTiers.selector);
        engine.setTiers(new uint256[](0)); // empty

        uint256[] memory tooLow = new uint256[](1);
        tooLow[0] = 0.04 ether;
        vm.expectRevert(BountyEngine.InvalidTiers.selector);
        engine.setTiers(tooLow); // below the 0.05 hard floor

        uint256[] memory justBelow = new uint256[](1);
        justBelow[0] = 0.05 ether - 1;
        vm.expectRevert(BountyEngine.InvalidTiers.selector);
        engine.setTiers(justBelow); // one wei under the floor

        uint256[] memory tooHigh = new uint256[](1);
        tooHigh[0] = 0.5 ether + 1;
        vm.expectRevert(BountyEngine.InvalidTiers.selector);
        engine.setTiers(tooHigh); // above hard ceiling

        uint256[] memory unsorted = new uint256[](2);
        unsorted[0] = 0.2 ether;
        unsorted[1] = 0.2 ether;
        vm.expectRevert(BountyEngine.InvalidTiers.selector);
        engine.setTiers(unsorted); // not strictly ascending

        uint256[] memory good = new uint256[](2);
        good[0] = 0.05 ether; // exactly the floor is accepted
        good[1] = 0.5 ether; // exactly the ceiling is accepted
        engine.setTiers(good);
        assertEq(engine.tiers().length, 2);
        assertEq(engine.tiers()[0], 0.05 ether);
        assertEq(engine.tiers()[1], 0.5 ether);

        vm.stopPrank();
    }

    function test_AdminFunctionsRevertForNonOwner() public {
        Category[] memory slots = new Category[](1);
        slots[0] = Category.NOUN;
        string[] memory frags = new string[](2);

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        engine.addTemplate(slots, frags);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        engine.removeTemplate(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        engine.setTiers(new uint256[](1));
        vm.stopPrank();
    }

    function test_AddTemplateValidation() public {
        vm.startPrank(admin);

        vm.expectRevert(BountyEngine.InvalidTemplate.selector);
        engine.addTemplate(new Category[](0), new string[](1)); // zero slots

        vm.expectRevert(BountyEngine.InvalidTemplate.selector);
        engine.addTemplate(new Category[](8), new string[](9)); // over MAX_SLOTS

        vm.expectRevert(BountyEngine.InvalidTemplate.selector);
        engine.addTemplate(new Category[](2), new string[](2)); // fragments != slots + 1

        uint256 id = engine.addTemplate(new Category[](7), new string[](8)); // at the cap
        assertEq(id, 1);
        assertEq(engine.templateCount(), 2);

        vm.stopPrank();
    }

    function test_TemplateCapBoundary() public {
        // 04-1: the menu is hard-capped at MAX_TEMPLATES so reveal()'s full-menu scan can
        // never be grown into a gas DoS. setUp added template 0 → fill the remaining 31.
        uint256 cap = engine.MAX_TEMPLATES();
        Category[] memory slots = new Category[](1);
        slots[0] = Category.NOUN;
        string[] memory frags = new string[](2);

        vm.startPrank(admin);
        for (uint256 i = engine.templateCount(); i < cap; ++i) {
            engine.addTemplate(slots, frags);
        }
        assertEq(engine.templateCount(), cap);

        // at the cap: one more reverts
        vm.expectRevert(BountyEngine.TooManyTemplates.selector);
        engine.addTemplate(slots, frags);

        // free a slot and the add works again — the cap is a bound, not a latch
        engine.removeTemplate(0);
        uint256 id = engine.addTemplate(slots, frags);
        assertEq(id, cap - 1);
        assertEq(engine.templateCount(), cap);

        // and back at the cap it reverts again
        vm.expectRevert(BountyEngine.TooManyTemplates.selector);
        engine.addTemplate(slots, frags);
        vm.stopPrank();
    }

    function test_RemoveTemplateSwapAndPop() public {
        vm.startPrank(admin);
        Category[] memory slots = new Category[](1);
        slots[0] = Category.VERB;
        string[] memory frags = new string[](2);
        frags[0] = "It ";
        frags[1] = "!";
        engine.addTemplate(slots, frags); // id 1

        engine.removeTemplate(0); // last (id 1) moves into slot 0
        assertEq(engine.templateCount(), 1);
        (Category[] memory gotSlots, string[] memory gotFrags) = engine.getTemplate(0);
        assertEq(uint256(gotSlots[0]), uint256(Category.VERB));
        assertEq(gotFrags[0], "It ");

        vm.expectRevert(abi.encodeWithSelector(BountyEngine.UnknownTemplate.selector, 1));
        engine.removeTemplate(1);
        vm.stopPrank();
    }

    function test_GetTemplateRevert_Unknown() public {
        vm.expectRevert(abi.encodeWithSelector(BountyEngine.UnknownTemplate.selector, 7));
        engine.getTemplate(7);
    }
}

// ════════════════════════════════ lockedFunds invariant ═════════════════════════════════

/// @dev Guarded handler: drives full game lifecycles (deposit / commit+reveal / lapse /
///      claim / sweep / unbind / mint) with valid calls only — fail_on_revert stays
///      meaningful through the engine's own guards.
contract BountyHandler is Test {
    uint256 internal constant BOND = 0.01 ether;
    uint256 internal constant MIN_COST = 0.051 ether; // 0.05 floor tier + its 2% reward

    BountyEngineHarness public engine;
    MockWordBankRegistry public bank;
    address public committer = makeAddr("committer");

    uint256[] public revealedEvents;
    uint256[] internal mintedIds;
    uint256 internal nextMintId = 200;

    constructor(BountyEngineHarness engine_, MockWordBankRegistry bank_) {
        engine = engine_;
        bank = bank_;

        // anchor token so the committer is always a holder (never unbound: not tracked)
        bank.mint(100, Category.NOUN, "anchor", committer);
        for (uint256 i; i < 8; ++i) {
            _mintTracked(Category.NOUN);
        }
        for (uint256 i; i < 4; ++i) {
            _mintTracked(Category.VERB);
        }
        for (uint256 i; i < 4; ++i) {
            _mintTracked(Category.ADJ);
        }
        _mintTracked(Category.ADV);
    }

    receive() external payable {} // reveal rewards and claims land here

    function _mintTracked(Category category) internal {
        uint256 id = nextMintId++;
        bank.mint(id, category, "w", address(this));
        mintedIds.push(id);
    }

    // ─────────────────────────────────── actions ───────────────────────────────────────

    function deposit(uint96 raw) external {
        uint256 amount = bound(uint256(raw), 1 wei, 5 ether);
        vm.deal(address(this), amount);
        engine.deposit{value: amount}();
    }

    function commitReveal(bytes32 h) external {
        (address pending,,) = engine.currentCommit();
        if (pending != address(0)) return;
        uint256 nextCommitTime = engine.lastEventTimestamp() + engine.CYCLE_LENGTH();
        if (block.timestamp < nextCommitTime) vm.warp(nextCommitTime);
        if (engine.freeTreasury() < MIN_COST) return;

        uint256 eventId = engine.nextEventId();
        vm.deal(committer, BOND);
        vm.prank(committer);
        engine.commit{value: BOND}();

        engine.setBlockhash(h);
        vm.roll(block.number + 16);
        engine.reveal();

        (,, uint256 deadline,) = engine.eventInfo(eventId);
        if (deadline != 0) revealedEvents.push(eventId); // aborted reveals leave no record
    }

    function lapse() external {
        (address pending, uint64 targetBlock,) = engine.currentCommit();
        if (pending == address(0)) {
            uint256 nextCommitTime = engine.lastEventTimestamp() + engine.CYCLE_LENGTH();
            if (block.timestamp < nextCommitTime) vm.warp(nextCommitTime);
            if (engine.freeTreasury() < MIN_COST) return;
            vm.deal(committer, BOND);
            vm.prank(committer);
            engine.commit{value: BOND}();
            (, targetBlock,) = engine.currentCommit();
        }
        vm.roll(uint256(targetBlock) + 257);
        engine.expireCommit();
    }

    function claimOne(uint256 evSeed, uint256 tokenSeed) external {
        if (revealedEvents.length == 0) return;
        uint256 eventId = revealedEvents[bound(evSeed, 0, revealedEvents.length - 1)];
        (uint256[] memory ids,, uint256 deadline, bool swept) = engine.eventInfo(eventId);
        if (swept || block.timestamp > deadline) return;
        uint256 tokenId = ids[bound(tokenSeed, 0, ids.length - 1)];
        if (engine.claimed(eventId, tokenId)) return;
        if (!bank.isAlive(tokenId)) return; // burned word: share falls to the sweep
        address owner = bank.ownerOf(tokenId);
        vm.prank(owner);
        engine.claim(eventId, tokenId);
    }

    function sweepOne(uint256 evSeed) external {
        if (revealedEvents.length == 0) return;
        uint256 eventId = revealedEvents[bound(evSeed, 0, revealedEvents.length - 1)];
        (,, uint256 deadline, bool swept) = engine.eventInfo(eventId);
        if (swept) return;
        if (block.timestamp <= deadline) vm.warp(deadline + 1);
        engine.sweep(eventId);
    }

    function unbindOne(uint256 seed) external {
        if (mintedIds.length == 0) return;
        uint256 tokenId = mintedIds[bound(seed, 0, mintedIds.length - 1)];
        if (!bank.isAlive(tokenId)) return;
        bank.unbind(tokenId);
    }

    function mintOne(uint256 seed) external {
        _mintTracked(Category(bound(seed, 0, 3)));
    }

    // ──────────────────────────────── ghost accessors ──────────────────────────────────

    function revealedCount() external view returns (uint256) {
        return revealedEvents.length;
    }
}

contract BountyEngineInvariantTest is StdInvariant, Test {
    BountyEngineHarness internal engine;
    MockWordBankRegistry internal bank;
    BountyHandler internal handler;

    function setUp() public {
        address admin = makeAddr("admin");
        bank = new MockWordBankRegistry();
        engine = new BountyEngineHarness(address(bank), admin);

        vm.startPrank(admin);
        Category[] memory s1 = new Category[](3);
        s1[0] = Category.NOUN;
        s1[1] = Category.VERB;
        s1[2] = Category.NOUN;
        string[] memory f1 = new string[](4);
        engine.addTemplate(s1, f1);
        Category[] memory s2 = new Category[](1);
        s2[0] = Category.ADJ;
        string[] memory f2 = new string[](2);
        engine.addTemplate(s2, f2);
        vm.stopPrank();

        handler = new BountyHandler(engine, bank);
        targetContract(address(handler));
    }

    /// @notice System invariant 5: locked never exceeds the contract's balance.
    function invariant_LockedWithinBalance() public view {
        assertLe(engine.lockedFunds(), address(engine).balance);
    }

    /// @notice lockedFunds is exactly the sum of every revealed event's unclaimed remainder.
    function invariant_LockedEqualsSumOfRemainders() public view {
        uint256 sum;
        uint256 n = handler.revealedCount();
        for (uint256 i; i < n; ++i) {
            sum += engine.remainingLocked(handler.revealedEvents(i));
        }
        assertEq(engine.lockedFunds(), sum);
    }

    /// @notice The free treasury never underflows: balance always covers locked + a
    ///         pending bond.
    function invariant_FreeTreasuryComputable() public view {
        uint256 reserved = engine.lockedFunds();
        (address pending,,) = engine.currentCommit();
        if (pending != address(0)) reserved += 0.01 ether;
        assertLe(reserved, address(engine).balance);
    }
}
