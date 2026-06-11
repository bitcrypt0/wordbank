// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

/// @title  LPLocker — timelock vault for the initial WORD/ETH liquidity position
/// @notice Holds the V4 PositionManager position NFT that represents the protocol's seeded
///         liquidity. The lock is set at deposit (minimum 1 year), can be EXTENDED but never
///         shortened, and a one-way `makePermanent()` upgrades it to unwithdrawable forever.
///         During the lock (and forever after) the admin may collect the position's accrued
///         V4 pool fees — these are the pool's LP fees, a legitimate revenue stream distinct
///         from the FeeHook's 1% skim — but can NEVER decrease principal liquidity before
///         expiry. At expiry the position NFT returns to the admin.
///
///         Publishing this contract's address and lock terms at launch is the trust signal
///         the contract exists to provide (architecture §7).
///
/// @dev    Deliberately dumb. The locker can produce exactly two effects at the
///         PositionManager: (1) a fee collection encoded internally as
///         DECREASE_LIQUIDITY(liquidity = 0) + TAKE_PAIR — the zero liquidity delta is
///         hardcoded, so no calldata the admin controls can touch principal; (2) a plain NFT
///         transfer back to the admin, gated on `lockedUntil`. `makePermanent()` is
///         structural, not flag-checked: it sets `lockedUntil = type(uint256).max`, a value
///         `block.timestamp` can never reach and no function can ever lower (extendLock only
///         increases; nothing else writes it).
contract LPLocker is Ownable2Step {
    // ─────────────────────────────────── constants ─────────────────────────────────────

    /// @notice Minimum initial lock duration.
    uint256 public constant MIN_LOCK_DURATION = 365 days;

    /// @notice `lockedUntil` value representing a permanent lock.
    uint256 public constant PERMANENT = type(uint256).max;

    // ──────────────────────────────────── storage ──────────────────────────────────────

    /// @notice The Uniswap V4 PositionManager whose position NFT this vault holds.
    IPositionManager public immutable positionManager;

    /// @notice The locked position's tokenId (meaningful only while `locked` is true).
    uint256 public tokenId;

    /// @notice True while a position is held by the vault.
    bool public locked;

    /// @notice Timestamp before which withdrawal is impossible. `PERMANENT` = forever.
    uint256 public lockedUntil;

    // ──────────────────────────────────── events ───────────────────────────────────────

    /// @notice A position was deposited and locked.
    event PositionLocked(uint256 indexed tokenId, uint256 lockedUntil);
    /// @notice The lock was extended (monotonic).
    event LockExtended(uint256 indexed tokenId, uint256 oldLockedUntil, uint256 newLockedUntil);
    /// @notice The lock was made permanent. Emitted at most once per position; irreversible.
    event LockMadePermanent(uint256 indexed tokenId);
    /// @notice Accrued V4 pool fees were collected to `to`. Principal untouched (structural).
    event FeesCollected(uint256 indexed tokenId, address indexed to);
    /// @notice The lock expired and the position returned to the admin.
    event PositionWithdrawn(uint256 indexed tokenId, address indexed to);

    // ──────────────────────────────────── errors ───────────────────────────────────────

    /// @notice The vault already holds a position.
    error AlreadyLocked();
    /// @notice No position is held.
    error NothingLocked();
    /// @notice Initial lock must be at least MIN_LOCK_DURATION from now.
    error LockTooShort();
    /// @notice extendLock may only increase lockedUntil.
    error LockNotExtended();
    /// @notice The lock is permanent; it cannot be extended further or withdrawn ever.
    error LockIsPermanent();
    /// @notice Withdrawal attempted before expiry.
    error StillLocked(uint256 lockedUntil);
    /// @notice Zero address where a real address is required.
    error ZeroAddress();

    // ───────────────────────────────── construction ────────────────────────────────────

    /// @param posm  The V4 PositionManager.
    /// @param admin The protocol admin: depositor, fee collector, and recipient at expiry.
    constructor(IPositionManager posm, address admin) Ownable(admin) {
        if (address(posm) == address(0)) revert ZeroAddress();
        positionManager = posm;
    }

    /// @notice Receives the ETH side of collected fees in transit to `collectFees`'s `to`
    ///         when the recipient is this contract — never the case in our flows, but native
    ///         currency handling requires the path to exist for TAKE_PAIR refund edge cases.
    receive() external payable {}

    // ──────────────────────────────────── locking ──────────────────────────────────────

    /// @notice Pulls position `tokenId_` from the admin (must be approved) and locks it
    ///         until `lockedUntil_` (≥ 1 year from now).
    function lock(uint256 tokenId_, uint256 lockedUntil_) external onlyOwner {
        if (locked) revert AlreadyLocked();
        if (lockedUntil_ < block.timestamp + MIN_LOCK_DURATION) revert LockTooShort();

        tokenId = tokenId_;
        lockedUntil = lockedUntil_;
        locked = true;

        IERC721(address(positionManager)).transferFrom(msg.sender, address(this), tokenId_);
        emit PositionLocked(tokenId_, lockedUntil_);
    }

    /// @notice Extends the lock. Monotonic: the new expiry must be strictly later. There is
    ///         no path, admin or otherwise, that shortens a lock.
    function extendLock(uint256 newLockedUntil) external onlyOwner {
        if (!locked) revert NothingLocked();
        if (lockedUntil == PERMANENT) revert LockIsPermanent();
        if (newLockedUntil <= lockedUntil) revert LockNotExtended();

        uint256 old = lockedUntil;
        lockedUntil = newLockedUntil;
        emit LockExtended(tokenId, old, newLockedUntil);
    }

    /// @notice One-way upgrade to a permanent lock: the position becomes unwithdrawable by
    ///         anyone, forever, while `collectFees` keeps working forever. Irreversibility is
    ///         structural — `lockedUntil` becomes type(uint256).max and nothing can lower it.
    function makePermanent() external onlyOwner {
        if (!locked) revert NothingLocked();
        if (lockedUntil == PERMANENT) revert LockIsPermanent();

        lockedUntil = PERMANENT;
        emit LockMadePermanent(tokenId);
    }

    // ────────────────────────────────── fee revenue ────────────────────────────────────

    /// @notice Collects the position's accrued V4 pool fees to `to`. Admin-only; works during
    ///         the lock and forever after (including under a permanent lock).
    /// @dev    The DECREASE_LIQUIDITY action is encoded here with a hardcoded zero liquidity
    ///         delta — collecting fees is the ONLY thing this call can do; principal cannot
    ///         be decreased through this path no matter the inputs.
    function collectFees(address to) external onlyOwner {
        if (!locked) revert NothingLocked();
        if (to == address(0)) revert ZeroAddress();

        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, to);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        emit FeesCollected(tokenId, to);
    }

    // ──────────────────────────────────── expiry ───────────────────────────────────────

    /// @notice Returns the position NFT to the admin once the lock has expired. Impossible
    ///         under a permanent lock (`block.timestamp` can never reach type(uint256).max).
    function withdraw() external onlyOwner {
        if (!locked) revert NothingLocked();
        if (block.timestamp < lockedUntil) revert StillLocked(lockedUntil);

        uint256 id = tokenId;
        locked = false;
        tokenId = 0;
        lockedUntil = 0;

        IERC721(address(positionManager)).transferFrom(address(this), owner(), id);
        emit PositionWithdrawn(id, owner());
    }
}
