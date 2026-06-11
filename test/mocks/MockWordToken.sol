// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice WORD stand-in for the FeeHook unit suite (agent 5). A fully functional ERC-20 (so
///         it works as the pool's currency1) plus a settable `burnableExcess()` — the single
///         WordToken view the FeeHook reads on each flush to pick the routing mode (three-way
///         when excess > 0, two-way when 0). The real WordToken derives this from
///         `WordBank.totalAlive()`; here it is set directly so tests can drive both modes.
contract MockWordToken is MockERC20 {
    uint256 private _burnableExcess;

    constructor() MockERC20("Word", "WORD", 18) {}

    /// @notice Test hook: set the value the FeeHook will read on the next flush.
    function setBurnableExcess(uint256 excess) external {
        _burnableExcess = excess;
    }

    function burnableExcess() external view returns (uint256) {
        return _burnableExcess;
    }
}
