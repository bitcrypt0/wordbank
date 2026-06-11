/**
 * Address sync — the dApp's deployed addresses come from the deploy pipeline,
 * never hardcoded (agent 9 charter). The Hardhat deploy writes
 * `deploy/addresses/<network>.json`; this script maps the keys the dApp needs
 * into `lib/contracts/deployed.json`, which every contract read imports.
 *
 * Run from `app/`:  npm run sync:addresses -- <network>   (default: localhost)
 * Safe to run before any deploy: if the source file is missing it leaves the
 * committed all-null stub untouched so the UI keeps its "pending" state.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ADDRESSES_DIR = path.resolve(HERE, "..", "..", "deploy", "addresses");
const OUT_FILE = path.resolve(HERE, "..", "lib", "contracts", "deployed.json");

const network = process.argv[2] ?? process.env.DEPLOY_NETWORK ?? "localhost";

/** network name → chainId (a local fork keeps mainnet's chainId 1). */
const NETWORK_CHAIN_IDS: Record<string, number> = {
  mainnet: 1,
  localhost: 1, // mainnet-fork Anvil
  anvil: 1,
  fork: 1,
  sepolia: 11155111,
  hardhat: 31337,
};

/** Resolve the chainId: explicit source field → DEPLOY_CHAIN_ID env → name map → 1. */
function resolveChainId(source: Record<string, unknown>): number {
  if (typeof source.chainId === "number") return source.chainId;
  if (process.env.DEPLOY_CHAIN_ID) return Number(process.env.DEPLOY_CHAIN_ID);
  return NETWORK_CHAIN_IDS[network] ?? 1;
}

/** deploy key → dApp key. Keys absent from the source stay null. */
const CONTRACT_KEYS: Record<string, string> = {
  wordToken: "wordToken",
  wordBank: "wordBank",
  renderer: "renderer",
  rewardsDistributor: "rewardsDistributor",
  bountyEngine: "bountyEngine",
  burnEngine: "burnEngine",
  feeHook: "feeHook",
  lpLocker: "lpLocker",
  royaltySplitter: "royaltySplitter",
};

function main(): void {
  const src = path.join(ADDRESSES_DIR, `${network}.json`);
  if (!fs.existsSync(src)) {
    console.log(
      `sync-addresses: no deploy output at ${src} — leaving deployed.json as-is (pending state). ` +
        `Run the deploy pipeline (deploy/scripts/01-deploy-protocol.ts) first.`,
    );
    return;
  }
  const deployed = JSON.parse(fs.readFileSync(src, "utf8")) as Record<string, unknown>;
  const current = JSON.parse(fs.readFileSync(OUT_FILE, "utf8")) as {
    contracts: Record<string, string | null>;
    pool: { fee: number; tickSpacing: number; weth: string | null };
    [k: string]: unknown;
  };

  const contracts: Record<string, string | null> = {};
  for (const [dapp, deploy] of Object.entries(CONTRACT_KEYS)) {
    contracts[dapp] = (deployed[deploy] as string | undefined) ?? null;
  }

  const out = {
    _comment: current._comment,
    network,
    chainId: resolveChainId(deployed),
    contracts,
    pool: {
      fee: (deployed.lpFee as number | undefined) ?? current.pool.fee,
      tickSpacing: (deployed.tickSpacing as number | undefined) ?? current.pool.tickSpacing,
      weth: (deployed.weth as string | undefined) ?? current.pool.weth,
    },
  };
  fs.writeFileSync(OUT_FILE, JSON.stringify(out, null, 2) + "\n", "utf8");
  const filled = Object.values(contracts).filter(Boolean).length;
  console.log(`sync-addresses: ${network} → deployed.json (${filled}/9 contracts set)`);
}

main();
