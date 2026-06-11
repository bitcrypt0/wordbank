// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {FeeHook} from "../src/FeeHook.sol";
import {IBountyEngine} from "../src/interfaces/IBountyEngine.sol";
import {IBurnEngine} from "../src/interfaces/IBurnEngine.sol";
import {IRewardsDistributor} from "../src/interfaces/IRewardsDistributor.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title  Standalone hook-salt miner (no broadcast, pure computation)
/// @notice Used by the Hardhat pipeline (deploy/) which shells out to
///         `forge script script/MineHookSalt.s.sol` and parses the logged salt/address.
///         The same mining runs inline in 01_DeployProtocol; this exists so the TS
///         orchestration can pre-compute and verify the address independently.
///
///         Required env: POOL_MANAGER, WORD_TOKEN, REWARDS_DISTRIBUTOR, BOUNTY_ENGINE,
///         BURN_ENGINE, ADMIN. Optional: LP_FEE (3000), TICK_SPACING (60),
///         CREATE2_DEPLOYER (canonical 0x4e59…956C).
contract MineHookSalt is Script {
    uint160 constant HOOK_FLAGS = uint160((1 << 7) | (1 << 6) | (1 << 3) | (1 << 2)); // 0x00CC

    function run() external view {
        address deployer = vm.envOr("CREATE2_DEPLOYER", 0x4e59b44847b379578588920cA78FbF26c0B4956C);
        bytes memory args = abi.encode(
            IPoolManager(vm.envAddress("POOL_MANAGER")),
            vm.envAddress("WORD_TOKEN"),
            uint24(vm.envOr("LP_FEE", uint256(3000))),
            int24(int256(vm.envOr("TICK_SPACING", uint256(60)))),
            IRewardsDistributor(vm.envAddress("REWARDS_DISTRIBUTOR")),
            IBountyEngine(vm.envAddress("BOUNTY_ENGINE")),
            IBurnEngine(vm.envAddress("BURN_ENGINE")),
            vm.envAddress("ADMIN")
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(deployer, HOOK_FLAGS, type(FeeHook).creationCode, args);
        console2.log("HOOK_ADDRESS:", hookAddress);
        console2.log("HOOK_SALT:", vm.toString(salt));
    }
}
