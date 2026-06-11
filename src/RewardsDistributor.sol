// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IBountyEngine} from "./interfaces/IBountyEngine.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import {IWordBank} from "./interfaces/IWordBank.sol";

/// @title  RewardsDistributor — equal ETH fee-share across alive word NFTs
/// @notice Splits every ETH deposit (the rewards slice of the 1% swap fee: 50% at launch
///         while buy-and-burn is active, default 70% after burn completion — this contract
///         is agnostic to the slice size) equally across all alive word NFTs using the
///         1e18-scaled rewards-per-share accumulator: O(1) per deposit, O(1) per claim,
///         no loops over holders, no snapshots.
/// @dev    All accounting is keyed by tokenId, never by owner — rewards travel with the
///         NFT (transfers never touch reward state; the claim-time owner collects).
///
///         Zero-alive deposits (documented choice, charter micro-decision): a deposit that
///         arrives while `wordBank.totalAlive() == 0` is HELD AND DEFERRED, never reverted.
///         `deposit()` is on the permissionless fee-routing path (FeeHook.flush, BurnEngine
///         residual sweep) and must be unbrickable; zero-alive is reachable before the first
///         mint registers and, in the terminal case, if every word is ever unbound. Deferred
///         ETH accumulates in `pendingUndistributed` and folds into the next deposit made
///         while at least one token is alive (a zero-value `deposit()` call acts as a
///         permissionless kick). Deferred funds are reserved — the dust sweep cannot touch
///         them. If the collection terminally empties, the buffer simply sits: with zero
///         alive words there are no holders to favor, and no admin path exists by design.
///
///         Entitlement safety: `owedScaled` tracks the aggregate outstanding entitlement in
///         1e18-scaled units. Deposits add exactly what they accrue; claims and settlements
///         subtract the full scaled delta they release (including the sub-wei fraction the
///         floored payout forfeits, which thereby becomes provable dust). The sweep sends
///         only `balance - pendingUndistributed - ceil(owedScaled / 1e18)`, so it can never
///         touch owed funds — system invariant: contract balance always covers the sum of
///         pending entitlements plus the deferred buffer.
contract RewardsDistributor is IRewardsDistributor, ReentrancyGuardTransient {
    // ─────────────────────────────────── types ─────────────────────────────────────────

    /// @notice Lifecycle of a tokenId in this contract. None → Active (register, at mint)
    ///         → Closed (settleAndClose, at unbind). Closed is terminal: no re-registration,
    ///         no accrual, no claim.
    enum TokenStatus {
        None,
        Active,
        Closed
    }

    // ─────────────────────────────────── errors ────────────────────────────────────────

    /// @notice Caller is not the WordBank.
    error NotWordBank();
    /// @notice Zero address given where a real one is required.
    error ZeroAddress();
    /// @notice deposit() called with no value and no deferred buffer to fold.
    error ZeroDeposit();
    /// @notice register() for an id that is already Active or Closed.
    error AlreadyRegistered(uint256 tokenId);
    /// @notice Operation on an id that was never registered.
    error NotRegistered(uint256 tokenId);
    /// @notice Operation on a permanently closed id.
    error TokenClosed(uint256 tokenId);
    /// @notice claimRewards() caller does not own the token.
    error NotTokenOwner(uint256 tokenId);
    /// @notice claimRewards() called with an empty id array.
    error EmptyClaim();
    /// @notice ETH payout failed (recipient reverted or has no payable path).
    error EthTransferFailed(address to, uint256 amount);
    /// @notice sweepDust() found nothing provably sweepable.
    error NoDust();

    // ─────────────────────────────────── events ────────────────────────────────────────

    /// @notice A deposit arrived while totalAlive == 0 and was deferred, not distributed.
    /// @param  from     The depositor.
    /// @param  amount   The value of this call.
    /// @param  buffered Total now held in the deferred buffer (includes prior deferrals).
    event DepositDeferred(address indexed from, uint256 amount, uint256 buffered);

    // ─────────────────────────────────── storage ───────────────────────────────────────

    /// @dev Accumulator scale. 1e18 keeps rounding dust sub-wei per token per deposit even
    ///      at the full 10,000 shares.
    uint256 private constant ACC_PRECISION = 1e18;

    /// @notice The ERC-721 + binding vault. Sole authority for register/settleAndClose and
    ///         the claim-auth + totalAlive oracle.
    IWordBank public immutable wordBank;

    /// @notice BountyEngine treasury — the only place dust can ever be swept to.
    address public immutable bountyTreasury;

    /// @inheritdoc IRewardsDistributor
    uint256 public override accRewardPerNFT;

    /// @notice Per-token accumulator checkpoint: the value of accRewardPerNFT already
    ///         accounted for (paid or never owed). Pending = (acc - debt) / 1e18.
    mapping(uint256 => uint256) public rewardDebt;

    /// @notice Lifecycle status per tokenId.
    mapping(uint256 => TokenStatus) public statusOf;

    /// @notice Aggregate outstanding entitlement, 1e18-scaled. Increases by exactly what
    ///         each deposit accrues; decreases by the full scaled delta each claim/settle
    ///         releases. ceil(owedScaled / 1e18) is the wei reserve the dust sweep honors.
    uint256 public owedScaled;

    /// @notice ETH from deposits that arrived while totalAlive == 0, held for the next
    ///         distribution. Reserved — never sweepable as dust.
    uint256 public pendingUndistributed;

    // ────────────────────────────────── modifiers ──────────────────────────────────────

    modifier onlyWordBank() {
        if (msg.sender != address(wordBank)) revert NotWordBank();
        _;
    }

    // ────────────────────────────────── constructor ────────────────────────────────────

    /// @param wordBank_       The WordBank (immutable; no upgradeability anywhere).
    /// @param bountyTreasury_ The BountyEngine, sink for swept dust (immutable).
    constructor(address wordBank_, address bountyTreasury_) {
        if (wordBank_ == address(0) || bountyTreasury_ == address(0)) revert ZeroAddress();
        wordBank = IWordBank(wordBank_);
        bountyTreasury = bountyTreasury_;
    }

    // ─────────────────────────────────── mutating ──────────────────────────────────────

    /// @inheritdoc IRewardsDistributor
    /// @dev Permissionless; donations are fine. Folds any deferred buffer into this
    ///      distribution. With zero alive tokens the full amount is deferred instead (see
    ///      contract NatSpec). A zero-value call with a non-empty buffer is the
    ///      permissionless kick that distributes a previously deferred buffer.
    function deposit() external payable nonReentrant {
        uint256 amount = msg.value + pendingUndistributed;
        if (amount == 0) revert ZeroDeposit();

        uint256 alive = wordBank.totalAlive();
        if (alive == 0) {
            pendingUndistributed = amount;
            emit DepositDeferred(msg.sender, msg.value, amount);
            return;
        }
        if (pendingUndistributed != 0) pendingUndistributed = 0;

        uint256 perShare = (amount * ACC_PRECISION) / alive;
        accRewardPerNFT += perShare;
        owedScaled += perShare * alive;
        emit Deposited(msg.sender, amount, accRewardPerNFT);
    }

    /// @inheritdoc IRewardsDistributor
    /// @dev Checkpoints debt to the current accumulator so a mid-stream mint cannot claim
    ///      fees that arrived before it existed. Reverts on re-registration and on closed
    ///      ids (burned ids can never be reminted — WordBank's _nextId only grows).
    function register(uint256 tokenId) external onlyWordBank {
        TokenStatus status = statusOf[tokenId];
        if (status == TokenStatus.Active) revert AlreadyRegistered(tokenId);
        if (status == TokenStatus.Closed) revert TokenClosed(tokenId);
        statusOf[tokenId] = TokenStatus.Active;
        rewardDebt[tokenId] = accRewardPerNFT;
        emit Registered(tokenId);
    }

    /// @inheritdoc IRewardsDistributor
    /// @dev WordBank calls this mid-unbind, AFTER burning the NFT but BEFORE the alive
    ///      registry pop (settle-before-decrement, system invariant 3) — so this function
    ///      must not and does not consult ownerOf or totalAlive; `to` is the burner, passed
    ///      explicitly. State is fully settled before the ETH leaves (CEI), and the
    ///      reentrancy guard shared with claimRewards/deposit/sweepDust blocks any reentry
    ///      while totalAlive is still pre-decrement.
    function settleAndClose(uint256 tokenId, address to) external onlyWordBank nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        TokenStatus status = statusOf[tokenId];
        if (status == TokenStatus.None) revert NotRegistered(tokenId);
        if (status == TokenStatus.Closed) revert TokenClosed(tokenId);

        uint256 delta = accRewardPerNFT - rewardDebt[tokenId];
        uint256 payout = delta / ACC_PRECISION;

        statusOf[tokenId] = TokenStatus.Closed;
        rewardDebt[tokenId] = accRewardPerNFT;
        owedScaled -= delta;

        emit SettledAndClosed(tokenId, to, payout);
        if (payout != 0) _pay(to, payout);
    }

    /// @inheritdoc IRewardsDistributor
    /// @dev Reverts the whole batch on any non-owned, unregistered, or closed id — nothing
    ///      is skipped silently. Duplicate ids in one batch pay once (the second occurrence
    ///      has zero delta). Per-token payouts are floored individually so the total paid
    ///      always equals the sum of pendingRewards over the batch. Single ETH transfer at
    ///      the end; all state is final before it (CEI + reentrancy guard).
    function claimRewards(uint256[] calldata tokenIds) external nonReentrant {
        uint256 len = tokenIds.length;
        if (len == 0) revert EmptyClaim();

        uint256 acc = accRewardPerNFT;
        uint256 totalPayout;
        uint256 releasedScaled;

        for (uint256 i = 0; i < len; ++i) {
            uint256 tokenId = tokenIds[i];
            TokenStatus status = statusOf[tokenId];
            if (status == TokenStatus.None) revert NotRegistered(tokenId);
            if (status == TokenStatus.Closed) revert TokenClosed(tokenId);
            if (wordBank.ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);

            uint256 delta = acc - rewardDebt[tokenId];
            uint256 payout = delta / ACC_PRECISION;
            if (delta != 0) {
                rewardDebt[tokenId] = acc;
                releasedScaled += delta;
                totalPayout += payout;
            }
            emit Claimed(tokenId, msg.sender, payout);
        }

        if (releasedScaled != 0) owedScaled -= releasedScaled;
        if (totalPayout != 0) _pay(msg.sender, totalPayout);
    }

    /// @notice Sweeps provable rounding dust to the BountyEngine treasury. Permissionless.
    /// @dev    Dust = balance − deferred buffer − ceil(owedScaled / 1e18). Because the sum
    ///         of floored per-token pendings can never exceed floor(owedScaled / 1e18), the
    ///         ceiling reserve guarantees the sweep never touches owed funds. Forced ETH
    ///         (selfdestruct sends — there is no receive()) lands here too rather than
    ///         being stranded.
    function sweepDust() external nonReentrant {
        uint256 reserved = pendingUndistributed + (owedScaled + ACC_PRECISION - 1) / ACC_PRECISION;
        uint256 balance = address(this).balance;
        if (balance <= reserved) revert NoDust();

        uint256 dust = balance - reserved;
        emit DustSwept(bountyTreasury, dust);
        IBountyEngine(bountyTreasury).deposit{value: dust}();
    }

    // ──────────────────────────────────── views ────────────────────────────────────────

    /// @inheritdoc IRewardsDistributor
    /// @dev Returns 0 for unregistered and closed ids.
    function pendingRewards(uint256 tokenId) external view returns (uint256) {
        if (statusOf[tokenId] != TokenStatus.Active) return 0;
        return (accRewardPerNFT - rewardDebt[tokenId]) / ACC_PRECISION;
    }

    // ─────────────────────────────────── internal ──────────────────────────────────────

    /// @dev ETH out via call (convention: no transfer()); reverts on failure — a recipient
    ///      that cannot receive ETH fails its own claim/unbind only.
    function _pay(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed(to, amount);
    }
}
