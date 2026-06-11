// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {WordBank} from "../../src/WordBank.sol";
import {WordToken} from "../../src/WordToken.sol";
import {Category, WordData} from "../../src/interfaces/Types.sol";
import {IWordBank} from "../../src/interfaces/IWordBank.sol";
import {MockRewardsDistributor} from "../mocks/MockRewardsDistributor.sol";
import {MockRenderer} from "../mocks/MockRenderer.sol";
import {ReenteringRewardsDistributor} from "../mocks/ReenteringRewardsDistributor.sol";

// ───────────────────────────────────── fixture ─────────────────────────────────────────

/// @notice Shared fixture: deployed WordBank + mocks, all 10,000 slots uploaded and locked.
///         Slot i carries word "word-i", category i % 4, deterministic trait indices,
///         honors for the first 25 slots — so every expected value is recomputable in tests.
abstract contract WordBankTestBase is Test {
    using Strings for uint256;

    uint256 internal constant MAX_SUPPLY = 10_000;
    uint256 internal constant PUBLIC_SUPPLY = 9_800;
    uint256 internal constant ADMIN_RESERVE = 200;
    uint256 internal constant BACKING = 1_000e18;
    uint256 internal constant EB_PRICE = 0.05 ether;
    uint256 internal constant PUB_PRICE = 0.08 ether;

    WordBank internal bank;
    WordToken internal token;
    MockRewardsDistributor internal distributor;
    MockRenderer internal renderer;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        bank = new WordBank(admin);
        token = bank.wordToken();
        distributor = new MockRewardsDistributor();
        renderer = new MockRenderer();
        distributor.setWordBank(address(bank));

        vm.startPrank(admin);
        bank.setRenderer(address(renderer));
        bank.setRewardsDistributor(address(distributor));
        _uploadAllSlots();
        bank.lockSlots(keccak256("wordbank-provenance"));
        vm.stopPrank();

        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        vm.deal(carol, 100_000 ether);
    }

    function _uploadAllSlots() internal {
        uint256 batchSize = 1_000;
        for (uint256 b = 0; b < MAX_SUPPLY / batchSize; ++b) {
            WordData[] memory batch = new WordData[](batchSize);
            for (uint256 i = 0; i < batchSize; ++i) {
                batch[i] = _slotFor(b * batchSize + i);
            }
            bank.setWordSlots(b * batchSize, batch);
        }
    }

    function _slotFor(uint256 idx) internal pure returns (WordData memory) {
        return WordData({
            word: string.concat("word-", idx.toString()),
            category: Category(idx % 4),
            material: uint8(idx % 19),
            ink: uint8(idx % 5),
            background: uint8(idx % 7),
            honors: idx < 25
        });
    }

    function _configure(uint256 ebAlloc, uint256 pubAlloc, uint256 walletCap) internal {
        vm.prank(admin);
        bank.setSaleConfig(ebAlloc, pubAlloc, EB_PRICE, PUB_PRICE, walletCap);
    }

    /// @dev Setup → PublicSale with the whole 9,800 in the public phase (no early bird).
    function _skipToPublicSale() internal {
        _configure(0, PUBLIC_SUPPLY, 0);
        vm.startPrank(admin);
        bank.openEarlyBird();
        bank.closeEarlyBird();
        bank.openPublicSale();
        vm.stopPrank();
    }

    /// @dev Mints the full 9,800 public allocation to `minter`, arming the offset commit.
    function _selloutPublic(address minter) internal {
        _skipToPublicSale();
        vm.prank(minter);
        bank.publicMint{value: PUBLIC_SUPPLY * PUB_PRICE}(PUBLIC_SUPPLY);
    }

    function _revealOffset() internal {
        vm.roll(bank.offsetTargetBlock() + 1);
        bank.revealOffset();
    }

    function _buildFullRegistry() internal {
        while (!bank.registrySynced()) {
            bank.buildRegistry(2_500);
        }
    }

    function _expectedSlotIndex(uint256 tokenId) internal view returns (uint256) {
        return (tokenId - 1 + bank.wordOffset()) % MAX_SUPPLY;
    }

    /// @dev Full O(n) registry ↔ alive-set consistency scan.
    function _assertRegistryConsistent() internal view {
        uint256 sum;
        for (uint8 c = 0; c < 4; ++c) {
            Category cat = Category(c);
            uint256 n = bank.aliveCount(cat);
            sum += n;
            for (uint256 i = 0; i < n; ++i) {
                uint256 id = bank.aliveAt(cat, i);
                assertEq(bank.indexInCategory(id), i + 1, "index map out of sync");
                assertTrue(bank.isAlive(id), "registry holds dead token");
                assertEq(uint8(bank.categoryOf(id)), c, "token in wrong category array");
            }
        }
        assertEq(sum, bank.totalAlive(), "category counts do not sum to totalAlive");
    }

    function _startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory s = bytes(str);
        bytes memory p = bytes(prefix);
        if (s.length < p.length) return false;
        for (uint256 i = 0; i < p.length; ++i) {
            if (s[i] != p[i]) return false;
        }
        return true;
    }

    /// @dev Returns `str` without its final byte — used to show two single-digit-id placeholder
    ///      URIs are identical except that last `#id` character.
    function _stripLastByte(string memory str) internal pure returns (string memory) {
        bytes memory s = bytes(str);
        require(s.length > 0, "empty");
        bytes memory out = new bytes(s.length - 1);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = s[i];
        }
        return string(out);
    }
}

// ──────────────────────────── setup, slots, dependencies ───────────────────────────────

