// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {LPLocker} from "../src/LPLocker.sol";

/// @title  Phase 2b — lock the seeded liquidity position in the LPLocker
/// @notice Carved out of 02_SeedPoolAndLaunch by the 2026-06-16 change order so the owner
///         controls WHEN liquidity is locked. Run AFTER 02 has minted the position. Until this
///         runs the position NFT sits UNlocked in the admin wallet — do NOT publish the
///         LPLocker / lock claim in any announcement until this completes.
///
///         Does ONLY the old step 5: approve the locker for the position, then lock it.
///         lockedUntil is based on the on-chain block timestamp + LOCK_DURATION, with a buffer
///         above MIN_LOCK_DURATION and a hard assert (the prior client-clock version under-shot
///         and reverted LockTooShort — don't regress that fix).
///
///         IDEMPOTENT: if the locker already holds a position it logs "already locked" and no-ops.
///
///         Required env:
///           LP_LOCKER, POSITION_MANAGER
///           POSITION_TOKEN_ID  the position to lock (a forge script keeps no addresses ledger,
///                              so the id printed by 02 must be supplied here)
///           ADMIN              protocol admin (broadcaster; owns/approves the position)
///         Optional env (defaults):
///           LOCK_DURATION      (366 days — a 1-day buffer above LPLocker.MIN_LOCK_DURATION)
contract LockLiquidity is Script {
    function run() external {
        LPLocker lpLocker = LPLocker(payable(vm.envAddress("LP_LOCKER")));
        address posm = vm.envAddress("POSITION_MANAGER");
        uint256 lockDuration = vm.envOr("LOCK_DURATION", uint256(366 days)); // buffer above MIN (365 days)

        // Idempotent: nothing to do if the locker already holds a position.
        if (lpLocker.locked()) {
            console2.log("lock: already locked - skip. tokenId:", lpLocker.tokenId());
            return;
        }

        uint256 tokenId = vm.envUint("POSITION_TOKEN_ID");
        require(tokenId != 0, "POSITION_TOKEN_ID required (the id 02_SeedPoolAndLaunch printed)");

        uint256 minLock = lpLocker.MIN_LOCK_DURATION();
        uint256 lockedUntil = block.timestamp + lockDuration;
        require(lockedUntil > block.timestamp + minLock, "lock duration must exceed MIN_LOCK_DURATION");

        vm.startBroadcast();
        (bool ok,) = posm.call(abi.encodeWithSignature("approve(address,uint256)", address(lpLocker), tokenId));
        require(ok, "posm approve failed");
        lpLocker.lock(tokenId, lockedUntil);
        vm.stopBroadcast();

        console2.log("Phase 2b complete - liquidity LOCKED. tokenId:", tokenId);
        console2.log("locked until:", lockedUntil);
        console2.log("You can now publish the LPLocker address + lock terms in your announcement.");
        console2.log("NEXT (when ready): 05_EnableTrading to go live.");
    }
}
