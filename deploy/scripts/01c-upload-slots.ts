/**
 * Phase 1.5 (A) — write the 10,000 word/trait slots, then lock with the provenance hash.
 *
 * Slot i ← assignments[i] (the shuffled provenance arrangement from tools/assign_traits.py).
 * Writes contiguous batches via setWordSlots(start, batch), then lockSlots(provenanceHash)
 * where provenanceHash = keccak256 of the exact assets/assignments.json bytes — the public,
 * reproducible snipe-proof commitment. Until locked, openEarlyBird reverts SetupIncomplete.
 *
 * RESUMABLE: ~200 transactions, so it resumes from the on-chain slotsWritten() — re-run after
 * any RPC hiccup. Owner-only → signer must be the WordBank owner (the ADMIN). The per-tokenId
 * offset reveal is the SEPARATE Phase 2.5 step (02b-sync-registry) — this only commits contents.
 *
 * Env: SLOT_BATCH (slots per tx, default 50). Reads/writes addresses/<network>.json.
 * Run: npx hardhat run scripts/01c-upload-slots.ts --network <net>
 */
import {ethers, network} from "hardhat";
import {attach, env, getDeploySigner, loadAddresses, saveAddresses} from "./lib";
import {loadArrangement, requireAuthority, TOTAL_SLOTS} from "./content";

async function main() {
  const {signer} = getDeploySigner(network);
  const a = loadAddresses(network.name);
  const bank = attach("WordBank.sol", "WordBank", a.wordBank, signer);
  const batchSize = Number(env("SLOT_BATCH", "50"));

  requireAuthority(await signer.getAddress(), await (bank as any).owner(), "WordBank owner");

  const {words, provenanceHash} = loadArrangement();
  console.log(`arrangement: ${words.length} slots, provenanceHash ${provenanceHash}`);
  // Record the commitment immediately (it's derived from the public file, independent of chain state).
  saveAddresses(network.name, {provenanceHash});

  if (await (bank as any).slotsLocked()) {
    const onchain = await (bank as any).provenanceHash();
    const match = onchain.toLowerCase() === provenanceHash.toLowerCase();
    console.log(`slots already LOCKED. on-chain provenanceHash ${onchain} ${match ? "== matches file" : "!= FILE MISMATCH"}`);
    if (!match) throw new Error("locked provenanceHash does not match assignments.json — investigate before launch");
    return;
  }

  // Resume from the on-chain written prefix; setWordSlots requires start == slotsWritten (contiguous).
  let start = Number(await (bank as any).slotsWritten());
  console.log(`resuming from slot ${start} (batch ${batchSize})`);
  while (start < TOTAL_SLOTS) {
    const batch = words.slice(start, Math.min(start + batchSize, TOTAL_SLOTS));
    const tx = await (bank as any).setWordSlots(start, batch);
    await tx.wait();
    start += batch.length;
    if (start % (batchSize * 10) === 0 || start === TOTAL_SLOTS) {
      console.log(`  wrote ${start}/${TOTAL_SLOTS} slots`);
    }
  }

  const written = Number(await (bank as any).slotsWritten());
  if (written !== TOTAL_SLOTS) throw new Error(`slotsWritten ${written} != ${TOTAL_SLOTS} after upload`);

  console.log(`locking slots with provenanceHash ${provenanceHash} (irreversible)…`);
  await (await (bank as any).lockSlots(provenanceHash)).wait();
  if (!(await (bank as any).slotsLocked())) throw new Error("lockSlots did not take effect");

  saveAddresses(network.name, {provenanceHash, slotsLocked: true});
  console.log("slots LOCKED. The provenanceHash is the public commitment — publish it with the collection.");
  console.log("NEXT: verify with scripts/verify-content.ts, then the sale (setSaleConfig → openEarlyBird).");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
