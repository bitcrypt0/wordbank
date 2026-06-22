/**
 * SNAPSHOT + MERKLE GENERATOR for the WORD v2 migration (WordMigrator).
 *
 * Produces the eligibility set and Merkle root for the one-way old→new WORD migration:
 *   • Snapshots every old-WORD holder AT A FIXED BLOCK (default 25,372,162 — locked the day the
 *     migration was decided, before it was public, so nobody can farm it by buying old WORD).
 *   • EXCLUDES contracts (code at the snapshot block), the zero/dead addresses, the WordBank
 *     (NFT backing) and the V4 PoolManager (pool liquidity). The admin EOA is INCLUDED
 *     (owner decision).
 *   • Allocates a FIXED reserve of new WORD pro-rata to each holder's snapshot balance:
 *       newAmount_i = floor(oldBalance_i * MIGRATION_RESERVE / totalEligibleOld)
 *     so the sum is ≤ MIGRATION_RESERVE (default 300,000e18). Holders whose floored allocation
 *     is 0 (dust) are dropped.
 *   • Emits the Merkle root (OpenZeppelin StandardMerkleTree, leaf = (address,uint256,uint256) =
 *     (holder, oldSnapshotBalance, newAmount)) and per-holder proofs.
 *
 * The WordMigrator is funded with EXACTLY the printed `reserveUsed` (≤ 300,000); the LP seed
 * premint is then `1,000,000e18 − reserveUsed`.
 *
 * Requires an ARCHIVE RPC (historical balanceOf/getCode) — set MAINNET_RPC_URL to your Alchemy
 * (or other archive) endpoint in deploy/.env. Install the tree lib first:  npm i @openzeppelin/merkle-tree
 *
 * Run:  npx hardhat run scripts/snapshot-merkle.ts --network mainnet
 * Out:  deploy/snapshots/word-migration-<block>.json   (root, reserveUsed, ratio, claims+proofs)
 */
import {ethers, network} from "hardhat";
import * as fs from "fs";
import * as path from "path";
// Loaded via require so this script's typecheck doesn't hard-fail before the dep is installed.
// Install it first:  npm i @openzeppelin/merkle-tree
// eslint-disable-next-line @typescript-eslint/no-var-requires
const {StandardMerkleTree} = require("@openzeppelin/merkle-tree");

// ── config (env-overridable) ───────────────────────────────────────────────────────────────
const OLD_WORD = process.env.OLD_WORD ?? "0x7c1061A9198571df11D26d48d4d3899F0Ab1831a";
const SNAPSHOT_BLOCK = BigInt(process.env.SNAPSHOT_BLOCK ?? "25372162");
// Old WORD first appeared at ~25,330,799 (first mint); scan a little before to be safe.
const FROM_BLOCK = BigInt(process.env.SNAPSHOT_FROM_BLOCK ?? "25330000");
const MIGRATION_RESERVE = BigInt(process.env.MIGRATION_RESERVE ?? (300_000n * 10n ** 18n).toString());
const LOG_CHUNK = BigInt(process.env.LOG_CHUNK ?? "5000");

// Always-excluded addresses (contracts are auto-excluded by code check; these are belt-and-braces).
const EXCLUDE = new Set(
  [
    "0x0000000000000000000000000000000000000000", // zero
    "0x000000000000000000000000000000000000dEaD", // dead
    "0x63a92C4E448847c906b7657C20630650e6bA1218", // WordBank (NFT backing)
    "0x000000000004444c5dc75cB358380D2e3dE08A90", // V4 PoolManager (pool liquidity)
  ].map((a) => a.toLowerCase()),
);

const TRANSFER_TOPIC = ethers.id("Transfer(address,address,uint256)");
const ERC20_ABI = ["function balanceOf(address) view returns (uint256)"];

