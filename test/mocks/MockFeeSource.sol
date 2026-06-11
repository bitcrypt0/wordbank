// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";

/// @title  MockFeeSource — stand-in for the FeeHook's rewards-slice flush (agent 3)
/// @notice Accrues ETH like the hook does between flushes, then pushes its whole balance
///         into the distributor via the permissionless deposit() — the exact call shape
///         agent 5's FeeHook will use.
contract MockFeeSource {
    IRewardsDistributor public immutable distributor;

    constructor(IRewardsDistributor distributor_) {
        distributor = distributor_;
    }

    /// @notice Accrue fee ETH (the hook's skim between flushes).
    receive() external payable {}

    /// @notice Push the accrued balance to the distributor, FeeHook-flush style.
    function flush() external {
        distributor.deposit{value: address(this).balance}();
    }
}
