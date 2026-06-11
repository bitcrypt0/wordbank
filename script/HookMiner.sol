// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title  HookMiner — CREATE2 salt mining for Uniswap V4 hook addresses
/// @notice V4 reads a hook's permissions from the low 14 bits of its ADDRESS, so the FeeHook
///         must be deployed to an address whose flag bits are exactly
///         BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA
///         (= 0x00CC). This library brute-forces a CREATE2 salt that produces such an
///         address for a given deployer + creation code + constructor args.
/// @dev    With 8 of 14 bits fixed the expected search is 2^14 / ... ≈ 16,384 attempts on
///         average (each candidate must match all 14 flag bits exactly); 200k iterations
///         gives comfortable headroom. Used by the deploy scripts and by the Hardhat
///         pipeline via `forge script script/MineHookSalt.s.sol`.
library HookMiner {
    /// @notice Mask of all 14 hook-permission bits.
    uint160 internal constant FLAG_MASK = Hooks.ALL_HOOK_MASK; // (1 << 14) - 1

    /// @notice Maximum salts to try before giving up.
    uint256 internal constant MAX_LOOP = 200_000;

    error NoSaltFound();

    /// @param deployer     The CREATE2 deployer that will run the deployment. For forge
    ///                     scripts using `new FeeHook{salt: ...}` this is the canonical
    ///                     deterministic deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C.
    /// @param flags        The exact flag bits the address must encode (e.g. 0x00CC).
    /// @param creationCode type(FeeHook).creationCode.
    /// @param constructorArgs abi.encode(...) of the constructor arguments.
    /// @return hookAddress The first matching address.
    /// @return salt        The salt that produces it.
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i = 0; i < MAX_LOOP; i++) {
            address candidate = computeAddress(deployer, bytes32(i), initCodeHash);
            if (uint160(candidate) & FLAG_MASK == flags && candidate.code.length == 0) {
                return (candidate, bytes32(i));
            }
        }
        revert NoSaltFound();
    }

    /// @notice Standard CREATE2 address derivation.
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