async function main() {
  const provider = ethers.provider;
  const net = network.name;
  console.log(`snapshot @ block ${SNAPSHOT_BLOCK} on ${net}, reserve ${MIGRATION_RESERVE} wei`);

  // 1) Collect every address that ever sent/received old WORD (chunked getLogs).
  const holders = new Set<string>();
  for (let lo = FROM_BLOCK; lo <= SNAPSHOT_BLOCK; lo += LOG_CHUNK + 1n) {
    const hi = lo + LOG_CHUNK > SNAPSHOT_BLOCK ? SNAPSHOT_BLOCK : lo + LOG_CHUNK;
    const logs = await provider.getLogs({
      address: OLD_WORD,
      topics: [TRANSFER_TOPIC],
      fromBlock: Number(lo),
      toBlock: Number(hi),
    });
    for (const log of logs) {
      // topics[1] = from, topics[2] = to (last 20 bytes of the 32-byte word).
      holders.add(ethers.getAddress("0x" + log.topics[1].slice(26)));
      holders.add(ethers.getAddress("0x" + log.topics[2].slice(26)));
    }
    console.log(`  scanned ${lo}-${hi}: ${holders.size} unique addresses so far`);
  }

  // 2) Keep only EOAs with a non-zero balance at the snapshot block.
  const old = new ethers.Contract(OLD_WORD, ERC20_ABI, provider);
  const blockTag = Number(SNAPSHOT_BLOCK);
  const eligible: {addr: string; bal: bigint}[] = [];
  const list = [...holders];
  for (let i = 0; i < list.length; i += 25) {
    const batch = list.slice(i, i + 25);
    const results = await Promise.all(
      batch.map(async (addr) => {
        if (EXCLUDE.has(addr.toLowerCase())) return null;
        const code = await provider.getCode(addr, blockTag);
        if (code && code !== "0x") return null; // contract — excluded
        const bal: bigint = await old.balanceOf(addr, {blockTag});
        return bal > 0n ? {addr, bal} : null;
      }),
    );
    for (const r of results) if (r) eligible.push(r);
    console.log(`  checked ${Math.min(i + 25, list.length)}/${list.length}, eligible ${eligible.length}`);
  }

  const totalEligible = eligible.reduce((s, e) => s + e.bal, 0n);
  if (totalEligible === 0n) throw new Error("no eligible holders found");

  // 3) Pro-rata allocation (floored); drop dust (0-allocation) holders.
  const leaves: [string, string, string][] = [];
  let reserveUsed = 0n;
  const claims: Record<string, {oldAmount: string; newAmount: string; proof: string[]}> = {};
  for (const {addr, bal} of eligible) {
    const newAmount = (bal * MIGRATION_RESERVE) / totalEligible; // floor
    if (newAmount === 0n) continue;
    leaves.push([addr, bal.toString(), newAmount.toString()]);
    reserveUsed += newAmount;
    claims[addr] = {oldAmount: bal.toString(), newAmount: newAmount.toString(), proof: []};
  }

  // 4) Build the OZ StandardMerkleTree and attach proofs.
  const tree = StandardMerkleTree.of(leaves, ["address", "uint256", "uint256"]);
  for (const [i, leaf] of tree.entries()) {
    const addr = leaf[0];
    claims[addr].proof = tree.getProof(i);
  }

  const out = {
    network: net,
    oldWord: OLD_WORD,
    snapshotBlock: SNAPSHOT_BLOCK.toString(),
    migrationReserve: MIGRATION_RESERVE.toString(),
    totalEligibleOld: totalEligible.toString(),
    reserveUsed: reserveUsed.toString(),
    lpPremint: (1_000_000n * 10n ** 18n - reserveUsed).toString(),
    holders: leaves.length,
    root: tree.root,
    claims,
  };

  const dir = path.join(__dirname, "..", "snapshots");
  fs.mkdirSync(dir, {recursive: true});
  const file = path.join(dir, `word-migration-${SNAPSHOT_BLOCK}.json`);
  fs.writeFileSync(file, JSON.stringify(out, null, 2));

  console.log("");
  console.log("Snapshot complete:");
  console.log(`  eligible holders     ${leaves.length}`);
  console.log(`  total eligible old   ${ethers.formatEther(totalEligible)} WORD`);
  console.log(`  reserve used (new)   ${ethers.formatEther(reserveUsed)} WORD  (cap ${ethers.formatEther(MIGRATION_RESERVE)})`);
  console.log(`  LP premint (new)     ${ethers.formatEther(out.lpPremint)} WORD`);
  console.log(`  merkle root          ${tree.root}`);
  console.log(`  written              ${file}`);
  console.log("");
  console.log("NEXT: deploy WordMigrator with this root, fund it with `reserveUsed` new WORD,");
  console.log("      seed the pool with `lpPremint` new WORD + your ETH.");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
