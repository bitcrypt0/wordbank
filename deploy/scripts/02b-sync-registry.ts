/**
 * Phase 2.5 — fix the provenance offset and build the game registry (mirror of
 * script/02b_SyncRegistry.s.sol; overseer review M-1).
 *
 * After the 9,800th public mint arms the offset commit, this script:
 *   1. reveals the offset once the target block has passed (or re-arms if the 256-block
 *      window lapsed — then re-run it ~15 blocks later);
 *   2. loops buildRegistry(batch) until registrySynced() is true.
 *
 * ⚠️ ANNOUNCEMENT GATE: do NOT announce or open the daily game before registrySynced()
 * reads true — between the offset reveal and full sync, game reveals would draw from a
 * biased partial registry. (Before the reveal they abort cleanly; after it they're biased.)
 *
 * Env (optional): REGISTRY_BATCH (default 250 tokens per tx).
 * Run:  npx hardhat run scripts/02b-sync-registry.ts --network <net>
 */
import {ethers, network} from "hardhat";
import {attach, env, getDeploySigner, loadAddresses} from "./lib";

const MAX_BUILD_CALLS = 200;
const BLOCKHASH_WINDOW = 256;

async function main() {
  const {signer, provider} = getDeploySigner(network);
  const a = loadAddresses(network.name);
  const bank = attach("WordBank.sol", "WordBank", a.wordBank, signer) as any;
  const batch = BigInt(env("REGISTRY_BATCH", "250"));

  if (await bank.registrySynced()) {
    console.log("Registry already synced — nothing to do. The game may be announced.");
    return;
  }

  if (!(await bank.offsetSet())) {
    const target = await bank.offsetTargetBlock();
    if (target === 0n) throw new Error("offset not armed: the 9,800 public allocation has not sold out yet");
    const current = BigInt(await provider.getBlockNumber());
    if (current <= target) {
      throw new Error(`reveal too early: wait until block ${target + 1n} (current ${current}, ~3 minutes)`);
    }
    if (current > target + BigInt(BLOCKHASH_WINDOW)) {
      console.log("Reveal window lapsed — re-arming…");
      await (await bank.rearmOffset()).wait();
      console.log(`RE-ARMED for block ${await bank.offsetTargetBlock()}. Re-run this script after that block (~3 min).`);
      return;
    }
    console.log("Revealing offset…");
    await (await bank.revealOffset()).wait();
    console.log(`Offset revealed: ${await bank.wordOffset()}`);
  }

  let calls = 0;
  while (!(await bank.registrySynced())) {
    await (await bank.buildRegistry(batch)).wait();
    calls++;
    console.log(`buildRegistry call ${calls}: cursor ${await bank.registryCursor()} / ${await bank.preRevealMinted()}`);
    if (calls > MAX_BUILD_CALLS) throw new Error("exceeded MAX_BUILD_CALLS — raise REGISTRY_BATCH");
  }

  console.log(`Registry built in ${calls} calls. registrySynced() == true.`);
  console.log("THE DAILY GAME MAY NOW BE ANNOUNCED.");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
