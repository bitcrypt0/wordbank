// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {WordBank} from "../../src/WordBank.sol";
import {WordToken} from "../../src/WordToken.sol";
import {RewardsDistributor} from "../../src/RewardsDistributor.sol";
import {BountyEngine} from "../../src/BountyEngine.sol";
import {Renderer} from "../../src/Renderer.sol";
import {Category, WordData} from "../../src/interfaces/Types.sol";
import {CoreHandler} from "./handlers/CoreHandler.sol";

/// @title  CoreInvariantBase — shared fixture + executable system invariants (agent 6)
/// @notice Deploys the REAL WordBank / WordToken / RewardsDistributor (plus the real
///         BountyEngine as the dust-sweep treasury and the real — wired but unsealed —
///         Renderer; tokenURI is never called by these suites), uploads and locks all
///         10,000 word slots, and encodes the system invariants from root AGENTS.md as
///         Foundry `invariant_` functions checked after every CoreHandler action.
///
///         Invariant map (root AGENTS.md numbering):
///         - 1: invariant_backingCoversAliveExactly + per-token bond checks in the samplers
///         - 2: invariant_supplyAccounting + invariant_dynamicFloor (dynamic backing floor)
///         - 3: settle-before-decrement shows up here as exact distributor conservation /
///              solvency across unbinds (the call-ordering itself is unit-tested by agents
///              1 and 3 with call-recording mocks)
///         - 4: invariant_registryCountsSum + invariant_registrySampled (round-trip)
///         - 5/8/9: pool-backed suites (FeeHook/BurnEngine/BountyEngine cycle) — next phase
///
///         Sampling note: full registry walks are O(10,000) and invariants run after every
///         handler call, so the round-trip checks sample ~10 ids per category with a
///         stride. The COUNT invariants are always exact; only per-id spot checks sample.
abstract contract CoreInvariantBase is Test {
    using Strings for uint256;

    uint256 internal constant NUM_CATEGORIES = 4;
    uint256 internal constant MAX_SUPPLY = 10_000;
    uint256 internal constant BACKING = 1_000e18;
    uint256 internal constant SUPPLY_CAP = 11_000_000e18;
    uint256 internal constant ACC_PRECISION = 1e18;

    WordBank internal bank;
    WordToken internal token;
    RewardsDistributor internal distributor;
    BountyEngine internal bounty;
    Renderer internal renderer;
    CoreHandler internal handler;

    address internal admin = makeAddr("admin");

    // ───────────────────────────────── deployment ──────────────────────────────────────

    /// @dev Real-contract deployment in production wiring order, word slots uploaded and
    ///      locked, handler wired as WordToken's burner (see CoreHandler NatSpec for why).
    function _deployCore() internal {
        bank = new WordBank(admin);
        token = bank.wordToken();
        bounty = new BountyEngine(address(bank), admin);
        distributor = new RewardsDistributor(address(bank), address(bounty));
        renderer = new Renderer();

        vm.startPrank(admin);
        bank.setRenderer(address(renderer));
        bank.setRewardsDistributor(address(distributor));
        _uploadAllSlots();
        bank.lockSlots(keccak256("agent6-invariant-provenance"));
        vm.stopPrank();

        handler = new CoreHandler(bank, distributor, admin);
        vm.prank(admin);
        token.setBurner(address(handler));
    }

    /// @dev Deterministic slot data: word-i, category i % 4 — every expectation recomputable.
    function _uploadAllSlots() internal {
        uint256 batchSize = 1_000;
        for (uint256 b = 0; b < MAX_SUPPLY / batchSize; ++b) {
            WordData[] memory batch = new WordData[](batchSize);
            for (uint256 i = 0; i < batchSize; ++i) {
                uint256 idx = b * batchSize + i;
                batch[i] = WordData({
                    word: string.concat("word-", idx.toString()),
                    category: Category(idx % NUM_CATEGORIES),
                    material: uint8(idx % 19),
                    ink: uint8(idx % 5),
                    background: uint8(idx % 7),
                    honors: idx < 25
                });
            }
            bank.setWordSlots(b * batchSize, batch);
        }
    }

    // ──────────────────────────── system invariant 1: backing ──────────────────────────

    /// @notice The vault's WORD balance equals totalAlive × 1,000e18 exactly — backing can
    ///         neither leak out of nor accrete inside the WordBank.
    function invariant_backingCoversAliveExactly() public view {
        assertEq(
            token.balanceOf(address(bank)),
            bank.totalAlive() * BACKING,
            "INV-1: vault WORD balance != totalAlive x 1000e18"
        );
    }

    // ──────────────────────────── system invariant 2: supply ───────────────────────────

    /// @notice Supply ledger closes exactly: minted = backing + liquidity, supply = minted
    ///         − burned, every allotment within its hard cap.
    function invariant_supplyAccounting() public view {
        uint256 supply = token.totalSupply();
        assertLe(supply, SUPPLY_CAP, "INV-2: totalSupply > 11M");
        assertEq(token.backingMinted(), bank.totalMinted() * BACKING, "INV-2: backingMinted != totalMinted x 1000e18");
        assertLe(token.backingMinted(), 10_000_000e18, "INV-2: backing cap exceeded");
        assertLe(token.liquidityMinted(), 1_000_000e18, "INV-2: liquidity cap exceeded");
        assertLe(token.burnedTotal(), 1_000_000e18, "INV-2: burnedTotal > 1M");
        assertEq(
            supply + token.burnedTotal(),
            token.backingMinted() + token.liquidityMinted(),
            "INV-2: supply + burned != backing + liquidity"
        );
    }

    /// @notice Dynamic backing floor (interfaces-v3): totalSupply can never fall below the
    ///         LIVE floor `totalAlive × 1000e18`, and never above 11M. The floor descends
    ///         only as NFTs unbind, and `burnableExcess()` is exactly `supply − floor` (0 at
    ///         the floor). There is no `burnComplete` and no permanent completion — burning
    ///         pauses at the floor and resumes after the next unbind. This holds at every
    ///         stage (pre- and post-seal), since the WordBank always holds exactly
    ///         `totalAlive × 1000e18` of backing inside `totalSupply`.
    function invariant_dynamicFloor() public view {
        uint256 supply = token.totalSupply();
        uint256 floor = bank.totalAlive() * BACKING;
        assertGe(supply, floor, "INV-2: supply below the live backing floor");
        assertLe(supply, SUPPLY_CAP, "INV-2: supply > 11M");
        assertEq(token.currentBurnFloor(), floor, "INV-2: currentBurnFloor != totalAlive x 1000e18");
        assertEq(token.burnableExcess(), supply - floor, "INV-2: burnableExcess != supply - floor");
        // Burning is gated on the seal; nothing can be burned before it.
        if (!token.mintingSealed()) {
            assertEq(token.burnedTotal(), 0, "INV-2: burned before seal");
        }
    }

    // ─────────────────────────── system invariant 4: registry ──────────────────────────

    /// @notice Category counts always sum to exactly the number of registered alive tokens
    ///         (derived in closed form from contract views: registryCursor + totalAlive −
    ///         preRevealMinted once the offset is set; zero before). Once registrySynced,
    ///         the sum equals totalAlive — the architecture's stated invariant-4 form.
    function invariant_registryCountsSum() public view {
        uint256 sum;
        for (uint8 c = 0; c < NUM_CATEGORIES; ++c) {
            sum += bank.aliveCount(Category(c));
        }
        if (!bank.offsetSet()) {
            assertEq(sum, 0, "INV-4: registry populated before offset reveal");
            return;
        }
        assertEq(
            sum,
            bank.registryCursor() + bank.totalAlive() - bank.preRevealMinted(),
            "INV-4: category counts != registered alive tokens"
        );
        if (bank.registrySynced()) {
            assertEq(sum, bank.totalAlive(), "INV-4: synced registry != totalAlive");
        }
    }

    /// @notice Sampled both-direction round trip: every sampled registry entry maps back
    ///         through indexInCategory, is alive, sits in the right category array, holds
    ///         its exact 1,000e18 bond, and is Active in the distributor. Also asserts the
    ///         sampled pending-rewards sum is covered by the distributor's free balance.
    function invariant_registrySampled() public view {
        uint256 pendingSum;
        for (uint8 c = 0; c < NUM_CATEGORIES; ++c) {
            Category cat = Category(c);
            uint256 n = bank.aliveCount(cat);
            if (n == 0) continue;
            uint256 step = n / 10 + 1;
            for (uint256 i = 0; i < n; i += step) {
                uint256 id = bank.aliveAt(cat, i);
                assertEq(bank.indexInCategory(id), i + 1, "INV-4: index map out of sync");
                assertTrue(bank.isAlive(id), "INV-4: registry holds dead token");
                assertEq(uint8(bank.categoryOf(id)), c, "INV-4: token in wrong category array");
                assertEq(bank.bondedBalance(id), BACKING, "INV-1: alive token bond != 1000e18");
                assertEq(
                    uint8(distributor.statusOf(id)),
                    uint8(RewardsDistributor.TokenStatus.Active),
                    "INV-1: alive token not Active in distributor"
                );
                pendingSum += distributor.pendingRewards(id);
            }
        }
        assertLe(
            pendingSum,
            address(distributor).balance - distributor.pendingUndistributed(),
            "rewards: sampled pending sum exceeds free balance"
        );
    }

    /// @notice Sampled "stays dead": unbound ids are not alive, hold no bond, are out of
    ///         the registry, and are Closed with zero pending in the distributor.
    function invariant_unboundStayDeadSampled() public view {
        uint256 n = handler.unboundCount();
        if (n == 0) return;
        uint256 step = n / 10 + 1;
        for (uint256 i = 0; i < n; i += step) {
            uint256 id = handler.unboundAt(i);
            assertFalse(bank.isAlive(id), "unbound id alive again");
            assertEq(bank.bondedBalance(id), 0, "unbound id still bonded");
            assertEq(bank.indexInCategory(id), 0, "unbound id still in registry");
            assertEq(distributor.pendingRewards(id), 0, "unbound id still accrues");
            assertEq(
                uint8(distributor.statusOf(id)),
                uint8(RewardsDistributor.TokenStatus.Closed),
                "unbound id not Closed in distributor"
            );
        }
    }

    // ──────────────────────── rewards solvency & ETH conservation ──────────────────────

    /// @notice The distributor's balance always covers the deferred buffer plus the ceiling
    ///         of all outstanding scaled entitlements — the contract's own documented
    ///         solvency line, checked from outside.
    function invariant_distributorSolvency() public view {
        uint256 reserved =
            distributor.pendingUndistributed() + (distributor.owedScaled() + ACC_PRECISION - 1) / ACC_PRECISION;
        assertGe(address(distributor).balance, reserved, "rewards: balance below reserved entitlements");
    }

    /// @notice Exact ETH conservation: balance == everything deposited − everything paid out
    ///         (claims, unbind settlements, dust sweeps), to the wei.
    function invariant_distributorEthConservation() public view {
        assertEq(
            address(distributor).balance,
            handler.ghostDistIn() - handler.ghostDistOut(),
            "rewards: ETH conservation broken"
        );
    }

    // ────────────────────────────────── reporting ──────────────────────────────────────

    /// @dev Coverage log so a run that silently no-opped its way to green is visible.
    function afterInvariant() public view {
        console2.log("-- core handler coverage --");
        console2.log("openSale", handler.calls("openSale"));
        console2.log("reconfigure", handler.calls("reconfigure"));
        console2.log("earlyBirdMint", handler.calls("earlyBirdMint"));
        console2.log("publicMint", handler.calls("publicMint"));
        console2.log("adminMint", handler.calls("adminMint"));
        console2.log("revealOffset", handler.calls("revealOffset"));
        console2.log("lapseAndRearm", handler.calls("lapseAndRearm"));
        console2.log("buildRegistry", handler.calls("buildRegistry"));
        console2.log("deposit", handler.calls("deposit"));
        console2.log("claim", handler.calls("claim"));
        console2.log("transfer", handler.calls("transfer"));
        console2.log("unbind", handler.calls("unbind"));
        console2.log("unbindMany", handler.calls("unbindMany"));
        console2.log("sweepDust", handler.calls("sweepDust"));
        console2.log("mintLiquidity", handler.calls("mintLiquidity"));
        console2.log("sealMinting", handler.calls("sealMinting"));
        console2.log("burn", handler.calls("burn"));
        console2.log("totalMinted", bank.totalMinted());
        console2.log("totalAlive", bank.totalAlive());
        console2.log("totalSupply", token.totalSupply());
    }
}