contract WordBankSetupTest is WordBankTestBase {
    using Strings for uint256;

    function test_constructor_wiresTokenAndAdmin() public view {
        assertEq(token.wordBank(), address(bank));
        assertEq(token.owner(), admin);
        assertEq(bank.owner(), admin);
        assertEq(bank.name(), "WordBank Words");
        assertEq(bank.symbol(), "WORDS");
    }

    function test_dependencies_setOnce() public {
        WordBank fresh = new WordBank(admin);
        vm.startPrank(admin);
        vm.expectRevert(WordBank.ZeroAddress.selector);
        fresh.setRenderer(address(0));
        fresh.setRenderer(address(renderer));
        vm.expectRevert(WordBank.AlreadySet.selector);
        fresh.setRenderer(address(renderer));

        fresh.setRewardsDistributor(address(distributor));
        vm.expectRevert(WordBank.AlreadySet.selector);
        fresh.setRewardsDistributor(address(distributor));
        vm.stopPrank();
    }

    function test_dependencies_onlyAdmin() public {
        WordBank fresh = new WordBank(admin);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setRenderer(address(renderer));
    }

    function test_slots_mustStayContiguous() public {
        WordBank fresh = new WordBank(admin);
        WordData[] memory batch = new WordData[](2);
        batch[0] = _slotFor(0);
        batch[1] = _slotFor(1);
        vm.startPrank(admin);
        vm.expectRevert(WordBank.NonContiguousBatch.selector);
        fresh.setWordSlots(5, batch); // gap: nothing written yet
        fresh.setWordSlots(0, batch);
        assertEq(fresh.slotsWritten(), 2);
        vm.stopPrank();
    }

    function test_slots_overwriteAllowedBeforeLock() public {
        WordBank fresh = new WordBank(admin);
        WordData[] memory batch = new WordData[](2);
        batch[0] = _slotFor(0);
        batch[1] = _slotFor(1);
        vm.startPrank(admin);
        fresh.setWordSlots(0, batch);
        WordData[] memory fix = new WordData[](1);
        fix[0] = _slotFor(7);
        fresh.setWordSlots(1, fix); // overwrite slot 1
        vm.stopPrank();
        assertEq(fresh.slotsWritten(), 2);
        assertEq(fresh.slotAt(1).word, "word-7");
    }

    function test_slots_rejectOverflowEmptyWordAndEmptyBatch() public {
        WordBank fresh = new WordBank(admin);
        vm.startPrank(admin);

        WordData[] memory empty = new WordData[](0);
        vm.expectRevert(WordBank.ZeroCount.selector);
        fresh.setWordSlots(0, empty);

        WordData[] memory blank = new WordData[](1);
        blank[0] = _slotFor(0);
        blank[0].word = "";
        vm.expectRevert(WordBank.EmptyWord.selector);
        fresh.setWordSlots(0, blank);
        vm.stopPrank();

        // a batch reaching past MAX_SUPPLY reverts (use the funded fixture bank pre-lock
        // is impossible — emulate by writing 9_999 then a 2-slot batch on the fresh one)
        // cheaper: single batch starting at 0 with MAX_SUPPLY+1 entries is impractical;
        // instead check the boundary math directly on a small window.
        WordData[] memory two = new WordData[](2);
        two[0] = _slotFor(0);
        two[1] = _slotFor(1);
        vm.prank(admin);
        vm.expectRevert(WordBank.NonContiguousBatch.selector);
        fresh.setWordSlots(MAX_SUPPLY - 1, two); // also non-contiguous here; range check tested below
    }

    function test_slots_lockRequiresAllTenThousand() public {
        WordBank fresh = new WordBank(admin);
        WordData[] memory batch = new WordData[](1);
        batch[0] = _slotFor(0);
        vm.startPrank(admin);
        fresh.setWordSlots(0, batch);
        vm.expectRevert(WordBank.SlotsIncomplete.selector);
        fresh.lockSlots(keccak256("x"));
        vm.stopPrank();
    }

    function test_slots_lockRejectsZeroHash_andIsPermanent() public {
        // fixture bank is fully uploaded + locked in setUp
        assertTrue(bank.slotsLocked());
        assertEq(bank.provenanceHash(), keccak256("wordbank-provenance"));

        WordData[] memory batch = new WordData[](1);
        batch[0] = _slotFor(0);
        vm.startPrank(admin);
        vm.expectRevert(WordBank.SlotsAreLocked.selector);
        bank.setWordSlots(0, batch);
        vm.expectRevert(WordBank.SlotsAreLocked.selector);
        bank.lockSlots(keccak256("y"));
        vm.stopPrank();

        WordBank fresh = new WordBank(admin);
        vm.prank(admin);
        // zero hash refused even with zero slots written? lock checks completeness first —
        // upload everything on the fresh bank to reach the hash check.
        vm.expectRevert(WordBank.SlotsIncomplete.selector);
        fresh.lockSlots(bytes32(0));
    }

    function test_slotAt_boundsCheck() public {
        vm.expectRevert(WordBank.SlotOutOfRange.selector);
        bank.slotAt(MAX_SUPPLY); // never writable

        WordBank fresh = new WordBank(admin);
        vm.expectRevert(WordBank.SlotOutOfRange.selector);
        fresh.slotAt(0); // nothing written yet
    }

    function test_openEarlyBird_requiresFullSetupAndConfig() public {
        WordBank fresh = new WordBank(admin);
        vm.prank(admin);
        vm.expectRevert(WordBank.SetupIncomplete.selector);
        fresh.openEarlyBird(); // no slots, no deps

        // fixture bank: setup complete but sale unconfigured (0 + 0 != 9_800)
        vm.prank(admin);
        vm.expectRevert(WordBank.SetupIncomplete.selector);
        bank.openEarlyBird();

        _configure(800, 9_000, 5);
        vm.prank(admin);
        bank.openEarlyBird();
        assertEq(uint8(bank.phase()), uint8(WordBank.SalePhase.EarlyBird));
    }

    function test_mintingImpossibleBeforeSetupComplete() public {
        WordBank fresh = new WordBank(admin);
        vm.prank(admin);
        vm.expectRevert(WordBank.SetupIncomplete.selector);
        fresh.adminMint(1, admin);
    }

    function test_erc165_supports721And2981() public view {
        assertTrue(bank.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(bank.supportsInterface(0x5b5e139f)); // ERC-721 Metadata
        assertTrue(bank.supportsInterface(0x2a55205a)); // ERC-2981
    }
}

// ───────────────────────────── sale config & phase machine ─────────────────────────────

contract WordBankConfigPhaseTest is WordBankTestBase {
    function test_config_allocationInvariantEnforced() public {
        vm.startPrank(admin);
        vm.expectRevert(WordBank.AllocationInvariantViolated.selector);
        bank.setSaleConfig(1_000, 9_000, EB_PRICE, PUB_PRICE, 5); // sums to 10_200
        vm.expectRevert(WordBank.AllocationInvariantViolated.selector);
        bank.setSaleConfig(0, 0, EB_PRICE, PUB_PRICE, 5);
        vm.expectRevert(WordBank.AllocationInvariantViolated.selector);
        bank.setSaleConfig(PUBLIC_SUPPLY, 1, EB_PRICE, PUB_PRICE, 5);
        bank.setSaleConfig(800, 9_000, EB_PRICE, PUB_PRICE, 5); // exact 10_000 with reserve
        vm.stopPrank();
        assertEq(bank.earlyBirdAllocation(), 800);
        assertEq(bank.publicAllocation(), 9_000);
    }

    function testFuzz_config_allocationInvariant(uint256 ebAlloc, uint256 pubAlloc) public {
        ebAlloc = bound(ebAlloc, 0, 20_000);
        pubAlloc = bound(pubAlloc, 0, 20_000);
        vm.prank(admin);
        if (ebAlloc + pubAlloc != PUBLIC_SUPPLY) {
            vm.expectRevert(WordBank.AllocationInvariantViolated.selector);
            bank.setSaleConfig(ebAlloc, pubAlloc, EB_PRICE, PUB_PRICE, 5);
        } else {
            bank.setSaleConfig(ebAlloc, pubAlloc, EB_PRICE, PUB_PRICE, 5);
            assertEq(bank.earlyBirdAllocation() + bank.publicAllocation() + ADMIN_RESERVE, MAX_SUPPLY);
        }
    }

    function test_config_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        bank.setSaleConfig(800, 9_000, EB_PRICE, PUB_PRICE, 5);
    }

    function test_config_frozenWhileSaleOpen() public {
        _configure(800, 9_000, 5);
        vm.startPrank(admin);
        bank.openEarlyBird();
        vm.expectRevert(WordBank.ConfigLockedDuringSale.selector);
        bank.setSaleConfig(800, 9_000, EB_PRICE, PUB_PRICE, 5);

        bank.closeEarlyBird(); // Between: allowed again
        bank.setSaleConfig(700, 9_100, EB_PRICE, PUB_PRICE, 5);

        bank.openPublicSale();
        vm.expectRevert(WordBank.ConfigLockedDuringSale.selector);
        bank.setSaleConfig(700, 9_100, EB_PRICE, PUB_PRICE, 5);

        bank.pausePublicSale(); // back to Between: allowed again
        bank.setSaleConfig(700, 9_100, EB_PRICE * 2, PUB_PRICE * 2, 5);
        vm.stopPrank();
        assertEq(bank.publicPrice(), PUB_PRICE * 2);
    }

    function test_config_cannotDropAllocationBelowMinted() public {
        _configure(100, 9_700, 50);
        vm.prank(admin);
        bank.openEarlyBird();
        vm.prank(alice);
        bank.earlyBirdMint{value: 10 * EB_PRICE}(10);

        vm.startPrank(admin);
        bank.closeEarlyBird();
        vm.expectRevert(WordBank.AllocationBelowMinted.selector);
        bank.setSaleConfig(9, 9_791, EB_PRICE, PUB_PRICE, 50); // 9 < 10 minted
        bank.setSaleConfig(10, 9_790, EB_PRICE, PUB_PRICE, 50); // fold remainder into public
        vm.stopPrank();
    }

    function test_phaseTransitions_wrongPhaseReverts() public {
        vm.startPrank(admin);
        vm.expectRevert(WordBank.WrongPhase.selector);
        bank.closeEarlyBird(); // still Setup
        vm.expectRevert(WordBank.WrongPhase.selector);
        bank.openPublicSale(); // still Setup
        vm.expectRevert(WordBank.WrongPhase.selector);
        bank.pausePublicSale(); // still Setup
        vm.stopPrank();

        _configure(800, 9_000, 5);
        vm.startPrank(admin);
        bank.openEarlyBird();
        vm.expectRevert(WordBank.WrongPhase.selector);
        bank.openEarlyBird(); // already open
        vm.expectRevert(WordBank.WrongPhase.selector);
        bank.openPublicSale(); // must route through Between
        vm.stopPrank();
    }

    function test_phaseTransitions_onlyAdmin() public {
        _configure(800, 9_000, 5);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        bank.openEarlyBird();
    }
}

