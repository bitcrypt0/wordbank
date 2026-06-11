// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IntegrationBase} from "./IntegrationBase.sol";
import {WordBank} from "../../src/WordBank.sol";
import {Category} from "../../src/interfaces/Types.sol";

/// @title  Scenario: the full mint lifecycle, end to end against real contracts (agent 6)
/// @notice Charter scenario 1: batch word writes → early bird (cap enforced) → phase
///         transition with pause/reconfigure → public sale → the 9,800th public mint fires
///         the provenance commit → reveal → registry build to sync → admin reserve minted
///         late → liquidity allotment → supply seals at exactly 11,000,000e18.
contract FullMintLifecycleTest is IntegrationBase {
    function setUp() public {
        _deployProtocol();
    }

    /// @dev The whole arc in one continuous story, asserting the state gates at every stage.
    function test_fullMintLifecycle_throughSealAt11M() public {
        // ── Stage: configured two-phase sale (3,000 early bird @ cap 5 / 6,800 public). ──
        vm.startPrank(admin);
        bank.setSaleConfig(3_000, 6_800, EB_PRICE, PUB_PRICE, 5);
        bank.openEarlyBird();
        vm.stopPrank();

        // Early bird: cap is enforced per wallet, this phase only.
        vm.prank(alice);
        bank.earlyBirdMint{value: 5 * EB_PRICE}(5);
        vm.prank(alice);
        vm.expectRevert(WordBank.ExceedsWalletCap.selector);
        bank.earlyBirdMint{value: EB_PRICE}(1);
        // Exact payment enforced.
        vm.prank(bob);
        vm.expectRevert(WordBank.WrongPayment.selector);
        bank.earlyBirdMint{value: 3 * EB_PRICE - 1}(3);
        vm.prank(bob);
        bank.earlyBirdMint{value: 5 * EB_PRICE}(5);

        // ── Stage: admin advances early (Between), reconfigures, opens the public sale. ──
        vm.startPrank(admin);
        bank.closeEarlyBird();
        // Fold the undersold early bird remainder into the public allocation (floors hold:
        // 10 early bird minted, so its allocation cannot drop below 10).
        vm.expectRevert(WordBank.AllocationBelowMinted.selector);
        bank.setSaleConfig(5, 9_795, EB_PRICE, PUB_PRICE, 5);
        bank.setSaleConfig(10, 9_790, EB_PRICE, PUB_PRICE, 5);
        bank.openPublicSale();
        // Pause back to Between and resume — the documented correction path.
        bank.pausePublicSale();
        bank.openPublicSale();
        vm.stopPrank();

        // No early bird mints in the public phase; the cap does not apply here.
        vm.prank(alice);
        vm.expectRevert(WordBank.WrongPhase.selector);
        bank.earlyBirdMint{value: EB_PRICE}(1);

        // ── Stage: public sale to the 9,800 sellout — arming provenance on the last mint. ─
        assertEq(bank.offsetTargetBlock(), 0, "offset must not arm early");
        vm.prank(alice);
        bank.publicMint{value: 4_000 * PUB_PRICE}(4_000);
        vm.prank(bob);
        bank.publicMint{value: 4_000 * PUB_PRICE}(4_000);
        vm.prank(carol);
        bank.publicMint{value: 1_789 * PUB_PRICE}(1_789);
        assertEq(bank.offsetTargetBlock(), 0, "one short of sellout: still unarmed");

        vm.prank(carol);
        bank.publicMint{value: PUB_PRICE}(1); // the 9,800th public mint
        assertGt(bank.offsetTargetBlock(), block.number, "public sellout arms the offset commit");
        assertEq(bank.totalMinted(), PUBLIC_SUPPLY);

        // Backing minted 1:1000 for every mint so far; everything still unregistered.
        assertEq(token.balanceOf(address(bank)), PUBLIC_SUPPLY * BACKING);
        assertFalse(bank.registrySynced());

        // ── Stage: reveal + registry build (02b choreography). ──
        vm.roll(bank.offsetTargetBlock() + 1);
        bank.revealOffset();
        assertTrue(bank.offsetSet());
        assertLt(bank.wordOffset(), MAX_NFT_SUPPLY);

        uint256 builds;
        while (!bank.registrySynced()) {
            bank.buildRegistry(2_500);
            builds++;
        }
        assertEq(builds, 4, "9,800 ids at 2,500 per call");
        uint256 sum;
        for (uint8 c = 0; c < NUM_CATEGORIES; ++c) {
            sum += bank.aliveCount(Category(c));
        }
        assertEq(sum, PUBLIC_SUPPLY, "registry holds every pre-reveal id");

        // ── Stage: admin reserve minted LATE (post-reveal, registers eagerly). ──
        vm.prank(admin);
        bank.adminMint(ADMIN_RESERVE, admin);
        assertEq(bank.totalMinted(), MAX_NFT_SUPPLY);
        assertEq(bank.totalAlive(), MAX_NFT_SUPPLY);
        sum = 0;
        for (uint8 c = 0; c < NUM_CATEGORIES; ++c) {
            sum += bank.aliveCount(Category(c));
        }
        assertEq(sum, MAX_NFT_SUPPLY, "late reserve registers eagerly");

        // The 201st reserve mint can never exist.
        vm.prank(admin);
        vm.expectRevert(WordBank.ExceedsAdminReserve.selector);
        bank.adminMint(1, admin);

        // ── Stage: liquidity + permissionless seal at exactly 11M. ──
        assertEq(token.totalSupply(), MAX_NFT_SUPPLY * BACKING);
        vm.expectRevert(); // SealPreconditionsNotMet — liquidity not minted yet
        token.sealMinting();

        vm.prank(admin);
        token.mintLiquidity(address(this), LIQUIDITY_CAP);
        token.sealMinting(); // permissionless once preconditions hold
        assertTrue(token.mintingSealed());
        assertEq(token.totalSupply(), 11_000_000e18, "seals at exactly 11M");

        // Sale proceeds accrued in the bank and are admin-withdrawable.
        uint256 expectedProceeds = 10 * EB_PRICE + 9_790 * PUB_PRICE; // 10 early bird + 9,790 public
        assertEq(address(bank).balance, expectedProceeds);
        address payout = makeAddr("payout");
        vm.prank(admin);
        bank.withdrawProceeds(payout);
        assertEq(payout.balance, expectedProceeds);
    }

    /// @dev Words and categories are only knowable post-reveal, and every minted token's
    ///      category matches its provenance slot.
    function test_provenance_wordsUnknowableUntilReveal() public {
        _mintOutCollection();

        vm.expectRevert(WordBank.OffsetNotSet.selector);
        bank.wordOf(1);

        _syncRegistry();

        uint256 offset = bank.wordOffset();
        for (uint256 id = 1; id <= 25; ++id) {
            uint256 slot = (id - 1 + offset) % MAX_NFT_SUPPLY;
            assertEq(uint8(bank.categoryOf(id)), uint8(Category(slot % NUM_CATEGORIES)));
        }
    }
}
