/**
 * Deployed-address registry. TWO clearly-separated groups:
 *
 *  1. OUR_ADDRESSES — the nine WORDBANK contracts. Sourced from the deploy
 *     pipeline via `npm run sync:addresses` (writes deployed.json). Null until
 *     a deployment exists; the UI shows the designed "pending" state.
 *
 *  2. UNISWAP — CANONICAL Uniswap V4 + Permit2 + WETH9 mainnet deployments.
 *     These are NOT ours; they back only the WORD-swap surface (HANDOFF §13).
 *     Kept as a separate group, never hardcoded inline in components.
 *
 * Nothing here is hand-edited per-deploy except via the sync script.
 */
import deployed from "./deployed.json";
import { EXPECTED_CHAIN_ID } from "./chain";

export type ContractKey =
  | "wordToken"
  | "wordBank"
  | "renderer"
  | "rewardsDistributor"
  | "bountyEngine"
  | "burnEngine"
  | "feeHook"
  | "lpLocker"
  | "royaltySplitter"
  // ── WORD v2 relaunch ──
  | "wordTokenV2"
  | "wordStaking"
  | "wordMigrator"
  | "feeHookV2";

export type Address = `0x${string}`;

function norm(v: string | null): Address | null {
  return v ? (v as Address) : null;
}

/** Our nine contracts — Address or null (pending deployment). */
export const OUR_ADDRESSES: Record<ContractKey, Address | null> = {
  wordToken: norm(deployed.contracts.wordToken),
  wordBank: norm(deployed.contracts.wordBank),
  renderer: norm(deployed.contracts.renderer),
  rewardsDistributor: norm(deployed.contracts.rewardsDistributor),
  bountyEngine: norm(deployed.contracts.bountyEngine),
  burnEngine: norm(deployed.contracts.burnEngine),
  feeHook: norm(deployed.contracts.feeHook),
  lpLocker: norm(deployed.contracts.lpLocker),
  royaltySplitter: norm(deployed.contracts.royaltySplitter),
  wordTokenV2: norm(deployed.contracts.wordTokenV2),
  wordStaking: norm(deployed.contracts.wordStaking),
  wordMigrator: norm(deployed.contracts.wordMigrator),
  feeHookV2: norm(deployed.contracts.feeHookV2),
};

/** WORD/ETH V4 pool launch params (currency0 = ETH, currency1 = WORD). */
export const POOL_PARAMS = {
  fee: deployed.pool.fee,
  tickSpacing: deployed.pool.tickSpacing,
  weth: norm(deployed.pool.weth),
} as const;

/** True once a contract has a deployed address. */
export function isDeployed(key: ContractKey): boolean {
  return OUR_ADDRESSES[key] !== null;
}

/** Throws a clear error if an address is needed before deployment. */
export function requireAddress(key: ContractKey): Address {
  const a = OUR_ADDRESSES[key];
  if (!a) {
    throw new Error(
      `${key} is not deployed yet — run \`npm run sync:addresses\` against a network with a completed deploy.`,
    );
  }
  return a;
}

/**
 * CANONICAL Uniswap V4 + Permit2 + WETH9 — separate group, NOT our contracts.
 * Selected per the configured chain (NEXT_PUBLIC_CHAIN_ID). They back only the
 * WORD-swap surface (HANDOFF §13).
 *
 * VERIFY against the official Uniswap deployments page before any MAINNET use:
 * https://docs.uniswap.org/contracts/v4/deployments
 */
export interface UniswapAddresses {
  poolManager: Address;
  universalRouter: Address;
  permit2: Address;
  v4Quoter: Address;
  stateView: Address;
  weth9: Address;
}

const UNISWAP_BY_CHAIN: Record<number, UniswapAddresses> = {
  // Ethereum mainnet (chainId 1) — also used by a mainnet-fork.
  1: {
    poolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
    universalRouter: "0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
    v4Quoter: "0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203",
    stateView: "0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227",
    weth9: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  },
  // Sepolia (chainId 11155111) — from Uniswap's official docs (testnet only).
  // Lowercased (no checksum to validate) so viem accepts them as-is.
  11155111: {
    poolManager: "0xe03a1074c86cfedd5c142c4f04f1a1536e203543",
    universalRouter: "0x3a9d48ab9751398bbfa63ad67599bb04e4bdf98b",
    permit2: "0x000000000022d473030f116ddee9f6b43ac78ba3",
    v4Quoter: "0x61b3f2011a92d183c7dbadbda940a7555ccf9227",
    stateView: "0xe1dd9c3fa50edb962e442f60dfbc432e24537e4c",
    weth9: "0xfff9976782d46cc05630d1f6ebab18b2324d6b14",
  },
};

/** The Uniswap set for the configured chain (defaults to mainnet for unknown ids). */
export const UNISWAP: UniswapAddresses = UNISWAP_BY_CHAIN[EXPECTED_CHAIN_ID] ?? UNISWAP_BY_CHAIN[1];
