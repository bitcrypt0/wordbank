// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IFlushable {
    function flush() external;
}

/// @notice Malicious deposit sink that re-enters FeeHook.flush() — used to prove the flush
///         reentrancy lock (agent 5 unit tests).
contract MockReenteringSink {
    function deposit() external payable {
        IFlushable(msg.sender).flush();
    }
}
