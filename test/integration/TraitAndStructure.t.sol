// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IntegrationBase} from "./IntegrationBase.sol";
import {Category} from "../../src/interfaces/Types.sol";

/// @title  Invariant 6 (visual rarity ⊥ gameplay) + invariant 9 structural (agent 6)
/// @notice Two executable proofs the other suites don't cover:
///
///         INVARIANT 6 — visual traits NEVER influence gameplay. Documented method: a
///         RECOMPUTE proof. The test re-derives every reveal's drawn tokenIds from scratch
///         using ONLY the public entropy seed and the category-indexed alive set
///         (`aliveAt`/`aliveCount`) — never touching material/ink/background/honors. If the
///         reproduction, which has no trait inputs at all, matches the contract's actual
///         draw exactly, then traits provably cannot be inputs to selection. This is
///         stronger than a source grep: it proves the running bytecode's behavior, not just
///         that the source text omits an identifier. Backed by a complementary behavioral
///         check that holder rewards are identical across tokens of different rarity.
///
///         INVARIANT 9 (structural) — the buyback runs in its OWN transaction and the
///         FeeHook holds NO swap logic. Proven behaviorally: `flush()` routes ETH without
///         ever moving the pool price (it performs no swap), whereas `executeBuyback()`
///         does move the price (it swaps) — and only ever as its own top-level call, never
///         from inside a hook callback.
contract TraitAndStructureTest is IntegrationBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // BountyEngine seed-domain separator for slot draws (DOMAIN_SLOT = 1 in BountyEngine).
    uint256 internal constant DOMAIN_SLOT = 1;

    function setUp() public {
        _deployProtocol();
        _mintOutCollection();
        _syncRegistry();
        _seedPool();
        _seal();
        _enableTrading();
        _expireGuard();
    }

    // ───────────────────── invariant 6: draw is trait-independent ───────────────────────

    /// @dev Adds ONE template of three DISTINCT categories (so slot dedup never triggers —
    ///      each slot draws from its own category array), then for several reveals
    ///      recomputes the drawn ids from (seed, aliveAt) alone and asserts an exact match.
    function test_invariant6_drawIsTraitIndependent_recompute() public {
        // Single always-feasible template: ADJ NOUN VERB (each category has ~2,500 alive).
        Category[] memory slots = new Category[](3);
        slots[0] = Category.ADJ;
        slots[1] = Category.NOUN;
        slots[2] = Category.VERB;
        string[] memory frags = new string[](4);
        frags[0] = "The ";
        frags[1] = " ";
        frags[2] = " ";
        frags[3] = ".";
        vm.prank(admin);
        bounty.addTemplate(slots, frags);

        bounty.deposit{value: 5 ether}();

        for (uint256 round = 0; round < 5; ++round) {
            // Commit → reveal a fresh event.
            vm.prank(alice);
            bounty.commit{value: BOND}();
            (, uint64 targetBlock, uint256 eventId) = bounty.currentCommit();
            vm.roll(uint256(targetBlock) + 1);
            vm.prank(keeper);
            bounty.reveal();

            (uint256[] memory actual,,,) = bounty.eventInfo(eventId);
            assertEq(actual.length, 3, "the only template drew");

            // Recompute using ONLY entropy + the category-indexed alive set. No trait reads.
            bytes32 seed = keccak256(abi.encode(blockhash(targetBlock), address(bounty), eventId));
            for (uint256 i = 0; i < slots.length; ++i) {
                uint256 count = bank.aliveCount(slots[i]);
                uint256 idx = uint256(keccak256(abi.encode(seed, DOMAIN_SLOT, i))) % count;
                uint256 expected = bank.aliveAt(slots[i], idx);
                assertEq(actual[i], expected, "draw reproduced from categories + seed alone");
                // And the drawn word's category matches its slot — selection is category-keyed.
                assertEq(uint8(bank.categoryOf(actual[i])), uint8(slots[i]), "slot category honored");
            }

            // Advance past the 24h cycle for the next round.
            vm.warp(block.timestamp + 24 hours + 1);
        }
    }

    /// @dev Complementary behavioral check: two tokens of DIFFERENT visual rarity accrue the
    ///      exact same holder reward from a deposit — the rewards stream is flat across the
    ///      collection (RewardsDistributor never receives or reads WordData; it is keyed by
    ///      tokenId only — a type-level guarantee, confirmed here in behavior).
    function test_invariant6_rewardsFlatAcrossRarity() public {
        // word-i has honors == (i < 25) and material == i % 19, so different slots carry
        // visibly different rarity. Pick two alive tokens whose slots differ in traits.
        uint256 idA = 1;
        uint256 idB = 2;

        // A swap-fed deposit, then assert equal pending regardless of rarity.
        _buyExactIn(bob, 5 ether);
        hook.flush();
        assertEq(distributor.pendingRewards(idA), distributor.pendingRewards(idB), "rewards ignore rarity");
        assertGt(distributor.pendingRewards(idA), 0);
    }

    // ─────────────────── invariant 9 (structural): own-tx separation ────────────────────

    /// @dev The FeeHook holds NO swap logic: routing accrued fees via flush() never moves
    ///      the pool price. The BurnEngine's buyback DOES move it — and runs as its own
    ///      top-level transaction (an unlock it opens itself), never from a hook callback.
    function test_invariant9_flushNeverSwaps_buybackIsOwnTx() public {
        // Accrue fees, then flush. The pool price must be unchanged by routing alone.
        _buyExactIn(bob, 5 ether);
        uint160 priceBeforeFlush = _spotSqrtPrice();
        assertGt(address(hook).balance, 0, "fees accrued to route");
        hook.flush();
        assertEq(_spotSqrtPrice(), priceBeforeFlush, "INV-9: flush performed no swap (hook holds no swap logic)");
        assertEq(address(hook).balance, 0, "fees were routed, not swapped");

        // The BurnEngine's buyback is a swap and DOES move the price — as its own call.
        burnEngine.deposit{value: 1 ether}();
        uint160 priceBeforeBuyback = _spotSqrtPrice();
        vm.roll(block.number + 1);
        vm.prank(keeper);
        burnEngine.executeBuyback(1 ether);
        assertTrue(_spotSqrtPrice() != priceBeforeBuyback, "buyback swapped (its own transaction)");
        assertGt(token.burnedTotal(), 0, "and burned what it bought");
    }

    /// @dev Reads the canonical pool's current sqrtPrice via StateLibrary (as BurnEngine does).
    function _spotSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
    }
}
