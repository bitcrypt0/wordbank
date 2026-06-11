// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";
import {IWordBank} from "../../src/interfaces/IWordBank.sol";

/// @title  MockRewardsDistributor — call-recording stand-in for agent 3's contract
/// @notice Implements the frozen IRewardsDistributor surface with no real accounting.
///         Records enough about each call for WordBank's unit tests to verify the unbind
///         ordering: at settle time it snapshots `isAlive(tokenId)` and `totalAlive()` as
///         seen through IWordBank. Under the reviewed ordering (overseer finding 1: burn
///         first, settle second, decrement after), a correct WordBank yields
///         `wasAliveAtSettle == false` (already burned) while `totalAliveAtSettle` still
///         shows the PRE-decrement count (the substance of system invariant 3).
contract MockRewardsDistributor is IRewardsDistributor {
    /// @notice Snapshot taken inside settleAndClose, proving call ordering.
    struct SettleRecord {
        address to;
        bool wasAliveAtSettle;
        uint256 totalAliveAtSettle;
        uint256 callIndex;
    }

    IWordBank public wordBank;

    mapping(uint256 => bool) public registered;
    mapping(uint256 => bool) public closed;
    uint256 public registerCount;
    uint256 public settleCount;
    mapping(uint256 => SettleRecord) public settleRecords;

    /// @notice Test wiring: tell the mock which WordBank to snapshot during settle.
    function setWordBank(address bank) external {
        wordBank = IWordBank(bank);
    }

    /// @inheritdoc IRewardsDistributor
    function deposit() external payable {
        emit Deposited(msg.sender, msg.value, 0);
    }

    /// @inheritdoc IRewardsDistributor
    function register(uint256 tokenId) external {
        require(!registered[tokenId], "MockRD: re-registration");
        require(!closed[tokenId], "MockRD: closed id");
        registered[tokenId] = true;
        registerCount++;
        emit Registered(tokenId);
    }

    /// @inheritdoc IRewardsDistributor
    function settleAndClose(uint256 tokenId, address to) external {
        require(registered[tokenId], "MockRD: never registered");
        require(!closed[tokenId], "MockRD: already closed");
        closed[tokenId] = true;
        settleCount++;
        settleRecords[tokenId] = SettleRecord({
            to: to,
            wasAliveAtSettle: wordBank.isAlive(tokenId),
            totalAliveAtSettle: wordBank.totalAlive(),
            callIndex: settleCount
        });
        emit SettledAndClosed(tokenId, to, 0);
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
}
