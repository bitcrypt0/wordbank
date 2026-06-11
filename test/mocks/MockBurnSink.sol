// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal IBurnEngine ETH-sink stand-in for FeeHook unit tests (agent 5). The hook
///         deposits the burn slice here on three-way flushes; the test asserts on `received`.
///         (v3: the hook no longer reads any completion flag from the engine — it picks the
///         split from WordToken.burnableExcess() — so this is now a plain sink.)
contract MockBurnSink {
    uint256 public received;
    uint256 public depositCount;

    function deposit() external payable {
        received += msg.value;
        depositCount += 1;
    }
}
