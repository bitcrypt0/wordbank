/**
 * Block-explorer links, chain-aware. Mainnet (incl. a mainnet-fork that reports
 * chainId 1) → etherscan.io; Sepolia → sepolia.etherscan.io. An unknown/local
 * chain has no explorer, so links are omitted (callers render plain text).
 */
import { EXPECTED_CHAIN_ID } from "./chain";

const EXPLORERS: Record<number, string> = {
  1: "https://etherscan.io",
  11155111: "https://sepolia.etherscan.io",
};

const BASE = EXPLORERS[EXPECTED_CHAIN_ID] ?? null;

/** Base for address links (kept for the Docs contract-directory seam). */
export const ETHERSCAN_BASE = `${BASE ?? "https://etherscan.io"}/address/`;

export function etherscanAddressUrl(address: string): string | null {
  return BASE ? `${BASE}/address/${address}` : null;
}

export function etherscanTxUrl(hash: string): string | null {
  return BASE ? `${BASE}/tx/${hash}` : null;
}