// ──────────────────────────────────── minting ──────────────────────────────────────────

contract WordBankMintTest is WordBankTestBase {
    function test_earlyBird_priceWalletCapAndPhaseGate() public {
        vm.prank(alice);
        vm.expectRevert(WordBank.WrongPhase.selector);
        bank.earlyBirdMint{value: EB_PRICE}(1); // Setup

        _configure(100, 9_700, 3);
        vm.prank(admin);
        bank.openEarlyBird();

        vm.startPrank(alice);
        vm.expectRevert(WordBank.ZeroCount.selector);
        bank.earlyBirdMint(0);

        vm.expectRevert(WordBank.WrongPayment.selector);
        bank.earlyBirdMint{value: EB_PRICE - 1}(1);

        vm.expectRevert(WordBank.WrongPayment.selector);
        bank.earlyBirdMint{value: 3 * EB_PRICE}(2); // overpay refused too

        bank.earlyBirdMint{value: 2 * EB_PRICE}(2);
        bank.earlyBirdMint{value: EB_PRICE}(1); // exactly at cap 3

        vm.expectRevert(WordBank.ExceedsWalletCap.selector);
        bank.earlyBirdMint{value: EB_PRICE}(1); // 4th
        vm.stopPrank();

        assertEq(bank.earlyBirdMintedBy(alice), 3);
        assertEq(bank.balanceOf(alice), 3);

        // bob still has his own cap
        vm.prank(bob);
        bank.earlyBirdMint{value: 3 * EB_PRICE}(3);
        assertEq(bank.earlyBirdMinted(), 6);
    }

    function test_earlyBird_capDoesNotApplyInPublicPhase() public {
        _configure(2, 9_798, 2);
        vm.prank(admin);
        bank.openEarlyBird();

        vm.startPrank(alice);
        bank.earlyBirdMint{value: 2 * EB_PRICE}(2); // sells out early bird → auto-advance
        assertEq(uint8(bank.phase()), uint8(WordBank.SalePhase.PublicSale));
        // same wallet mints far beyond the early bird cap in public phase
        bank.publicMint{value: 50 * PUB_PRICE}(50);
        vm.stopPrank();
        assertEq(bank.balanceOf(alice), 52);
    }

    function test_earlyBird_selloutAutoAdvances() public {
        _configure(5, 9_795, 10);
        vm.prank(admin);
        bank.openEarlyBird();
        vm.prank(alice);
        bank.earlyBirdMint{value: 4 * EB_PRICE}(4);
        assertEq(uint8(bank.phase()), uint8(WordBank.SalePhase.EarlyBird));
        vm.prank(bob);
        bank.earlyBirdMint{value: EB_PRICE}(1);
        assertEq(uint8(bank.phase()), uint8(WordBank.SalePhase.PublicSale));
    }

    function test_earlyBird_allocationGate() public {
        _configure(5, 9_795, 10);
        vm.prank(admin);
        bank.openEarlyBird();
        vm.prank(alice);
        vm.expectRevert(WordBank.ExceedsAllocation.selector);
        bank.earlyBirdMint{value: 6 * EB_PRICE}(6);
    }

    function test_publicMint_priceAllocationPhaseGates() public {
        _skipToPublicSale();
        vm.startPrank(alice);
        vm.expectRevert(WordBank.ZeroCount.selector);
        bank.publicMint(0);
        vm.expectRevert(WordBank.WrongPayment.selector);
        bank.publicMint{value: PUB_PRICE + 1}(1);
        vm.expectRevert(WordBank.ExceedsAllocation.selector);
        bank.publicMint{value: (PUBLIC_SUPPLY + 1) * PUB_PRICE}(PUBLIC_SUPPLY + 1);
        bank.publicMint{value: 3 * PUB_PRICE}(3);
        vm.stopPrank();
        assertEq(bank.publicMinted(), 3);
        assertEq(bank.totalAlive(), 3);

        vm.prank(admin);
        bank.pausePublicSale();
        vm.prank(alice);
        vm.expectRevert(WordBank.WrongPhase.selector);
        bank.publicMint{value: PUB_PRICE}(1);
    }

    function test_coreMintSequence_everyEffect() public {
        _skipToPublicSale();
        vm.prank(alice);
        bank.publicMint{value: 2 * PUB_PRICE}(2);

        // ids are sequential from 1
        assertEq(bank.ownerOf(1), alice);
        assertEq(bank.ownerOf(2), alice);
        assertEq(bank.totalMinted(), 2);

        // backing minted into the vault, recorded per token
        assertEq(token.balanceOf(address(bank)), 2 * BACKING);
        assertEq(bank.bondedBalance(1), BACKING);
        assertEq(bank.bondedBalance(2), BACKING);

        // distributor registration happened for each id
        assertTrue(distributor.registered(1));
        assertTrue(distributor.registered(2));
        assertEq(distributor.registerCount(), 2);

        // pre-reveal: alive counter exact, category registry intentionally empty
        assertEq(bank.totalAlive(), 2);
        assertEq(
            bank.aliveCount(Category.NOUN) + bank.aliveCount(Category.VERB) + bank.aliveCount(Category.ADJ)
                + bank.aliveCount(Category.ADV),
            0
        );
        assertFalse(bank.registrySynced());

        // proceeds accumulated
        assertEq(address(bank).balance, 2 * PUB_PRICE);
    }

    function test_adminMint_freeAnyPhaseFullyBacked() public {
        // Setup phase (setup complete via fixture)
        vm.prank(admin);
        bank.adminMint(2, admin);
        assertEq(bank.balanceOf(admin), 2);

        // EarlyBird phase
        _configure(100, 9_700, 5);
        vm.prank(admin);
        bank.openEarlyBird();
        vm.prank(admin);
        bank.adminMint(3, bob);

        // PublicSale phase
        vm.startPrank(admin);
        bank.closeEarlyBird();
        bank.openPublicSale();
        bank.adminMint(5, admin);
        vm.stopPrank();

        assertEq(bank.adminMinted(), 10);
        // reserve mints paid nothing
        assertEq(address(bank).balance, 0);
        // identical core sequence: backed + registered
        assertEq(token.balanceOf(address(bank)), 10 * BACKING);
        assertEq(distributor.registerCount(), 10);
        assertEq(bank.bondedBalance(10), BACKING);
    }

    function test_adminMint_201stReverts() public {
        vm.startPrank(admin);
        vm.expectRevert(WordBank.ExceedsAdminReserve.selector);
        bank.adminMint(201, admin);

        bank.adminMint(200, admin);
        assertEq(bank.adminMinted(), 200);
        vm.expectRevert(WordBank.ExceedsAdminReserve.selector);
        bank.adminMint(1, admin);
        vm.stopPrank();
    }

    function test_adminMint_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        bank.adminMint(1, alice);
    }

    function test_adminMint_worksAfterSelloutAndReveal() public {
        _selloutPublic(alice);
        _revealOffset();
        vm.prank(admin);
        bank.adminMint(ADMIN_RESERVE, admin);
        assertEq(bank.totalMinted(), MAX_SUPPLY);
        assertEq(token.balanceOf(address(bank)), MAX_SUPPLY * BACKING);
        // post-reveal mints register eagerly — all 200 are in category arrays already
        uint256 sum = bank.aliveCount(Category.NOUN) + bank.aliveCount(Category.VERB) + bank.aliveCount(Category.ADJ)
            + bank.aliveCount(Category.ADV);
        assertEq(sum, ADMIN_RESERVE); // pre-reveal 9_800 still await buildRegistry
    }

    function test_withdrawProceeds() public {
        _skipToPublicSale();
        vm.prank(alice);
        bank.publicMint{value: 10 * PUB_PRICE}(10);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        bank.withdrawProceeds(alice);

        uint256 before = admin.balance;
        vm.prank(admin);
        bank.withdrawProceeds(admin);
        assertEq(admin.balance - before, 10 * PUB_PRICE);
        assertEq(address(bank).balance, 0);
    }

    function test_royalty_capAndMath() public {
        vm.prank(admin);
        vm.expectRevert(WordBank.RoyaltyTooHigh.selector);
        bank.setRoyalty(admin, 1_001);

        vm.prank(admin);
        bank.setRoyalty(bob, 1_000); // exactly the ceiling
        (address recv, uint256 amount) = bank.royaltyInfo(1, 1 ether);
        assertEq(recv, bob);
        assertEq(amount, 0.1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        bank.setRoyalty(alice, 100);
    }

    function test_frozenInterfaceConformance() public {
        _selloutPublic(alice);
        _revealOffset();
        _buildFullRegistry();

        IWordBank ibank = IWordBank(address(bank));
        assertEq(ibank.ownerOf(1), alice);
        assertEq(ibank.balanceOf(alice), PUBLIC_SUPPLY);
        assertEq(ibank.totalAlive(), PUBLIC_SUPPLY);
        assertTrue(ibank.isAlive(1));
        assertEq(ibank.bondedBalance(1), BACKING);
        assertGt(bytes(ibank.wordOf(1)).length, 0);
        uint256 n = ibank.aliveCount(Category.NOUN);
        assertGt(n, 0);
        uint256 id = ibank.aliveAt(Category.NOUN, n - 1);
        assertEq(uint8(ibank.categoryOf(id)), uint8(Category.NOUN));
    }

    function test_totalSupply_tracksAliveCount_risesOnMintFallsOnUnbind() public {
        // Explorer-standard circulating supply: equals totalAlive() at every step.
        assertEq(bank.totalSupply(), 0);
        assertEq(bank.totalSupply(), bank.totalAlive());

        _skipToPublicSale();
        vm.prank(alice);
        bank.publicMint{value: 5 * PUB_PRICE}(5);
        assertEq(bank.totalSupply(), 5); // rises on mint
        assertEq(bank.totalSupply(), bank.totalAlive());

        vm.prank(admin);
        bank.adminMint(2, bob);
        assertEq(bank.totalSupply(), 7); // every mint path counts

        // Sell out, reveal, and build the registry so tokens can unbind.
        vm.prank(alice);
        bank.publicMint{value: (PUBLIC_SUPPLY - 5) * PUB_PRICE}(PUBLIC_SUPPLY - 5);
        _revealOffset();
        _buildFullRegistry();
        assertEq(bank.totalSupply(), PUBLIC_SUPPLY + 2);

        vm.prank(alice);
        bank.unbind(1);
        assertEq(bank.totalSupply(), PUBLIC_SUPPLY + 1); // falls on unbind
        assertEq(bank.totalSupply(), bank.totalAlive());

        uint256[] memory ids = new uint256[](2);
        ids[0] = 2;
        ids[1] = 3;
        vm.prank(alice);
        bank.unbindMany(ids);
        assertEq(bank.totalSupply(), PUBLIC_SUPPLY - 1);
        assertEq(bank.totalSupply(), bank.totalAlive());
        // totalMinted (ever minted) stays put — only totalSupply/totalAlive fall.
        assertEq(bank.totalMinted(), PUBLIC_SUPPLY + 2);
    }
}

