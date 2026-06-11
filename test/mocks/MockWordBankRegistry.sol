// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IWordBank} from "../../src/interfaces/IWordBank.sol";
import {Category} from "../../src/interfaces/Types.sol";

/// @title  MockWordBankRegistry — full IWordBank with controllable category populations
/// @notice Built for BountyEngine unit tests (agent 4). Unlike MockWordBank (agent 3's
///         distributor-focused mock), this one implements the real category-indexed alive
///         registry — dense per-category arrays with swap-and-pop removal — exactly the
///         production shape the BountyEngine's sentence generation iterates via
///         aliveCount/aliveAt. Tests drive populations per category to exercise template
///         feasibility, dedup with tiny populations, and the burned-word claim path.
/// @dev    Permissionless drivers; auth is not under test here. `wordOf` keeps working for
///         burned ids (frozen IWordBank guarantee: burned words still appear in historical
///         SentenceGenerated events); `ownerOf` reverts for them (ERC-721 semantics the
///         BountyEngine's claim auth relies on).
contract MockWordBankRegistry is IWordBank {
    error NonexistentToken(uint256 tokenId);
    error AlreadyMinted(uint256 tokenId);
    error IndexOutOfBounds(Category category, uint256 index);

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    /// @dev Ever-minted flag; stays true after unbind so ids can never be reminted and
    ///      wordOf/categoryOf keep answering for burned ids.
    mapping(uint256 => bool) private _minted;
    mapping(uint256 => string) private _words;
    mapping(uint256 => Category) private _categories;

    mapping(Category => uint256[]) private _aliveByCategory;
    mapping(uint256 => uint256) private _indexInCategory;
    uint256 private _totalAlive;

    /// @dev SPEC-3 gate flag, consumed by BountyEngine.commit via the IRegistrySync local
    ///      interface. Defaults to true: the mock's registry is always eagerly built, so the
    ///      synced state is the accurate default — only the gate test flips it off.
    bool private _registrySynced = true;

    // ─────────────────────────────────── drivers ───────────────────────────────────────

    /// @notice Test wiring for the SPEC-3 game-start gate.
    function setRegistrySynced(bool synced) external {
        _registrySynced = synced;
    }

    /// @notice Mirrors WordBank's registry-sync flag (true once aliveByCategory is fully
    ///         built post-provenance-reveal).
    function registrySynced() external view returns (bool) {
        return _registrySynced;
    }

    /// @notice Mints a word into the alive registry, mirroring the production mint core
    ///         sequence (push to category array, record index).
    function mint(uint256 tokenId, Category category, string calldata word, address to) external {
        if (_minted[tokenId]) revert AlreadyMinted(tokenId);
        _minted[tokenId] = true;
        _owners[tokenId] = to;
        _balances[to] += 1;
        _words[tokenId] = word;
        _categories[tokenId] = category;
        _indexInCategory[tokenId] = _aliveByCategory[category].length;
        _aliveByCategory[category].push(tokenId);
        _totalAlive += 1;
    }

    /// @notice Unbinds (burns) a word: swap-and-pop from its category array, O(1), exactly
    ///         the production registry removal. ownerOf reverts from here on; wordOf keeps
    ///         working.
    function unbind(uint256 tokenId) external {
        address owner = _owners[tokenId];
        if (owner == address(0)) revert NonexistentToken(tokenId);

        Category category = _categories[tokenId];
        uint256[] storage arr = _aliveByCategory[category];
        uint256 idx = _indexInCategory[tokenId];
        uint256 lastId = arr[arr.length - 1];
        arr[idx] = lastId;
        _indexInCategory[lastId] = idx;
        arr.pop();
        delete _indexInCategory[tokenId];

        _owners[tokenId] = address(0);
        _balances[owner] -= 1;
        _totalAlive -= 1;
    }

    /// @notice Bare ERC-721-style transfer for claim-time-ownership tests. Touches no
    ///         registry state — bounty shares travel with the NFT.
    function transfer(uint256 tokenId, address to) external {
        address from = _owners[tokenId];
        if (from == address(0)) revert NonexistentToken(tokenId);
        _owners[tokenId] = to;
        _balances[from] -= 1;
        _balances[to] += 1;
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
    function wordOf(uint256 tokenId) external view returns (string memory) {
        if (!_minted[tokenId]) revert NonexistentToken(tokenId);
        return _words[tokenId];
    }

    /// @inheritdoc IWordBank
    function categoryOf(uint256 tokenId) external view returns (Category) {
        if (!_minted[tokenId]) revert NonexistentToken(tokenId);
        return _categories[tokenId];
    }

    /// @inheritdoc IWordBank
    function aliveCount(Category category) external view returns (uint256) {
        return _aliveByCategory[category].length;
    }

    /// @inheritdoc IWordBank
    function aliveAt(Category category, uint256 index) external view returns (uint256 tokenId) {
        uint256[] storage arr = _aliveByCategory[category];
        if (index >= arr.length) revert IndexOutOfBounds(category, index);
        return arr[index];
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
}
