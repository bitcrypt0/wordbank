/**
 * Phase 2c — enable trading on the FeeHook (mirror of script/05_EnableTrading.s.sol).
 *
 * Carved out of 02-seed-and-launch.ts by the 2026-06-16 change order so the owner controls
 * WHEN the market opens. Run AFTER 02-seed-and-launch.ts (and, recommended, after
 * 04-lock-liquidity.ts so liquidity is provably locked the moment people can trade).
 *
 * Does ONLY the old step 7: feeHook.enableTrading(). One-way — there is no off switch. From
 * this moment swaps work; the anti-whale guard dies at the earlier of sunsetGuard() or +1 hour.
 *
 * HONEYPOT WINDOW: until this runs the pool exists but swaps are gated, so honeypot scanners
 * report "cannot buy/sell" — do NOT announce the token/pool address until AFTER this completes.
 *
 * SANITY CHECKS before flipping (clear revert if the seed wasn't run): the pool must be
 * initialized and burnEngine.poolSet() must be true.
 *
 * IDEMPOTENT: if feeHook.tradingEnabledAt() != 0 it logs "already live — skip".
 *
 * Run:  npx hardhat run scripts/05-enable-trading.ts --network <net>
 */
import {ethers, network} from "hardhat";
import type {Contract} from "ethers";
import {POOL_KEY_TUPLE, attach, coder, getDeploySigner, loadAddresses} from "./lib";

const POOL_MANAGER_ABI = ["function extsload(bytes32 slot) view returns (bytes32)"];
const MASK_160 = (1n << 160n) - 1n;
const POOLS_SLOT = "0x0000000000000000000000000000000000000000000000000000000000000006"; // StateLibrary.POOLS_SLOT

/** True if the canonical pool already has a non-zero sqrtPrice (i.e. it is initialized). */
async function poolInitialized(poolManager: Contract, key: any): Promise<boolean> {
  const poolId = ethers.keccak256(coder.encode([POOL_KEY_TUPLE], [key]));
  const stateSlot = ethers.keccak256(ethers.concat([poolId, POOLS_SLOT]));
  const slot0 = await poolManager.extsload(stateSlot);
  return (BigInt(slot0) & MASK_160) !== 0n;
}

async function main() {
  const {signer} = getDeploySigner(network);
  const a = loadAddresses(network.name);

  const feeHook = attach("FeeHook.sol", "FeeHook", a.feeHook, signer);
  const burnEngine = attach("BurnEngine.sol", "BurnEngine", a.burnEngine, signer);
  const poolManager = new ethers.Contract(a.poolManager, POOL_MANAGER_ABI, signer);

  const key = {
    currency0: ethers.ZeroAddress, // native ETH always sorts first
    currency1: a.wordToken,
    fee: a.lpFee,
    tickSpacing: a.tickSpacing,
    hooks: a.feeHook,
  };

  // Idempotent: nothing to do if trading is already live.
  if ((await (feeHook as any).tradingEnabledAt()) != 0n) {
    console.log("enableTrading: trading already live — skip");
    return;
  }

  // Sanity-check the seed ran: pool initialized + BurnEngine wired. Clear errors beat a deep revert.
  if (!(await poolInitialized(poolManager, key))) {
    throw new Error("pool is not initialized — run 02-seed-and-launch.ts (Phase 2a) first");
  }
  if (!(await (burnEngine as any).poolSet())) {
    throw new Error("BurnEngine pool not set — run 02-seed-and-launch.ts (Phase 2a) first");
  }

  console.log("enabling trading…");
  await (await (feeHook as any).enableTrading()).wait();

  console.log("");
  console.log("Phase 2c complete — TRADING IS LIVE.");
  console.log("Anti-whale guard rejects single buys > 10,000 WORD; it dies at the earlier of");
  console.log("sunsetGuard() or +1 hour. The 1% fee skim is live (50% holders / 25% bounty / 25% burn).");
  console.log("Anyone can now call FeeHook.flush(). NOTE: buy-and-burn (executeBuyback) only");
  console.log("activates at Phase 3 (the seal) — keepers calling it earlier just waste gas.");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