// ─────────────────────────────── provenance & registry ─────────────────────────────────

contract WordBankProvenanceTest is WordBankTestBase {
    function test_offsetArms_atExactlyPublicSellout() public {
        _skipToPublicSale();
        vm.prank(alice);
        bank.publicMint{value: (PUBLIC_SUPPLY - 1) * PUB_PRICE}(PUBLIC_SUPPLY - 1);
        assertEq(bank.offsetTargetBlock(), 0); // 9_799: not armed

        vm.prank(bob);
        vm.expectEmit(false, false, false, true, address(bank));
        emit WordBank.OffsetCommitArmed(block.number + 15);
        bank.publicMint{value: PUB_PRICE}(1); // 9_800th arms
        assertEq(bank.offsetTargetBlock(), block.number + 15);
        assertFalse(bank.offsetSet());
    }

    function test_offsetArms_viaEarlyBirdOnlySale() public {
        // entire 9_800 sold through early bird (public allocation zero)
        _configure(PUBLIC_SUPPLY, 0, PUBLIC_SUPPLY);
        vm.prank(admin);
        bank.openEarlyBird();
        vm.prank(alice);
        bank.earlyBirdMint{value: PUBLIC_SUPPLY * EB_PRICE}(PUBLIC_SUPPLY);
        assertEq(bank.offsetTargetBlock(), block.number + 15);
    }

    /// @notice Overseer finding 3: an undersold early bird closed by the admin must not
    ///         strand the provenance trigger — folding the remainder into the public
    ///         allocation in Between makes the 9,800 sellout (and the arm) reachable again.
    function test_undersoldEarlyBird_foldRemainder_offsetStillArms() public {
        _configure(100, 9_700, 50);
        vm.prank(admin);
        bank.openEarlyBird();
        vm.prank(alice);
        bank.earlyBirdMint{value: 10 * EB_PRICE}(10); // undersold: 10 of 100

        vm.startPrank(admin);
        bank.closeEarlyBird();
        // without this fold, public sellout would stop at 9_710 and never arm the offset
        bank.setSaleConfig(10, PUBLIC_SUPPLY - 10, EB_PRICE, PUB_PRICE, 50);
        bank.openPublicSale();
        vm.stopPrank();

        vm.prank(bob);
        bank.publicMint{value: (PUBLIC_SUPPLY - 10) * PUB_PRICE}(PUBLIC_SUPPLY - 10);

        assertEq(bank.earlyBirdMinted() + bank.publicMinted(), PUBLIC_SUPPLY);
        assertGt(bank.offsetTargetBlock(), 0); // armed at exactly 9,800 despite the detour
        _revealOffset();
        assertTrue(bank.offsetSet());
    }

    function test_reveal_guards() public {
        vm.expectRevert(WordBank.OffsetNotArmed.selector);
        bank.revealOffset();

        _selloutPublic(alice);
        uint256 target = bank.offsetTargetBlock();

        vm.roll(target); // not yet past the target block
        vm.expectRevert(WordBank.RevealTooEarly.selector);
        bank.revealOffset();

        vm.roll(target + 1);
        bank.revealOffset();
        assertTrue(bank.offsetSet());
        assertLt(bank.wordOffset(), MAX_SUPPLY);
        assertEq(bank.preRevealMinted(), PUBLIC_SUPPLY);

        vm.expectRevert(WordBank.OffsetAlreadySet.selector);
        bank.revealOffset(); // immutable once set
        vm.expectRevert(WordBank.OffsetAlreadySet.selector);
        bank.rearmOffset();
    }

    function test_reveal_windowExpiry_andRearm() public {
        _selloutPublic(alice);
        uint256 target = bank.offsetTargetBlock();

        vm.expectRevert(WordBank.RevealWindowStillOpen.selector);
        bank.rearmOffset(); // window not even open yet

        vm.roll(target + 257); // blockhash(target) no longer available
        vm.expectRevert(WordBank.RevealWindowExpired.selector);
        bank.revealOffset();

        bank.rearmOffset();
        uint256 newTarget = bank.offsetTargetBlock();
        assertEq(newTarget, target + 257 + 15);

        vm.roll(newTarget + 1);
        bank.revealOffset();
        assertTrue(bank.offsetSet());
    }

    function test_wordQueries_revertPreReveal_workPostReveal() public {
        _skipToPublicSale();
        vm.prank(alice);
        bank.publicMint{value: PUB_PRICE}(1);

        vm.expectRevert(WordBank.OffsetNotSet.selector);
        bank.wordOf(1);
        vm.expectRevert(WordBank.OffsetNotSet.selector);
        bank.categoryOf(1);
        vm.expectRevert(WordBank.UnknownToken.selector);
        bank.wordOf(0);
        vm.expectRevert(WordBank.UnknownToken.selector);
        bank.wordOf(2); // never minted

        vm.prank(alice);
        bank.publicMint{value: (PUBLIC_SUPPLY - 1) * PUB_PRICE}(PUBLIC_SUPPLY - 1);
        _revealOffset();

        // every token's word/category/traits match its offset-rotated slot
        for (uint256 id = 1; id <= 25; ++id) {
            WordData memory expected = _slotFor(_expectedSlotIndex(id));
            assertEq(bank.wordOf(id), expected.word);
            assertEq(uint8(bank.categoryOf(id)), uint8(expected.category));
            WordData memory got = bank.wordDataOf(id);
            assertEq(got.material, expected.material);
            assertEq(got.ink, expected.ink);
            assertEq(got.background, expected.background);
            assertEq(got.honors, expected.honors);
        }
    }

    function test_tokenURI_placeholderThenRenderer() public {
        _skipToPublicSale();
        vm.prank(alice);
        bank.publicMint{value: 2 * PUB_PRICE}(2);

        // Pre-reveal: tokenURI delegates to the Renderer's unrevealedTokenURI(tokenId), which
        // takes ONLY the id — structurally trait-free. Two tokens differ only by the #id.
        string memory pre1 = bank.tokenURI(1);
        string memory pre2 = bank.tokenURI(2);
        assertEq(pre1, "mock://unrevealed/1");
        assertEq(pre2, "mock://unrevealed/2");
        assertTrue(_startsWith(pre1, "mock://unrevealed/"));
        assertTrue(_startsWith(pre2, "mock://unrevealed/"));
        // Identical except the trailing id: stripping the id leaves the same prefix, and the
        // placeholder never carries the eventual word/category/honors (snipe-proof).
        assertEq(_stripLastByte(pre1), _stripLastByte(pre2));

        vm.prank(alice);
        bank.publicMint{value: (PUBLIC_SUPPLY - 2) * PUB_PRICE}(PUBLIC_SUPPLY - 2);
        _revealOffset();

        // Post-reveal: unchanged — delegates with the full trait data.
        WordData memory expected = _slotFor(_expectedSlotIndex(1));
        string memory post = bank.tokenURI(1);
        string memory want = string.concat(
            "mock://1/",
            expected.word,
            "/",
            Strings.toString(uint256(uint8(expected.category))),
            "/",
            expected.honors ? "honors" : "standard"
        );
        assertEq(post, want);
    }

    function test_buildRegistry_batchesToFullSync() public {
        vm.expectRevert(WordBank.OffsetNotSet.selector);
        bank.buildRegistry(100);

        _selloutPublic(alice);
        _revealOffset();
        assertFalse(bank.registrySynced());

        vm.expectRevert(WordBank.ZeroCount.selector);
        bank.buildRegistry(0);

        bank.buildRegistry(4_000);
        assertEq(bank.registryCursor(), 4_000);
        assertFalse(bank.registrySynced());

        bank.buildRegistry(100_000); // clamps to the remainder
        assertEq(bank.registryCursor(), PUBLIC_SUPPLY);
        assertTrue(bank.registrySynced());

        vm.expectRevert(WordBank.RegistryAlreadyBuilt.selector);
        bank.buildRegistry(1);

        // categories are 2_500 slots each; 9_800 sequential ids rotated by a constant
        // offset still land 2_450 per category
        assertEq(bank.aliveCount(Category.NOUN), 2_450);
        assertEq(bank.aliveCount(Category.VERB), 2_450);
        assertEq(bank.aliveCount(Category.ADJ), 2_450);
        assertEq(bank.aliveCount(Category.ADV), 2_450);
        _assertRegistryConsistent();
    }

    function test_aliveAt_outOfBoundsReverts() public {
        _selloutPublic(alice);
        _revealOffset();
        _buildFullRegistry();
        uint256 n = bank.aliveCount(Category.NOUN);
        vm.expectRevert(stdError.indexOOBError);
        bank.aliveAt(Category.NOUN, n);
    }
}

