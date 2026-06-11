/**
 * Phase 2b — lock the seeded liquidity position in the LPLocker (mirror of
 * script/04_LockLiquidity.s.sol).
 *
 * Carved out of 02-seed-and-launch.ts by the 2026-06-16 change order so the owner controls
 * WHEN liquidity is locked. Run AFTER 02-seed-and-launch.ts has minted the position. Until
 * this runs the position NFT sits UNlocked in the admin wallet — so do NOT publish the
 * LPLocker / lock claim in any announcement until this completes.
 *
 * Does ONLY the old step 5: approve the LPLocker for the position, then lock it. lockedUntil is
 * computed from the LATEST ON-CHAIN block timestamp + LOCK_DURATION_DAYS, with a hard assert
 * that it clears the contract's 365-day MIN_LOCK_DURATION (the client-clock version under-shot
 * and reverted LockTooShort once the tx mined a few seconds later — don't regress that fix).
 *
 * IDEMPOTENT: if lpLocker.locked() is already true it logs "already locked — skip".
 *
 * Env: optional LOCK_DURATION_DAYS (default 366 — a 1-day buffer above MIN_LOCK_DURATION),
 *   POSITION_TOKEN_ID (override/recovery: lock this tokenId instead of the one recorded in
 *   addresses/<network>.json — see RUNBOOK "if something goes wrong").
 * Run:  npx hardhat run scripts/04-lock-liquidity.ts --network <net>
 */
import {ethers, network} from "hardhat";
import {attach, env, getDeploySigner, loadAddresses, saveAddresses} from "./lib";

const POSM_ABI = ["function approve(address to, uint256 tokenId)", "function ownerOf(uint256 tokenId) view returns (address)"];

async function main() {
  const {signer, provider} = getDeploySigner(network);
  const a = loadAddresses(network.name);

  const lockDays = BigInt(env("LOCK_DURATION_DAYS", "366")); // buffer above MIN_LOCK_DURATION (365d)
  const positionOverride = process.env.POSITION_TOKEN_ID?.trim();

  const lpLocker = attach("LPLocker.sol", "LPLocker", a.lpLocker, signer);
  const posm = new ethers.Contract(a.positionManager, POSM_ABI, signer);

  // Idempotent: nothing to do if the locker already holds a position.
  if (await (lpLocker as any).locked()) {
    console.log(`lock: already locked (tokenId ${await (lpLocker as any).tokenId()}) — skip`);
    return;
  }

  // Resolve the position tokenId: explicit override (recovery) else the recorded one (resume).
  let tokenId: bigint;
  if (positionOverride) {
    tokenId = BigInt(positionOverride);
    console.log(`using POSITION_TOKEN_ID override ${tokenId}`);
  } else if (a.positionTokenId) {
    tokenId = BigInt(a.positionTokenId);
    console.log(`using recorded position tokenId ${tokenId}`);
  } else {
    throw new Error(
      "no positionTokenId in addresses/<network>.json — run 02-seed-and-launch.ts first, or pass POSITION_TOKEN_ID=<id>",
    );
  }

  // lockedUntil from the LATEST ON-CHAIN block timestamp + duration, asserted to clear
  // MIN_LOCK_DURATION before sending (the client-clock version under-shot and reverted).
  const blockTs = BigInt((await provider.getBlock("latest"))!.timestamp);
  const minLock = BigInt(await (lpLocker as any).MIN_LOCK_DURATION());
  const lockedUntil = blockTs + lockDays * 86_400n;
  if (lockedUntil <= blockTs + minLock) {
    throw new Error(
      `LOCK_DURATION_DAYS=${lockDays} does not clear MIN_LOCK_DURATION (${minLock}s); raise it above ${minLock / 86_400n} days`,
    );
  }

  console.log(`locking position ${tokenId} until ${new Date(Number(lockedUntil) * 1000).toISOString()}…`);
  await (await posm.approve(a.lpLocker, tokenId)).wait();
  await (await (lpLocker as any).lock(tokenId, lockedUntil)).wait();
  saveAddresses(network.name, {positionTokenId: tokenId.toString(), lockedUntil: lockedUntil.toString()});

  console.log("");
  console.log("Phase 2b complete — liquidity LOCKED.");
  console.log("You can now publish the LPLocker address + lock terms in your launch announcement.");
  console.log("NEXT (when ready): npm run enable-trading  (05-enable-trading.ts) to go live.");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
