// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";
import {IWordBank} from "../../src/interfaces/IWordBank.sol";
import {Category} from "../../src/interfaces/Types.sol";

/// @title  MockWordBank — minimal IWordBank for RewardsDistributor unit tests (agent 3)
/// @notice Implements exactly the surface the distributor consumes (ownerOf, totalAlive)
///         plus mint/transfer/unbind drivers that mirror the production WordBank's
///         interaction pattern. Critically, `unbind` reproduces the production ordering
///         (WordBank._unbind, overseer finding 1): (1) burn — ownerOf reverts from here on,
///         (2) settleAndClose on the distributor while totalAlive is still PRE-decrement,
///         (3) decrement totalAlive. Tests that rely on settle-before-decrement semantics
///         exercise the real call shape through this mock.
/// @dev    Permissionless drivers; auth is not what is under test here. Word metadata
///         views are stubs — the distributor must never read them (system invariant 6).
contract MockWordBank is IWordBank {
    error NonexistentToken(uint256 tokenId);
    error AlreadyMinted(uint256 tokenId);
    error DistributorNotSet();
    error AliveAtUnsupported();

    IRewardsDistributor public distributor;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    /// @dev Ever-minted flag; stays true after burn so ids can never be reminted,
    ///      matching the production "_nextId only grows" guarantee.
    mapping(uint256 => bool) private _minted;
    uint256 private _totalAlive;

    /// @notice Test wiring: the distributor to register/settle against.
    function setDistributor(address distributor_) external {
        distributor = IRewardsDistributor(distributor_);
    }

    // ─────────────────────────────────── drivers ───────────────────────────────────────

    /// @notice Mints `tokenId` to `to` and registers it with the distributor, like the
    ///         production mint core sequence.
    function mint(uint256 tokenId, address to) external {
        if (address(distributor) == address(0)) revert DistributorNotSet();
        if (_minted[tokenId]) revert AlreadyMinted(tokenId);
        _minted[tokenId] = true;
        _owners[tokenId] = to;
        _balances[to] += 1;
        _totalAlive += 1;
        distributor.register(tokenId);
    }

    /// @notice Bare ERC-721-style transfer. Deliberately touches NO reward state —
    ///         rewards travel with the NFT.
    function transfer(uint256 tokenId, address to) external {
        address from = _owners[tokenId];
        if (from == address(0)) revert NonexistentToken(tokenId);
        _owners[tokenId] = to;
        _balances[from] -= 1;
        _balances[to] += 1;
    }

    /// @notice Unbinds in the exact production order: burn → settle (pre-decrement) →
    ///         decrement. Settlement pays the owner at unbind time, as in WordBank where
    ///         the burner is msg.sender.
    function unbind(uint256 tokenId) external {
        address owner = _owners[tokenId];
        if (owner == address(0)) revert NonexistentToken(tokenId);

        // 1. burn — ownerOf reverts from here; transfer surface closed.
        _owners[tokenId] = address(0);
        _balances[owner] -= 1;

        // 2. force-settle while totalAlive is still the pre-decrement count.
        distributor.settleAndClose(tokenId, owner);

        // 3. decrement.
        _totalAlive -= 1;
    }

    // ──────────────────────────── IWordBank views ───────────────────────────────────────

    /// @inheritdoc IWordBank
    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        if (owner == address(0)) revert NonexistentToken(tokenId);
        return owner;
    }

    /// @inheritdoc IWordBank
    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    /// @inheritdoc IWordBank
    function totalAlive() external view returns (uint256) {
        return _totalAlive;
    }

    /// @inheritdoc IWordBank
    function isAlive(uint256 tokenId) external view returns (bool) {
        return _owners[tokenId] != address(0);
    }

    /// @inheritdoc IWordBank
    function bondedBalance(uint256 tokenId) external view returns (uint256) {
        return _owners[tokenId] != address(0) ? 1000e18 : 0;
    }

    /// @inheritdoc IWordBank
    /// @dev Stub — the distributor must never read word metadata.
    function wordOf(uint256) external pure returns (string memory) {
        return "";
    }

    /// @inheritdoc IWordBank
    /// @dev Stub — every mock word is a NOUN; the distributor must never read this.
    function categoryOf(uint256) external pure returns (Category) {
        return Category.NOUN;
    }

    /// @inheritdoc IWordBank
    /// @dev Stub: the whole mock collection counts as NOUN.
    function aliveCount(Category category) external view returns (uint256) {
        return category == Category.NOUN ? _totalAlive : 0;
    }

    /// @inheritdoc IWordBank
    /// @dev Stub — dense-array iteration is not part of the distributor's surface.
    function aliveAt(Category, uint256) external pure returns (uint256) {
        revert AliveAtUnsupported();
    }
}