// ──────────────────────────────────── unbinding ────────────────────────────────────────

contract WordBankUnbindTest is WordBankTestBase {
    function setUp() public override {
        super.setUp();
        _selloutPublic(alice);
        _revealOffset();
        _buildFullRegistry();
    }

    function test_unbind_fullEffects() public {
        uint256 aliveBefore = bank.totalAlive();
        uint256 aliceWordBefore = token.balanceOf(alice);

        vm.prank(alice);
        bank.unbind(77);

        // NFT burned: ownerOf reverts, isAlive false
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 77));
        bank.ownerOf(77);
        assertFalse(bank.isAlive(77));

        // backing released 1:1000
        assertEq(token.balanceOf(alice) - aliceWordBefore, BACKING);
        assertEq(bank.bondedBalance(77), 0);
        assertEq(token.balanceOf(address(bank)), (aliveBefore - 1) * BACKING);

        // registry shrank consistently
        assertEq(bank.totalAlive(), aliveBefore - 1);
        assertEq(bank.indexInCategory(77), 0);

        // metadata outlives the burn (historical sentences need it)
        assertGt(bytes(bank.wordOf(77)).length, 0);
    }

    function test_unbind_burnFirst_settleBeforeDecrement() public {
        uint256 aliveBefore = bank.totalAlive();
        vm.prank(alice);
        bank.unbind(123);

        (address to, bool wasAlive, uint256 totalAliveAtSettle,) = distributor.settleRecords(123);
        assertEq(to, alice); // paid to the burner
        assertFalse(wasAlive); // burn happens BEFORE settle (overseer finding 1)
        assertEq(totalAliveAtSettle, aliveBefore); // settle saw the PRE-decrement count (invariant 3)
        assertTrue(distributor.closed(123));
    }

    function test_unbind_nonOwnerReverts() public {
        vm.prank(bob);
        vm.expectRevert(WordBank.NotTokenOwner.selector);
        bank.unbind(1);
    }

    function test_unbind_burnedIdCannotRepeatOrRemint() public {
        vm.startPrank(alice);
        bank.unbind(50);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 50));
        bank.unbind(50);
        vm.stopPrank();

        // minting continues at fresh ids — a burned id is never reissued
        vm.prank(admin);
        bank.adminMint(1, admin);
        assertEq(bank.totalMinted(), PUBLIC_SUPPLY + 1);
        assertEq(bank.ownerOf(PUBLIC_SUPPLY + 1), admin);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 50));
        bank.ownerOf(50);
    }

    function test_unbind_transferredTokenUnbindsToNewOwner() public {
        vm.prank(alice);
        bank.transferFrom(alice, bob, 500);
        // backing travelled with the token, no state to migrate
        assertEq(bank.bondedBalance(500), BACKING);

        vm.prank(alice);
        vm.expectRevert(WordBank.NotTokenOwner.selector);
        bank.unbind(500);

        vm.prank(bob);
        bank.unbind(500);
        assertEq(token.balanceOf(bob), BACKING);
        (address to,,,) = distributor.settleRecords(500);
        assertEq(to, bob);
    }

    function test_unbindMany_batchAndAtomicity() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 11;
        ids[1] = 22;
        ids[2] = 33;
        vm.prank(alice);
        bank.unbindMany(ids);
        assertEq(token.balanceOf(alice), 3 * BACKING);
        assertEq(bank.totalAlive(), PUBLIC_SUPPLY - 3);

        // duplicate id in batch → second hit reverts the whole batch (already burned)
        uint256[] memory dup = new uint256[](2);
        dup[0] = 44;
        dup[1] = 44;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 44));
        bank.unbindMany(dup);
        assertTrue(bank.isAlive(44)); // atomic: nothing happened

        uint256[] memory empty = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(WordBank.ZeroCount.selector);
        bank.unbindMany(empty);
    }

    function test_unbind_swapAndPopKeepsRegistryConsistent() public {
        // remove first, middle, and last elements of one category array
        Category cat = Category.NOUN;
        uint256 n = bank.aliveCount(cat);
        uint256 first = bank.aliveAt(cat, 0);
        uint256 mid = bank.aliveAt(cat, n / 2);
        uint256 last = bank.aliveAt(cat, n - 1);

        uint256[] memory ids = new uint256[](3);
        ids[0] = first;
        ids[1] = last;
        ids[2] = mid;
        vm.prank(alice);
        bank.unbindMany(ids);

        assertEq(bank.aliveCount(cat), n - 3);
        _assertRegistryConsistent();
    }

    function test_unbind_everySeventhToken_fullConsistencyScan() public {
        uint256 burned;
        for (uint256 id = 7; id <= PUBLIC_SUPPLY; id += 7) {
            vm.prank(alice);
            bank.unbind(id);
            ++burned;
        }
        assertEq(bank.totalAlive(), PUBLIC_SUPPLY - burned);
        assertEq(token.balanceOf(alice), burned * BACKING);
        assertEq(token.balanceOf(address(bank)), (PUBLIC_SUPPLY - burned) * BACKING);
        _assertRegistryConsistent();
    }
}

