// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IBurnEngine — buy-and-burn, the deflationary third fee destination
/// @notice v3 IN PROGRESS (interfaces-v3, 2026-06-13). Do not edit without overseer approval and
///         a tag bump. Lands together with WordToken/IWordToken v3 (agent 1) and the
///         BurnEngine/FeeHook rewire (agent 5).
/// @dev    Implemented by agent 5 (hook-locker — it owns pool-facing infra and the V4 swap
///         expertise this needs). Consumed by:
///           - FeeHook (agent 5): deposit (the burn slice). The FeeHook no longer reads any
///             completion flag from the engine — it picks the fee split per flush from
///             `WordToken.burnableExcess()` directly (dynamic routing, Option B).
///           - Frontend (agent 9): burn progress / supply countdown, executeBuyback button.
///         Holds no NFT, bounty, or rewards logic. Buys WORD on the canonical pool and burns it
///         via WordToken.burn, respecting the DYNAMIC backing floor
///         (`WordBank.totalAlive() × 1000e18`). Buyback runs in its OWN transaction — never
///         inside a swap callback — to avoid reentering the V4 PoolManager.
///
///         v3 change (2026-06-13): the burn floor is dynamic and there is NO permanent
///         completion — burning pauses at the floor and resumes whenever an unbind lowers it.
///         Removed `burnComplete()` and the `BurnEngineRetired` event accordingly.
interface IBurnEngine {
    // ──────────────────────────────────── events ───────────────────────────────────────

    /// @notice ETH arrived (from the FeeHook flush, or anyone — donations are fine).
    event Deposited(address indexed from, uint256 amount);
    /// @notice A buyback executed: `ethSpent` bought `wordBought`, all of which was burned;
    ///         `keeperTip` paid to `caller`.
    event BuybackExecuted(address indexed caller, uint256 ethSpent, uint256 wordBought, uint256 keeperTip);
    /// @notice Admin updated the bounded max-slippage used to derive the buyback min-out.
    event MaxSlippageSet(uint256 bps);

    // ─────────────────────────────────── mutating ──────────────────────────────────────

    /// @notice Accepts ETH to be used for buy-and-burn. Permissionless (FeeHook is the source).
    function deposit() external payable;

    /// @notice Spends accrued ETH to buy WORD on the canonical pool and burn it. Permissionless.
    /// @dev    MUST: size the spend so WORD bought never overshoots `WordToken.burnableExcess()`
    ///         (the live `totalSupply - currentBurnFloor()`); enforce an on-chain slippage guard
    ///         (min-out from pool price within the admin-bounded max-slippage, hardcoded ceiling);
    ///         burn 100% of WORD bought; pay the caller the bounded keeper tip. When there is no
    ///         burnable excess (supply is at the live floor) it cleanly reverts/no-ops; it resumes
    ///         automatically once a later unbind lowers the floor and frees new excess. There is
    ///         no permanent retirement.
    /// @param  maxEthToSpend Caller-supplied upper bound on ETH spent this call (rate-limit /
    ///         price-impact control); the engine spends min(this, its sizing cap, its balance).
    function executeBuyback(uint256 maxEthToSpend) external;

    // ──────────────────────────────────── views ────────────────────────────────────────

    /// @notice ETH currently held and available for buybacks.
    function pendingEth() external view returns (uint256);
}
