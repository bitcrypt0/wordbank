// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBountyEngine} from "./interfaces/IBountyEngine.sol";
import {IBurnEngine} from "./interfaces/IBurnEngine.sol";

/// @dev Minimal canonical-WETH surface this contract needs: unwrap to ETH + balance. Avoids a
///      heavyweight import; WETH9's `withdraw` sends native ETH back via the splitter's
///      `receive()`.
interface IWETH {
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @title  RoyaltySplitter — trustless ERC-2981 royalty receiver, equal-thirds forwarder
/// @notice WordBank's ERC-2981 royalty receiver points here (`setRoyalty(splitter, 300)` at
///         launch — 3%, admin-settable on WordBank, not here). Every ETH/WETH royalty that
///         lands is forwarded in EQUAL THIRDS: 1/3 to the BurnEngine (buy-and-burn), 1/3 to
///         the BountyEngine treasury (prizes), 1/3 to the protocol admin (team). Holders /
///         RewardsDistributor get NO royalty cut — intentional (the 1% swap fee already feeds
///         holders; royalties fund deflation, prizes, and the team). Architecture §8.
///
///         ## What makes it trustless
///         The three destinations AND the equal-thirds weighting are fixed at construction and
///         `immutable` — there are NO setters. Nobody, not even the admin, can re-point or
///         re-weight the split after deploy. ERC-2981 names exactly one receiver address, so a
///         splitting contract with immutable shares is the only way to split royalties
///         trustlessly.
///
///         ## Pull-based, never push-on-receipt (read me, agent 7)
///         `receive()` accepts ETH and does nothing else. A push-split inside `receive()` would
///         couple the marketplace's sale settlement to all three recipients succeeding — one
///         reverting recipient could fail the royalty payment (or the sale itself, depending on
///         the marketplace). Royalties simply ACCRUE here; a permissionless `distribute()`
///         flushes them later. The marketplace's transfer can never revert because of us.
///
///         ## Reentrancy & griefing (read me, agent 7)
///         `distribute()` is `nonReentrant` and reads the distributable balance FRESH each call
///         (net of `pendingAdmin`, see below). The two protocol sinks are paid first via their
///         own `deposit()` (trusted contracts — `deposit` only accrues/emits). The admin slice
///         is then sent by a plain call; **if that call fails it is accrued to `pendingAdmin`
///         instead of reverting**, so a broken or griefing admin recipient can NEVER block the
///         BurnEngine/BountyEngine slices — it can at most delay its OWN slice, which it then
///         pulls via `withdrawAdmin()`. Because `pendingAdmin` is excluded from the
///         distributable balance, a stuck admin slice is never re-split into the protocol sinks
///         (no double-count, no leak).
///
///         ## Admin-rescue trust point (read me, agent 7 — the ONE accepted trust point)
///         Only ETH and WETH auto-split — keeping the automatic path swap-free (no in-contract
///         DEX, oracle, or slippage surface). Royalties paid in an arbitrary ERC-20 (e.g. USDC)
///         cannot be split without a swap, so they sit until the admin-only `rescueToken()`
///         pulls them to the admin. This is the single admin-trust point, accepted by the owner
///         in exchange for a simple, swap-free auto path; ETH/WETH (the overwhelming majority of
///         real royalty volume) always splits trustlessly. `rescueToken` CANNOT touch WETH —
///         otherwise the admin could bypass the trustless WETH split by rescuing it instead.
///
///         Holds no NFT, game, rewards, or burn logic.
contract RoyaltySplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────── immutables ───────────────────────────────────

    /// @notice Buy-and-burn sink — receives 1/3 via its `deposit()`.
    IBurnEngine public immutable burnEngine;
    /// @notice Bounty treasury sink — receives 1/3 via its `deposit()`.
    IBountyEngine public immutable bountyEngine;
    /// @notice Protocol admin — receives 1/3, and the sole `rescueToken` authority.
    address public immutable admin;
    /// @notice Canonical WETH — unwrapped to ETH at the top of `distribute()`.
    IWETH public immutable weth;

    // ──────────────────────────────────── storage ──────────────────────────────────────

    /// @notice Admin's slice(s) whose direct send failed, awaiting `withdrawAdmin()`. Excluded
    ///         from the distributable balance so it is never re-split.
    uint256 public pendingAdmin;

    // ──────────────────────────────────── events ───────────────────────────────────────