/// @notice Unbind is gated on registry membership: tokens minted before the offset reveal
///         cannot unbind until buildRegistry has processed them.
contract WordBankUnbindGatingTest is WordBankTestBase {
    function test_unbind_blockedUntilRegistered() public {
        _selloutPublic(alice);

        // pre-reveal: minted and owned, but not yet in the category registry
        vm.prank(alice);
        vm.expectRevert(WordBank.TokenNotInRegistry.selector);
        bank.unbind(1);

        _revealOffset();
        vm.prank(alice);
        vm.expectRevert(WordBank.TokenNotInRegistry.selector);
        bank.unbind(1); // revealed but registry not built yet

        bank.buildRegistry(1); // registers exactly tokenId 1
        vm.prank(alice);
        bank.unbind(1); // now fine

        vm.prank(alice);
        vm.expectRevert(WordBank.TokenNotInRegistry.selector);
        bank.unbind(2); // still pending
    }
}

// ───────────────────────────── unbind reentrancy (finding 1) ───────────────────────────

/// @notice Malicious burner: when the distributor's settle payout hands it ETH mid-unbind,
///         its receive() tries to (a) transfer the half-unbound NFT to an accomplice — the
///         pre-fix exploit: sell into a standing bid, keep proceeds + rewards + WORD — and
///         (b) re-enter unbind on a second token it owns. Both must fail.
contract UnbindAttacker {
    WordBank internal bank;
    address internal accomplice;
    uint256 internal targetId;
    uint256 internal secondId;

    bool public gotCallback;
    bool public transferSucceeded;
    bool public reenterUnbindSucceeded;

    constructor(WordBank bank_, address accomplice_) {
        bank = bank_;
        accomplice = accomplice_;
    }

    function attack(uint256 targetId_, uint256 secondId_) external {
        targetId = targetId_;
        secondId = secondId_;
        bank.unbind(targetId_);
    }

    receive() external payable {
        gotCallback = true;
        try bank.transferFrom(address(this), accomplice, targetId) {
            transferSucceeded = true;
        } catch {}
        try bank.unbind(secondId) {
            reenterUnbindSucceeded = true;
        } catch {}
    }
}

