// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal ETH sink standing in for IRewardsDistributor / IBountyEngine in FeeHook
///         and BurnEngine unit tests (agent 5). Records cumulative deposits.
contract MockEthSink {
    uint256 public received;
    uint256 public depositCount;

    function deposit() external payable {
        received += msg.value;
        depositCount += 1;
    }
}
