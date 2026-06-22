/**
 * WORD v2 RELAUNCH — Phase 1: deploy the new contracts.
 *
 * Deploys WordTokenV2 (1,000,000 fixed, minted to the deployer), WordStaking, WordMigrator
 * (seeded with the snapshot Merkle root), and FeeHookV2 (CREATE2 at a flag-mined address). It
 * REUSES the existing RewardsDistributor + BountyEngine (read from addresses/<network>.json) —
 * the NFTs keep earning untouched. Finally it funds the migrator with the snapshot's
 * `reserveUsed` new WORD; the deployer keeps the rest (`lpPremint`) for the pool seed.
 *
 * Writes v2-prefixed keys ALONGSIDE the live v1 addresses (saveAddresses merges — it never
 * overwrites wordBank/rewardsDistributor/etc.).
 *
 * PREREQ: run snapshot-merkle.ts first to produce deploy/snapshots/word-migration-<block>.json.
 * RESUMABLE: each deploy is skipped if already recorded with code on-chain.
 *
 * Env: ADMIN (default deployer), POOL_MANAGER + LP_FEE + TICK_SPACING (reused from v1 if set in
 *   the addresses file), SNAPSHOT_FILE (default the newest deploy/snapshots/word-migration-*.json).
 * Run: npx hardhat run scripts/v2-01-deploy.ts --network mainnet
 */
import {network} from "hardhat";
import {ethers} from "ethers";
import * as fs from "fs";
import * as path from "path";
import {
  attach,
  coder,
  deployViaCreate2,
  env,
  factory,
  getDeploySigner,
  loadAddresses,
  loadAddressesOrEmpty,
  mineHookSalt,
  saveAddresses,
} from "./lib";

/** Find the snapshot JSON (explicit SNAPSHOT_FILE, else newest in deploy/snapshots/). */
function loadSnapshot(): {root: string; reserveUsed: string; lpPremint: string; snapshotBlock: string} {
  const explicit = process.env.SNAPSHOT_FILE?.trim();
  let file = explicit;
  if (!file) {
    const dir = path.join(__dirname, "..", "snapshots");
    const found = fs.existsSync(dir)
      ? fs.readdirSync(dir).filter((f) => f.startsWith("word-migration-") && f.endsWith(".json")).sort()
      : [];
    if (found.length === 0) {
      throw new Error("no snapshot file — run scripts/snapshot-merkle.ts first (or set SNAPSHOT_FILE)");
    }
    file = path.join(dir, found[found.length - 1]);
  }
  const s = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!s.root || !s.reserveUsed) throw new Error(`snapshot ${file} missing root/reserveUsed`);
  console.log(`snapshot: ${file}  (block ${s.snapshotBlock}, root ${s.root})`);
  return s;
}

