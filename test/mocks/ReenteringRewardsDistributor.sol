// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";

/// @title  ReenteringRewardsDistributor — adversarial mock for unbind reentrancy tests
/// @notice Unlike MockRewardsDistributor (which only records calls), this mock pays real ETH
///         to `to` inside settleAndClose via a low-level call — handing execution to the
///         burner mid-unbind exactly like the production distributor's pull payment will.
///         Pair it with an attacker contract whose receive() tries to move the half-unbound
///         NFT or re-enter unbind. Fund it with vm.deal before use.
///         (Added for overseer review 2026-06-11, finding 1; agent 6 should reuse this
///         pattern for system-level unbind tests.)
contract ReenteringRewardsDistributor is IRewardsDistributor {
    /// @notice Flat ETH amount paid to the burner on every settle, standing in for pending
    ///         rewards.
    uint256 public constant SETTLE_PAYOUT = 0.1 ether;

    /// @notice Payout transfer inside settleAndClose failed (mock is unfunded or the
    ///         recipient reverted).
    error SettlePayoutFailed();

    /// @inheritdoc IRewardsDistributor
    function deposit() external payable {}

    /// @inheritdoc IRewardsDistributor
    function register(uint256 tokenId) external {
        emit Registered(tokenId);
    }

    /// @inheritdoc IRewardsDistributor
    /// @dev The low-level call is the whole point: it gives `to` arbitrary execution while
    ///      WordBank._unbind is mid-flight.
    function settleAndClose(uint256 tokenId, address to) external {
        (bool ok,) = to.call{value: SETTLE_PAYOUT}("");
        if (!ok) revert SettlePayoutFailed();
        emit SettledAndClosed(tokenId, to, SETTLE_PAYOUT);
    }

    /// @inheritdoc IRewardsDistributor
    function claimRewards(uint256[] calldata tokenIds) external {}

    /// @inheritdoc IRewardsDistributor
    function pendingRewards(uint256) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IRewardsDistributor
    function accRewardPerNFT() external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}