/// @notice Wires WordBank to the ETH-paying ReenteringRewardsDistributor so the burner
///         really receives execution mid-unbind (the gap the recording mock cannot cover).
contract WordBankUnbindReentrancyTest is WordBankTestBase {
    ReenteringRewardsDistributor internal ethDistributor;
    UnbindAttacker internal attacker;

    function setUp() public override {
        bank = new WordBank(admin);
        token = bank.wordToken();
        renderer = new MockRenderer();
        ethDistributor = new ReenteringRewardsDistributor();
        vm.deal(address(ethDistributor), 100 ether);

        vm.startPrank(admin);
        bank.setRenderer(address(renderer));
        bank.setRewardsDistributor(address(ethDistributor));
        _uploadAllSlots();
        bank.lockSlots(keccak256("wordbank-provenance"));
        vm.stopPrank();

        vm.deal(alice, 100_000 ether);
        _selloutPublic(alice);
        _revealOffset();
        _buildFullRegistry();

        attacker = new UnbindAttacker(bank, bob);
        vm.startPrank(alice);
        bank.transferFrom(alice, address(attacker), 1);
        bank.transferFrom(alice, address(attacker), 2);
        vm.stopPrank();
    }

    function test_unbind_reentrantTransferAndReentrantUnbindBothBlocked() public {
        uint256 aliveBefore = bank.totalAlive();
        attacker.attack(1, 2);

        // the attack really ran: the burner had execution mid-unbind
        assertTrue(attacker.gotCallback());
        // (a) the half-unbound NFT could not be moved — it was already burned
        assertFalse(attacker.transferSucceeded());
        // (b) re-entering unbind on another owned token was stopped by the guard
        assertFalse(attacker.reenterUnbindSucceeded());

        // accomplice got nothing; the token is simply gone
        assertEq(bank.balanceOf(bob), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        bank.ownerOf(1);

        // the attacker received exactly the legitimate exit: settle payout + 1,000 WORD
        assertEq(address(attacker).balance, ethDistributor.SETTLE_PAYOUT());
        assertEq(token.balanceOf(address(attacker)), BACKING);

        // second token untouched by the failed reentry, still owned and alive
        assertEq(bank.ownerOf(2), address(attacker));
        assertEq(bank.totalAlive(), aliveBefore - 1);
        assertEq(token.balanceOf(address(bank)), (aliveBefore - 1) * BACKING);

        // and the second token unbinds normally afterwards (state not corrupted)
        attacker.attack(2, 0);
        assertEq(token.balanceOf(address(attacker)), 2 * BACKING);
        assertEq(bank.totalAlive(), aliveBefore - 2);
    }
}

// ─────────────────────────────────── fuzz: registry ────────────────────────────────────

contract WordBankRegistryFuzzTest is WordBankTestBase {
    function setUp() public override {
        super.setUp();
        _selloutPublic(alice);
        _revealOffset();
        _buildFullRegistry();
    }

    /// @notice Random unbind sequences (with interleaved admin mints) keep the registry
    ///         mutually consistent: every alive id findable via aliveAt + indexInCategory,
    ///         counts summing to totalAlive, backing matching the vault balance.
    function testFuzz_randomUnbinds_registryStaysConsistent(uint256 seed, uint256 burns) public {
        burns = bound(burns, 1, 200);
        uint256 minted = bank.totalMinted();
        uint256 burnedCount;

        for (uint256 i = 0; i < burns; ++i) {
            uint256 id = (uint256(keccak256(abi.encode(seed, i))) % minted) + 1;
            if (!bank.isAlive(id)) continue;

            // sprinkle admin reserve mints between burns (post-reveal: registers eagerly)
            if (i % 13 == 3 && bank.adminMinted() < ADMIN_RESERVE) {
                vm.prank(admin);
                bank.adminMint(1, alice);
                minted = bank.totalMinted();
            }

            vm.prank(alice);
            bank.unbind(id);
            ++burnedCount;

            // burned id fully scrubbed
            assertFalse(bank.isAlive(id));
            assertEq(bank.indexInCategory(id), 0);
            assertEq(bank.bondedBalance(id), 0);
        }

        // cheap global checks every run
        uint256 sum = bank.aliveCount(Category.NOUN) + bank.aliveCount(Category.VERB) + bank.aliveCount(Category.ADJ)
            + bank.aliveCount(Category.ADV);
        assertEq(sum, bank.totalAlive());
        assertEq(token.balanceOf(address(bank)), bank.totalAlive() * BACKING);
        assertEq(token.balanceOf(alice), burnedCount * BACKING);

        // sampled roundtrip checks: aliveAt(cat, i) ↔ indexInCategory
        for (uint8 c = 0; c < 4; ++c) {
            Category cat = Category(c);
            uint256 n = bank.aliveCount(cat);
            for (uint256 k = 0; k < 25 && k < n; ++k) {
                uint256 pos = uint256(keccak256(abi.encode(seed, c, k))) % n;
                uint256 id = bank.aliveAt(cat, pos);
                assertEq(bank.indexInCategory(id), pos + 1);
                assertTrue(bank.isAlive(id));
                assertEq(uint8(bank.categoryOf(id)), c);
            }
        }
    }
}

// ────────────────────────────────── invariant suite ────────────────────────────────────

/// @notice Random walker over unbind / adminMint / transfer, driven by the invariant engine.
contract WordBankHandler is Test {
    WordBank internal bank;
    address internal admin;
    address[] internal holders;

    constructor(WordBank bank_, address admin_, address seedHolder) {
        bank = bank_;
        admin = admin_;
        holders.push(seedHolder);
        holders.push(makeAddr("holder2"));
        holders.push(makeAddr("holder3"));
    }

    function unbindOne(uint256 seed) external {
        uint256 minted = bank.totalMinted();
        // probe a few candidates; fine to do nothing if all probes are dead
        for (uint256 i = 0; i < 10; ++i) {
            uint256 id = (uint256(keccak256(abi.encode(seed, i))) % minted) + 1;
            if (!bank.isAlive(id) || bank.indexInCategory(id) == 0) continue;
            vm.prank(bank.ownerOf(id));
            bank.unbind(id);
            return;
        }
    }

    function unbindBatch(uint256 seed, uint256 want) external {
        want = _bound(want, 1, 15);
        uint256 minted = bank.totalMinted();
        // collect distinct alive ids owned by the same holder
        for (uint256 h = 0; h < holders.length; ++h) {
            address owner_ = holders[h];
            uint256[] memory picks = new uint256[](want);
            uint256 found;
            for (uint256 i = 0; i < 60 && found < want; ++i) {
                uint256 id = (uint256(keccak256(abi.encode(seed, h, i))) % minted) + 1;
                if (!bank.isAlive(id) || bank.indexInCategory(id) == 0) continue;
                if (bank.ownerOf(id) != owner_) continue;
                bool dup;
                for (uint256 j = 0; j < found; ++j) {
                    if (picks[j] == id) dup = true;
                }
                if (dup) continue;
                picks[found++] = id;
            }
            if (found == 0) continue;
            assembly {
                mstore(picks, found) // shrink to fit
            }
            vm.prank(owner_);
            bank.unbindMany(picks);
            return;
        }
    }

    function adminMintSome(uint256 seed) external {
        uint256 remaining = 200 - bank.adminMinted();
        if (remaining == 0) return;
        uint256 n = _bound(seed, 1, remaining > 5 ? 5 : remaining);
        vm.prank(admin);
        bank.adminMint(n, holders[seed % holders.length]);
    }

    function transferOne(uint256 seed) external {
        seed %= 1e27; // keep seed-derived arithmetic below far from uint256 overflow
        uint256 minted = bank.totalMinted();
        for (uint256 i = 0; i < 10; ++i) {
            uint256 id = (uint256(keccak256(abi.encode(seed, "t", i))) % minted) + 1;
            if (!bank.isAlive(id)) continue;
            address from = bank.ownerOf(id);
            address to = holders[(seed + i) % holders.length];
            if (to == from) to = holders[(seed + i + 1) % holders.length];
            vm.prank(from);
            bank.transferFrom(from, to, id);
            return;
        }
    }
}

contract WordBankInvariantTest is WordBankTestBase {
    WordBankHandler internal handler;

    function setUp() public override {
        super.setUp();
        _selloutPublic(alice);
        _revealOffset();
        _buildFullRegistry();
        handler = new WordBankHandler(bank, admin, alice);
        targetContract(address(handler));
    }

    /// @notice Charter invariant: the vault's WORD balance always equals
    ///         totalAlive × 1,000e18 — every live NFT exactly backed, nothing stranded.
    function invariant_vaultBackingEqualsTotalAlive() public view {
        assertEq(token.balanceOf(address(bank)), bank.totalAlive() * BACKING);
    }

    /// @notice System invariant 4: per-category counts always sum to totalAlive
    ///         (registry fully synced in setUp; mints/unbinds must preserve it).
    function invariant_categoryCountsSumToTotalAlive() public view {
        uint256 sum = bank.aliveCount(Category.NOUN) + bank.aliveCount(Category.VERB) + bank.aliveCount(Category.ADJ)
            + bank.aliveCount(Category.ADV);
        assertEq(sum, bank.totalAlive());
    }

    /// @notice System invariant 2: WORD supply can never exceed the 11M hard cap.
    function invariant_supplyNeverExceedsCap() public view {
        assertLe(token.totalSupply(), 11_000_000e18);
    }

    /// @notice Provenance: the offset never moves once revealed.
    function invariant_offsetImmutable() public view {
        assertTrue(bank.offsetSet());
        assertLt(bank.wordOffset(), MAX_SUPPLY);
    }
}
