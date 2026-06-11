// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {WordBank} from "../src/WordBank.sol";

/// @title  Phase 2.5 — fix the provenance offset and build the game registry
/// @notice Runs the post-sellout choreography (overseer review M-1). When the 9,800th public
///         NFT mints, WordBank arms an offset commit for `block.number + 15`. This script,
///         run any time after that:
///           1. reveals the offset from the target block's hash (or, if the 256-block
///              window lapsed unrevealed, re-arms and tells you to re-run in ~15 blocks);
///           2. loops `buildRegistry(batch)` until `registrySynced()` is true, pushing every
///              pre-reveal token into the category-indexed alive registry.
///
///         ⚠️ ANNOUNCEMENT GATE: do NOT announce or open the daily game before
///         `registrySynced()` reads true. Between the offset reveal and full sync the
///         registry is PARTIAL: a BountyEngine reveal in that window would draw from a
///         biased subset of words. (Before the offset reveal, game reveals abort cleanly —
///         harmless; after it, they are biased — not harmless.)
///
///         Required env: WORD_BANK. Optional: REGISTRY_BATCH (250 tokens per tx — sized to
///         stay well inside the block gas limit).
contract SyncRegistry is Script {
    uint256 constant MAX_BUILD_CALLS = 200;

    function run() external {
        WordBank bank = WordBank(payable(vm.envAddress("WORD_BANK")));
        uint256 batch = vm.envOr("REGISTRY_BATCH", uint256(250));

        if (bank.registrySynced()) {
            console2.log("Registry already synced - nothing to do. The game may be announced.");
            return;
        }

        if (!bank.offsetSet()) {
            uint256 target = bank.offsetTargetBlock();
            require(target != 0, "offset not armed: the 9,800 public allocation has not sold out yet");
            require(block.number > target, "reveal too early: wait until the target block has passed (~3 min)");

            if (blockhash(target) == bytes32(0)) {
                // The 256-block reveal window lapsed unrevealed - re-arm and come back.
                vm.startBroadcast();
                bank.rearmOffset();
                vm.stopBroadcast();
                console2.log("Reveal window had lapsed. RE-ARMED for block:", bank.offsetTargetBlock());
                console2.log("Re-run this script after that block (~15 blocks / ~3 minutes).");
                return;
            }

            vm.startBroadcast();
            bank.revealOffset();
            vm.stopBroadcast();
            console2.log("Offset revealed:", bank.wordOffset());
        }

        // Build the registry to sync. ~9,800+ tokens at `batch` per tx.
        vm.startBroadcast();
        uint256 calls;
        while (!bank.registrySynced()) {
            bank.buildRegistry(batch);
            calls++;
            require(calls <= MAX_BUILD_CALLS, "exceeded MAX_BUILD_CALLS - raise REGISTRY_BATCH");
        }
        vm.stopBroadcast();

        console2.log("Registry built in buildRegistry calls:", calls);
        console2.log("registrySynced() == true. THE DAILY GAME MAY NOW BE ANNOUNCED.");
    }
}
