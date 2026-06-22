// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title  WordMigrator — fair one-way migration from the old WORD to the relaunch WORD
/// @author WORDBANK — https://wordbank.fun
/// @notice Lets holders captured in a fixed off-chain snapshot convert old WORD to new WORD by
///         BURNING their old balance (sent to a dead address — the old `burn()` is burner-gated,
///         so a dead-address transfer is the available sink) in exchange for a pro-rata share of
///         a fixed new-WORD reserve this contract holds.
///
///         Eligibility + amounts are fixed by a Merkle root over the snapshot (EOA holders only,
///         contracts excluded), so this contract stores no per-holder data and cannot be gamed:
///         buying old WORD after the snapshot grants nothing (entitlements are capped by the
///         proof), and selling it forfeits the claim (you must still hold your snapshot amount to
///         burn it).
///
/// @dev    NO DEADLINE and NO ADMIN — by owner decision the migration is open in perpetuity and
///         fully autonomous. The reserve is the holders' rightful allocation: there is no sweep,
///         recovery, or owner that can withdraw it. Anything never claimed simply stays claimable
///         here forever. The new token keeps its fixed 1,000,000 supply (this reserve is part of
///         it, premined to this contract at deploy); no minting is involved.
///
///         Leaf format (OpenZeppelin StandardMerkleTree convention, double-hashed to resist
///         second-preimage): `keccak256(bytes.concat(keccak256(abi.encode(account, oldAmount,
///         newAmount))))`. The snapshot generator MUST emit the same encoding.
contract WordMigrator is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Where burned old WORD goes. The old token blocks transfers to address(0) but not
    ///         to this conventional dead address, so balances sent here are out of circulation
    ///         permanently. (The old `burn()` is restricted to its BurnEngine, so it can't be used.)
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice The deprecated WORD token being migrated FROM.
    IERC20 public immutable oldToken;
    /// @notice The relaunch WORD token being migrated TO (this contract holds the reserve).
    IERC20 public immutable newToken;
    /// @notice Merkle root over the snapshot leaves (account, oldAmount, newAmount).
    bytes32 public immutable merkleRoot;

    /// @notice True once an account has migrated (one claim per snapshot address).
    mapping(address => bool) public claimed;

    /// @notice Total new WORD handed out so far (for observability; ≤ the seeded reserve).
    uint256 public totalMigrated;

    /// @notice A holder migrated: burned `oldAmount` old WORD, received `newAmount` new WORD.
    event Migrated(address indexed account, uint256 oldAmount, uint256 newAmount);

    /// @notice Zero address given where a real one is required.
    error ZeroAddress();
    /// @notice This account has already migrated.
    error AlreadyClaimed();
    /// @notice The (account, oldAmount, newAmount) leaf is not in the snapshot.
    error InvalidProof();

    /// @param oldToken_   The deprecated WORD token.
    /// @param newToken_   The relaunch WORD token (this contract must be funded with the reserve).
    /// @param merkleRoot_ Root over the snapshot leaves.
    constructor(address oldToken_, address newToken_, bytes32 merkleRoot_) {
        if (oldToken_ == address(0) || newToken_ == address(0)) revert ZeroAddress();
        oldToken = IERC20(oldToken_);
        newToken = IERC20(newToken_);
        merkleRoot = merkleRoot_;
    }

    /// @notice Migrate: burn your snapshot old-WORD balance and receive your new-WORD allocation.
    ///         The caller must currently hold ≥ `oldAmount` old WORD and have approved this
    ///         contract for it. Both `oldAmount` (your snapshot balance) and `newAmount` (your
    ///         pro-rata allocation) are fixed by the proof and cannot be altered.
    /// @param  oldAmount The snapshot old-WORD balance to burn (the exact leaf value).
    /// @param  newAmount The new-WORD allocation to receive (the exact leaf value).
    /// @param  proof     Merkle proof for `keccak256(keccak256(abi.encode(msg.sender, oldAmount,
    ///                   newAmount)))`.
    function claim(uint256 oldAmount, uint256 newAmount, bytes32[] calldata proof) external nonReentrant {
        if (claimed[msg.sender]) revert AlreadyClaimed();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, oldAmount, newAmount))));
        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leaf)) revert InvalidProof();

        // Effects before interactions (CEI) — the guard is belt-and-suspenders on top.
        claimed[msg.sender] = true;
        totalMigrated += newAmount;

        emit Migrated(msg.sender, oldAmount, newAmount);

        // Burn the old (pull to the dead address; caller must hold + approve oldAmount), then
        // deliver the new from this contract's reserve. Both tokens are trusted vanilla ERC-20s.
        oldToken.safeTransferFrom(msg.sender, DEAD, oldAmount);
        newToken.safeTransfer(msg.sender, newAmount);
    }
}
