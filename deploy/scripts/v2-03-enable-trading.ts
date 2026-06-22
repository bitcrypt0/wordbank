/**
 * WORD v2 RELAUNCH — Phase 3: flip trading live on FeeHookV2 (one-time, admin-only).
 *
 * Run this AFTER the pool is seeded (v2-02) and the LP is locked on UNCX. It calls
 * FeeHookV2.enableTrading(), which also starts the 1-hour anti-whale buy-cap window. Idempotent:
 * if trading is already enabled it reports and exits without reverting.
 *
 * Run: npx hardhat run scripts/v2-03-enable-trading.ts --network mainnet
 */
import {network} from "hardhat";
import {attach, getDeploySigner, loadAddresses} from "./lib";

async function main() {
  const {signer} = getDeploySigner(network);
  const a = loadAddresses(network.name);
  if (!a.feeHookV2) throw new Error("missing feeHookV2 — run v2-01-deploy.ts first");

  const hook = attach("FeeHookV2.sol", "FeeHookV2", a.feeHookV2, signer);
  const enabledAt: bigint = await (hook as any).tradingEnabledAt();
  if (enabledAt !== 0n) {
    console.log(`trading already enabled (tradingEnabledAt=${enabledAt}) — nothing to do`);
    return;
  }

  console.log("enabling trading on FeeHookV2…");
  await (await (hook as any).enableTrading()).wait();
  const now: bigint = await (hook as any).tradingEnabledAt();
  console.log(`trading ENABLED at ${now}. Anti-whale buy cap active for ~1 hour (or until sunsetGuard()).`);
  console.log("The WORD/ETH pool is now live. Safe to announce the token + pool address.");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
