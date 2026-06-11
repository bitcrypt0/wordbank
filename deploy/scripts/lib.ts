/**
 * Shared helpers for the WORDBANK deployment pipeline.
 *
 * Foundry is the compiler of record: every ABI and every byte of deployed code comes from
 * ../out (run `forge build` at the repo root first). Hardhat only orchestrates transactions.
 */
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import {spawnSync} from "child_process";
import {
  AbiCoder,
  Contract,
  ContractFactory,
  JsonRpcProvider,
  NonceManager,
  Signer,
  Wallet,
  ethers,
  keccak256,
  concat,
  getCreate2Address,
} from "ethers";

export const OUT_DIR = path.join(__dirname, "..", "..", "out");
export const ADDRESSES_DIR = path.join(__dirname, "..", "addresses");

// ───────────────────────── RPC compatibility: tolerate `to: ""` ────────────────────────
// Some RPC providers return `to: ""` (empty string) instead of `to: null` in the
// transaction / receipt response for a CONTRACT-CREATION tx. ethers v6 (≥6.16) rejects that
// with `invalid value for value.to (invalid address value="")`, which crashed the owner's
// mainnet 01-deploy AFTER WordBank had already been created. We coerce `to: ""` → null in the
// RPC response before ethers parses it. Pure + exported so it is unit-tested directly.

/** Coerce a single RPC tx/receipt object's `to: ""` to null, in place. Returns the object. */
export function normalizeTxTo<T>(result: T): T {
  if (result && typeof result === "object") {
    const r = result as Record<string, unknown>;
    if (r.to === "") r.to = null;
  }
  return result;
}

/** A JsonRpcProvider that normalizes `to: ""` → null on tx/receipt lookups, so a creation-tx
 *  response can never crash ethers — applied once here and shared by every deploy script. */
export class NormalizingJsonRpcProvider extends JsonRpcProvider {
  async send(method: string, params: Array<any> | Record<string, any>): Promise<any> {
    const result = await super.send(method, params as any);
    if (method === "eth_getTransactionByHash" || method === "eth_getTransactionReceipt") {
      normalizeTxTo(result);
    }
    return result;
  }
}

/** The shared deploy signer: a Wallet on the `to:""`-normalizing provider, built from the
 *  hardhat network's RPC url + configured private key. Scripts use this instead of bare
 *  `ethers.getSigners()` so the normalization (and thus the RPC fix) benefits all of them.
 *
 *  Wrapped in a NonceManager so nonces are tracked locally and increment deterministically —
 *  a bare Wallet fetches the "pending" nonce per send, which races on fast chains (instant-mine
 *  anvil) and throws "nonce too low" across the many back-to-back deploy/wiring txs here. */
export function getDeploySigner(network: {name: string; config: any}): {
  signer: Signer;
  provider: NormalizingJsonRpcProvider;
} {
  const url: string | undefined = network.config?.url;
  if (!url) {
    throw new Error(`network '${network.name}' has no RPC url — run with --network <anvil|sepolia|mainnet>`);
  }
  const accounts = network.config?.accounts;
  let key: unknown = Array.isArray(accounts) ? accounts[0] : undefined;
  if (typeof key !== "string" || key.length === 0) {
    throw new Error(`network '${network.name}' has no private key — set PRIVATE_KEY in deploy/.env`);
  }
  if (!key.startsWith("0x")) key = "0x" + key;
  const provider = new NormalizingJsonRpcProvider(url);
  const signer = new NonceManager(new Wallet(key as string, provider));
  return {signer, provider};
}

/** Canonical deterministic CREATE2 deployer (same address on every chain). */
export const CREATE2_DEPLOYER = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
/** Canonical Permit2 (same address on every chain). */
export const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

/** The FeeHook's four V4 permission flags: beforeSwap | afterSwap | both return-deltas. */
export const HOOK_FLAGS = 0x00ccn;
export const HOOK_FLAG_MASK = 0x3fffn; // all 14 permission bits

export interface FoundryArtifact {
  abi: any[];
  bytecode: {object: string};
}

/** Loads a forge artifact, e.g. artifact("FeeHook.sol", "FeeHook"). */
export function artifact(file: string, name: string): FoundryArtifact {
  const p = path.join(OUT_DIR, file, `${name}.json`);
  if (!fs.existsSync(p)) {
    throw new Error(`Missing forge artifact ${p} — run 'forge build' at the repo root first.`);
  }
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

export function factory(file: string, name: string, signer: Signer): ContractFactory {
  const a = artifact(file, name);
  return new ContractFactory(a.abi, a.bytecode.object, signer);
}

export function attach(file: string, name: string, address: string, signer: Signer): Contract {
  const a = artifact(file, name);
  return new Contract(address, a.abi, signer);
}

/** Mines a CREATE2 salt so the FeeHook address encodes exactly HOOK_FLAGS in its low 14 bits. */
export function mineHookSalt(initCode: string): {salt: string; address: string} {
  const initCodeHash = keccak256(initCode);
  for (let i = 0n; i < 1_000_000n; i++) {
    const salt = ethers.zeroPadValue(ethers.toBeHex(i), 32);
    const addr = getCreate2Address(CREATE2_DEPLOYER, salt, initCodeHash);
    if ((BigInt(addr) & HOOK_FLAG_MASK) === HOOK_FLAGS) {
      return {salt, address: addr};
    }
  }
  throw new Error("no salt found in 1,000,000 iterations");
}

/** Deploys init code through the canonical CREATE2 deployer (tx data = salt ++ initCode). */
export async function deployViaCreate2(signer: Signer, salt: string, initCode: string): Promise<string> {
  const tx = await signer.sendTransaction({to: CREATE2_DEPLOYER, data: concat([salt, initCode])});
  await tx.wait();
  return getCreate2Address(CREATE2_DEPLOYER, salt, keccak256(initCode));
}

/** Persists deployed addresses + constructor args per network (consumed by later phases & verification). */
export function saveAddresses(network: string, addresses: Record<string, unknown>): void {
  fs.mkdirSync(ADDRESSES_DIR, {recursive: true});
  const p = path.join(ADDRESSES_DIR, `${network}.json`);
  const existing = fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, "utf8")) : {};
  fs.writeFileSync(p, JSON.stringify({...existing, ...addresses}, null, 2));
  console.log(`addresses written to ${p}`);
}

