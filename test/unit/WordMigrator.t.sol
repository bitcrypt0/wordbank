// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WordMigrator} from "../../src/WordMigrator.sol";
import {MockWordToken} from "../mocks/MockWordToken.sol";

/// @notice Unit suite for WordMigrator. Builds a 3-leaf Merkle tree by hand using the same
///         leaf encoding (double-hashed) and commutative pair hashing as OpenZeppelin's
///         MerkleProof, so the snapshot generator can target the OZ StandardMerkleTree format.
contract WordMigratorTest is Test {
    MockWordToken oldTok;
    MockWordToken newTok;
    WordMigrator migrator;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Snapshot: (holder, oldBalance, newEntitlement) at ratio 0.2 (200 reserve over 1000 old).
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);
    address dave = address(0xDA4E); // NOT in the snapshot

    uint256 constant A_OLD = 100e18;
    uint256 constant A_NEW = 20e18;
    uint256 constant B_OLD = 300e18;
    uint256 constant B_NEW = 60e18;
    uint256 constant C_OLD = 600e18;
    uint256 constant C_NEW = 120e18;
    uint256 constant RESERVE = A_NEW + B_NEW + C_NEW; // 200e18

    bytes32 l0;
    bytes32 l1;
    bytes32 l2;
    bytes32 n01;
    bytes32 root;

    function setUp() public {
        oldTok = new MockWordToken();
        newTok = new MockWordToken();

        // Leaves (OZ StandardMerkleTree: double keccak of abi.encode(values)).
        l0 = _leaf(alice, A_OLD, A_NEW);
        l1 = _leaf(bob, B_OLD, B_NEW);
        l2 = _leaf(carol, C_OLD, C_NEW);
        // Tree:  root = H(H(l0,l1), l2)
        n01 = _hashPair(l0, l1);
        root = _hashPair(n01, l2);

        migrator = new WordMigrator(address(oldTok), address(newTok), root);

        // Fund the migrator with exactly the reserve; give holders their old WORD + approval.
        newTok.mint(address(migrator), RESERVE);
        oldTok.mint(alice, A_OLD);
        oldTok.mint(bob, B_OLD);
        oldTok.mint(carol, C_OLD);
        vm.prank(alice);
        oldTok.approve(address(migrator), type(uint256).max);
        vm.prank(bob);
        oldTok.approve(address(migrator), type(uint256).max);
        vm.prank(carol);
        oldTok.approve(address(migrator), type(uint256).max);
    }

    // ── merkle helpers (mirror OZ MerkleProof) ──
    function _leaf(address a, uint256 o, uint256 n) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, o, n))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proofAlice() internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = l1;
        p[1] = l2;
    }

    function _proofCarol() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = n01;
    }

    // ─────────────────────────────────── tests ─────────────────────────────────────────

    function test_constructorRejectsZero() public {
        vm.expectRevert(WordMigrator.ZeroAddress.selector);
        new WordMigrator(address(0), address(newTok), root);
        vm.expectRevert(WordMigrator.ZeroAddress.selector);
        new WordMigrator(address(oldTok), address(0), root);
    }

    function test_claimBurnsOldAndDeliversNew() public {
        vm.prank(alice);
        migrator.claim(A_OLD, A_NEW, _proofAlice());

        assertEq(newTok.balanceOf(alice), A_NEW, "received new");
        assertEq(oldTok.balanceOf(alice), 0, "old burned");
        assertEq(oldTok.balanceOf(DEAD), A_OLD, "old at dead address");
        assertTrue(migrator.claimed(alice));
        assertEq(migrator.totalMigrated(), A_NEW);
        assertEq(newTok.balanceOf(address(migrator)), RESERVE - A_NEW, "reserve drawn down");
    }

    function test_doubleClaimReverts() public {
        vm.startPrank(alice);
        migrator.claim(A_OLD, A_NEW, _proofAlice());
        vm.expectRevert(WordMigrator.AlreadyClaimed.selector);
        migrator.claim(A_OLD, A_NEW, _proofAlice());
        vm.stopPrank();
    }

    function test_nonEligibleReverts() public {
        // dave isn't in the tree.
        oldTok.mint(dave, A_OLD);
        vm.prank(dave);
        oldTok.approve(address(migrator), type(uint256).max);
        vm.prank(dave);
        vm.expectRevert(WordMigrator.InvalidProof.selector);
        migrator.claim(A_OLD, A_NEW, _proofAlice());
    }

    function test_alteredAmountReverts() public {
        // Correct sender + proof, but inflated newAmount → different leaf → invalid.
        vm.prank(alice);
        vm.expectRevert(WordMigrator.InvalidProof.selector);
        migrator.claim(A_OLD, A_NEW + 1, _proofAlice());
    }

    function test_mustHoldOldBalance() public {
        // Carol moves her old WORD away → cannot burn her snapshot amount.
        vm.prank(carol);
        oldTok.transfer(dave, C_OLD);
        vm.prank(carol);
        vm.expectRevert(); // ERC20 insufficient balance inside safeTransferFrom
        migrator.claim(C_OLD, C_NEW, _proofCarol());
    }

    function test_noDeadline_claimableFarInFuture() public {
        vm.warp(block.timestamp + 3650 days);
        vm.prank(carol);
        migrator.claim(C_OLD, C_NEW, _proofCarol());
        assertEq(newTok.balanceOf(carol), C_NEW);
    }

    function test_allClaim_reserveFullyDistributed() public {
        vm.prank(alice);
        migrator.claim(A_OLD, A_NEW, _proofAlice());
        bytes32[] memory pBob = new bytes32[](2);
        pBob[0] = l0;
        pBob[1] = l2;
        vm.prank(bob);
        migrator.claim(B_OLD, B_NEW, pBob);
        vm.prank(carol);
        migrator.claim(C_OLD, C_NEW, _proofCarol());

        assertEq(migrator.totalMigrated(), RESERVE);
        assertEq(newTok.balanceOf(address(migrator)), 0, "reserve emptied");
        assertEq(oldTok.balanceOf(DEAD), A_OLD + B_OLD + C_OLD, "all old burned");
    }
}