async function main() {
  const {signer, provider} = getDeploySigner(network);
  const net = network.name;
  const deployer = await signer.getAddress();
  const a = loadAddresses(net); // v1 addresses (must exist) — we reuse rewards/bounty/old token

  const admin = env("ADMIN", deployer);
  const poolManager = env("POOL_MANAGER", a.poolManager);
  const lpFee = Number(env("LP_FEE", String(a.lpFee ?? 3000)));
  const tickSpacing = Number(env("TICK_SPACING", String(a.tickSpacing ?? 60)));
  const oldWord = a.wordToken as string;
  const rewardsDistributor = a.rewardsDistributor as string;
  const bountyEngine = a.bountyEngine as string;
  for (const [k, v] of Object.entries({poolManager, oldWord, rewardsDistributor, bountyEngine})) {
    if (!v) throw new Error(`missing ${k} in addresses/${net}.json (run v1 deploy / sync first)`);
  }

  const snap = loadSnapshot();
  const reserveUsed = BigInt(snap.reserveUsed);

  console.log(`deployer ${deployer}  admin ${admin}  network ${net}`);

  const addrs = loadAddressesOrEmpty(net);
  const deployAndWait = async (file: string, name: string, args: unknown[]): Promise<string> => {
    const c = await factory(file, name, signer).deploy(...args);
    await c.waitForDeployment();
    return c.getAddress();
  };
  const deployOrReuse = async (key: string, label: string, deploy: () => Promise<string>): Promise<string> => {
    if (addrs[key] && (await provider.getCode(addrs[key])) !== "0x") {
      console.log(`${label}: already at ${addrs[key]} — skip`);
      return addrs[key];
    }
    const addr = await deploy();
    addrs[key] = addr;
    saveAddresses(net, {[key]: addr});
    console.log(`${label}: ${addr}`);
    return addr;
  };

  // 1. WordTokenV2 — fixed 1,000,000 minted to the deployer (who then funds the migrator + LP).
  const wordTokenV2 = await deployOrReuse("wordTokenV2", "WordTokenV2", () =>
    deployAndWait("WordTokenV2.sol", "WordTokenV2", [deployer]),
  );

  // 2. WordStaking — stake WORD, earn ETH (the token-side 50% of the fee).
  const wordStaking = await deployOrReuse("wordStaking", "WordStaking", () =>
    deployAndWait("WordStaking.sol", "WordStaking", [wordTokenV2]),
  );

  // 3. WordMigrator — burn old WORD → claim new, gated by the snapshot Merkle root.
  const wordMigrator = await deployOrReuse("wordMigrator", "WordMigrator", () =>
    deployAndWait("WordMigrator.sol", "WordMigrator", [oldWord, wordTokenV2, snap.root]),
  );

  // 4. FeeHookV2 via CREATE2 at a mined address encoding exactly the four V4 permission flags.
  //    Reuses the existing RewardsDistributor + BountyEngine; routes 25/25/50 (fixed).
  const hookArgs = coder.encode(
    ["address", "address", "uint24", "int24", "address", "address", "address", "address"],
    [poolManager, wordTokenV2, lpFee, tickSpacing, rewardsDistributor, bountyEngine, wordStaking, admin],
  );
  let feeHookV2: string;
  if (addrs.feeHookV2 && (await provider.getCode(addrs.feeHookV2)) !== "0x") {
    feeHookV2 = addrs.feeHookV2;
    console.log(`FeeHookV2: already at ${feeHookV2} — skip`);
  } else {
    const hookArtifact = factory("FeeHookV2.sol", "FeeHookV2", signer);
    const initCode = ethers.concat([hookArtifact.bytecode, hookArgs]);
    const {salt, address: predicted} = mineHookSalt(initCode);
    console.log(`mined FeeHookV2 address ${predicted} (salt ${salt})`);
    feeHookV2 = await deployViaCreate2(signer, salt, initCode);
    if (feeHookV2.toLowerCase() !== predicted.toLowerCase()) throw new Error("hook address mismatch");
    saveAddresses(net, {feeHookV2, feeHookV2Salt: salt, feeHookV2ConstructorArgs: hookArgs});
    console.log(`FeeHookV2: ${feeHookV2}`);
  }

  // 5. Fund the migrator with EXACTLY the reserve (idempotent: top up only the shortfall).
  const token = attach("WordTokenV2.sol", "WordTokenV2", wordTokenV2, signer);
  const migBal: bigint = await (token as any).balanceOf(wordMigrator);
  if (migBal >= reserveUsed) {
    console.log(`migrator already holds ${migBal} (>= reserve ${reserveUsed}) — skip funding`);
  } else {
    const topUp = reserveUsed - migBal;
    console.log(`funding migrator with ${topUp} WORD (reserve ${reserveUsed})…`);
    await (await (token as any).transfer(wordMigrator, topUp)).wait();
  }

  saveAddresses(net, {
    wordTokenV2,
    wordStaking,
    wordMigrator,
    feeHookV2,
    wordTokenV2Recipient: deployer, // constructor arg — for Etherscan verification
    v2MerkleRoot: snap.root, // WordMigrator constructor arg — for verification
    v2MigrationReserve: reserveUsed.toString(),
    v2SnapshotBlock: snap.snapshotBlock,
    v2LpPremint: snap.lpPremint,
  });

  const deployerBal: bigint = await (token as any).balanceOf(deployer);
  console.log("");
  console.log("v2 Phase 1 complete.");
  console.log(`  WordTokenV2 ${wordTokenV2}  WordStaking ${wordStaking}`);
  console.log(`  WordMigrator ${wordMigrator} (funded ${reserveUsed} WORD — migration is LIVE once announced)`);
  console.log(`  FeeHookV2 ${feeHookV2}`);
  console.log(`  deployer holds ${deployerBal} WORD for the LP seed (expected lpPremint ${snap.lpPremint})`);
  console.log("NEXT: scripts/v2-02-seed-and-launch.ts");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