    /// @notice A distribution ran: equal thirds (last slice took the rounding remainder).
    event Distributed(address indexed caller, uint256 toBurn, uint256 toBounty, uint256 toAdmin);
    /// @notice The admin's slice could not be sent directly and was accrued for later pull.
    event AdminSlicePending(uint256 amount, uint256 totalPending);
    /// @notice A previously-pending admin slice was withdrawn to the admin.
    event AdminWithdrawn(uint256 amount);
    /// @notice A stray non-ETH ERC-20 was rescued to the admin.
    event TokenRescued(address indexed token, uint256 amount);

    // ──────────────────────────────────── errors ───────────────────────────────────────

    /// @notice Zero address supplied to the constructor.
    error ZeroAddress();
    /// @notice Caller is not the admin.
    error NotAdmin();
    /// @notice distribute() called with no distributable balance.
    error NothingToDistribute();
    /// @notice withdrawAdmin() called with no pending admin slice.
    error NothingPending();
    /// @notice ETH transfer failed.
    error EthTransferFailed();
    /// @notice rescueToken() may not touch WETH — it auto-splits via distribute().
    error CannotRescueWeth();

    // ───────────────────────────────── construction ────────────────────────────────────

    /// @param burnEngine_   The BurnEngine (buy-and-burn) — 1/3.
    /// @param bountyEngine_ The BountyEngine (bounty treasury) — 1/3.
    /// @param admin_        The protocol admin — 1/3, and the rescue authority.
    /// @param weth_         Canonical WETH for the chain.
    constructor(address burnEngine_, address bountyEngine_, address admin_, address weth_) {
        if (burnEngine_ == address(0) || bountyEngine_ == address(0) || admin_ == address(0) || weth_ == address(0)) {
            revert ZeroAddress();
        }
        burnEngine = IBurnEngine(burnEngine_);
        bountyEngine = IBountyEngine(bountyEngine_);
        admin = admin_;
        weth = IWETH(weth_);
    }

    /// @notice Accepts ETH (royalty income, and the unwrap callback from WETH.withdraw) and
    ///         does nothing else. Splitting is deferred to `distribute()` (see contract notes).
    receive() external payable {}

    // ─────────────────────────────────── distribution ──────────────────────────────────

    /// @notice Unwraps any held WETH, then forwards the ETH balance in equal thirds:
    ///         burn / bounty / admin, the admin slice taking the rounding remainder so the
    ///         three sum to exactly the distributed balance. Permissionless.
    /// @dev    See the contract-level notes for the reentrancy and admin-griefing reasoning.
    function distribute() external nonReentrant {
        uint256 wethBal = weth.balanceOf(address(this));
        if (wethBal > 0) weth.withdraw(wethBal); // → ETH into receive()

        // Distributable balance excludes any stuck admin slice (never re-split).
        uint256 bal = address(this).balance - pendingAdmin;
        if (bal == 0) revert NothingToDistribute();

        uint256 toBurn = bal / 3;
        uint256 toBounty = bal / 3;
        uint256 toAdmin = bal - toBurn - toBounty; // remainder → admin; slices sum to `bal`

        // Protocol sinks first — trusted contracts whose deposit() only accrues/emits, so they
        // always succeed and can never be blocked by the admin recipient.
        burnEngine.deposit{value: toBurn}();
        bountyEngine.deposit{value: toBounty}();

        // Admin slice: try a direct send; on failure accrue for a later pull rather than
        // reverting (a broken/griefing admin must not block the two protocol sinks).
        (bool ok,) = admin.call{value: toAdmin}("");
        if (!ok) {
            pendingAdmin += toAdmin;
            emit AdminSlicePending(toAdmin, pendingAdmin);
        }

        emit Distributed(msg.sender, toBurn, toBounty, toAdmin);
    }

    /// @notice Sends a previously-failed admin slice to the admin. Permissionless (the
    ///         destination is the immutable admin); retryable.
    function withdrawAdmin() external nonReentrant {
        uint256 amount = pendingAdmin;
        if (amount == 0) revert NothingPending();
        pendingAdmin = 0;
        (bool ok,) = admin.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit AdminWithdrawn(amount);
    }

    /// @notice ETH that the next `distribute()` would split (balance net of `pendingAdmin`).
    function pendingDistribution() external view returns (uint256) {
        return address(this).balance - pendingAdmin;
    }

    // ───────────────────────────────────── rescue ──────────────────────────────────────

    /// @notice Sweeps the full balance of a non-ETH ERC-20 to the admin. Admin-only; the one
    ///         accepted admin-trust point (see contract notes). MUST NOT touch WETH, which
    ///         auto-splits via `distribute()`.
    function rescueToken(IERC20 token) external {
        if (msg.sender != admin) revert NotAdmin();
        if (address(token) == address(weth)) revert CannotRescueWeth();
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(admin, amount);
        emit TokenRescued(address(token), amount);
    }
}
