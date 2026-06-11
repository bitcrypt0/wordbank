// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";

/// @title  Phase 0 (LOCAL/TESTNET REHEARSAL ONLY) — deploy a fresh V4 PoolManager
/// @notice Mainnet uses the canonical Uniswap deployment; this exists so the full pipeline
///         can be rehearsed on anvil or a bare testnet. NOTE: the repo's v4-periphery pin
///         cannot compile the PositionManager implementation against the pinned v4-core
///         (PoolOperation split), so a local rehearsal of phase 2 needs a real-network
///         PositionManager — on anvil, rehearse phases 1 and 3 and unit/fork-test the rest.
contract DeployLocalV4 is Script {
    function run() external {
        vm.startBroadcast();
        PoolManager poolManager = new PoolManager(msg.sender);
        vm.stopBroadcast();
        console2.log("PoolManager:", address(poolManager));
    }
}