export function loadAddresses(network: string): Record<string, any> {
  const p = path.join(ADDRESSES_DIR, `${network}.json`);
  if (!fs.existsSync(p)) throw new Error(`no addresses file for network '${network}' — run phase 1 first`);
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

/** Repo root — one level above deploy/ — where forge must run (it needs src/ + foundry.toml). */
export const REPO_ROOT = path.join(__dirname, "..", "..");

/** Locates the `forge` binary without requiring it on PATH (Foundry is NOT on the owner's PATH).
 *  Tries ~/.foundry/bin/forge[.exe] first (the foundryup default), then falls back to `forge`
 *  on PATH (so a PATH install still works). Returns the resolved binary string for spawning.
 *  Throws a clear, actionable error if neither is usable. */
export function resolveForge(): string {
  // Explicit override wins (custom Foundry install, or tests). Must point at a real binary.
  const override = (process.env.FORGE_BIN ?? "").trim();
  if (override) {
    if (override === "forge" || fs.existsSync(override)) return override;
    throw new Error(`FORGE_BIN is set to '${override}' but no such file exists.`);
  }
  const home = process.env.HOME || process.env.USERPROFILE || os.homedir();
  const candidates = [
    path.join(home, ".foundry", "bin", process.platform === "win32" ? "forge.exe" : "forge"),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  // Fall back to PATH: probe `forge --version`. If that fails, the binary isn't installed.
  const probe = spawnSync("forge", ["--version"], {stdio: "ignore", shell: process.platform === "win32"});
  if (!probe.error && probe.status === 0) return "forge";
  throw new Error(
    `Foundry's 'forge' was not found.\n` +
      `  Looked for: ${candidates.join(", ")}\n` +
      `  and 'forge' on your PATH.\n` +
      `  Install Foundry (https://getfoundry.sh) — it normally lands in ~/.foundry/bin.`,
  );
}

/** Like loadAddresses but returns {} instead of throwing — for resumable scripts that read
 *  what's already been deployed before writing more. */
export function loadAddressesOrEmpty(network: string): Record<string, any> {
  const p = path.join(ADDRESSES_DIR, `${network}.json`);
  return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, "utf8")) : {};
}

export function env(name: string, fallback?: string): string {
  // Treat a present-but-blank var (e.g. `ADMIN=` in .env) as missing, so the fallback
  // applies and required vars give a clear error instead of a cryptic downstream crash
  // (an empty string passed as an address makes ethers attempt ENS resolveName).
  const raw = process.env[name];
  const v = raw === undefined || raw.trim() === "" ? fallback : raw.trim();
  if (v === undefined) throw new Error(`missing required env var ${name}`);
  return v;
}

export const coder = AbiCoder.defaultAbiCoder();

/** PoolKey tuple type for ABI encoding. */
export const POOL_KEY_TUPLE = "tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)";

export interface PoolKey {
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
}

const Q96 = 2n ** 96n;

/** sqrt(1.0001^tick) * 2^96, float-derived then floored — only used for full-range bounds
 *  where sub-ppm precision is irrelevant (the computed liquidity is deflated by 0.1% and
 *  posm sweeps/refunds the unused remainder). */
export function sqrtPriceAtTick(tick: number): bigint {
  const ratio = Math.pow(1.0001, tick / 2);
  // Split to keep float precision sane across the huge exponent range.
  return (BigInt(Math.floor(ratio * 1e15)) * Q96) / 10n ** 15n;
}

/** Uniswap LiquidityAmounts.getLiquidityForAmounts, full-precision BigInt. */
export function liquidityForAmounts(
  sqrtP: bigint,
  sqrtA: bigint,
  sqrtB: bigint,
  amount0: bigint,
  amount1: bigint,
): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  const liq0 = (numerator: bigint, sa: bigint, sb: bigint) => (numerator * sa * sb) / Q96 / (sb - sa);
  const liq1 = (amount: bigint, sa: bigint, sb: bigint) => (amount * Q96) / (sb - sa);
  let liquidity: bigint;
  if (sqrtP <= sqrtA) liquidity = liq0(amount0, sqrtA, sqrtB);
  else if (sqrtP < sqrtB) {
    const l0 = liq0(amount0, sqrtP, sqrtB);
    const l1 = liq1(amount1, sqrtA, sqrtP);
    liquidity = l0 < l1 ? l0 : l1;
  } else liquidity = liq1(amount1, sqrtA, sqrtB);
  // Deflate 0.1% so float-derived range bounds can never make posm demand more than our maxes.
  return (liquidity * 999n) / 1000n;
}
