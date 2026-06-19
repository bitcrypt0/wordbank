/**
 * Chain + RPC config — ENV-DRIVEN so ONE build serves mainnet, a mainnet-fork,
 * AND Sepolia. Set `NEXT_PUBLIC_CHAIN_ID` (default 1 → mainnet; 11155111 →
 * Sepolia) to choose the network.
 *
 * READ RPC RESOLUTION (owner decision 2026-06-16 — reads NEVER ride the wallet):
 *   Reads ALWAYS target the configured chain's own RPC, regardless of whether a
 *   wallet is connected and regardless of which network the wallet is on. This
 *   guarantees the Dashboard, owned-NFT discovery, and swap quotes work pre- and
 *   post-connect identically. The read transport is:
 *     1. NEXT_PUBLIC_RPC_URL → used ONLY if explicitly set (must be a PUBLIC/
 *        keyless URL). Front-ranked. OPTIONAL.
 *     2. PUBLIC FALLBACK   → an explicit viem `fallback([...])` of KEYLESS public
 *        endpoints, ordered best-first, that can execute the V4 Quoter's heavy
 *        `eth_call` simulation AND serve ownerOf/eth_getLogs (see
 *        PUBLIC_FALLBACK_RPCS below).
 *
 * The wallet's EIP-1193 provider is used ONLY for WRITES (see clients.ts) and
 * network UX (wrongNetwork detection + one-click switch in WalletProvider). It
 * is NEVER used for reads — coupling reads to the wallet's selected network and
 * RPC quirks/limits was the source of the empty-Dashboard / 0-quote bugs.
 *
 * There is NO Alchemy/Infura/keyed URL as a committed default, hardcoded fallback,
 * or required value. The dApp works fully with `NEXT_PUBLIC_RPC_URL` unset.
 *
 * WHY AN EXPLICIT FALLBACK LIST (bug fix 2026-06-16): viem's chain-default
 * `http()` (no URL) resolves to cloudflare-eth on mainnet, which returns
 * `-32603 Internal error` on the V4 Quoter `quoteExactInputSingle` simulation —
 * so swap quotes showed `0`. The endpoints below were each verified to return the
 * real quote, serve `ownerOf`, and handle wide `eth_getLogs` ranges against the
 * live mainnet pool.
 *
 * "Wrong network" is anything other than the configured chain; the one-click
 * switch targets it. Injected-only wallet rules unchanged.
 */
import { createPublicClient, fallback, http, type Chain } from "viem";
import { mainnet, sepolia } from "viem/chains";

/** Supported chains, keyed by id. Add more here if a new network is rehearsed. */
const SUPPORTED: Record<number, Chain> = {
  [mainnet.id]: mainnet, // 1
  [sepolia.id]: sepolia, // 11155111
};

/** The configured chain id (default mainnet). NEXT_PUBLIC_* is inlined at build.
 *  Empty/unset/NaN all fall back to 1 so a blank env line never yields chainId 0. */
const _rawChainId = process.env.NEXT_PUBLIC_CHAIN_ID;
export const EXPECTED_CHAIN_ID =
  _rawChainId && _rawChainId.trim() !== "" && !Number.isNaN(Number(_rawChainId))
    ? Number(_rawChainId)
    : 1;

/** The viem chain for the configured id; falls back to mainnet for an unknown id. */
export const CHAIN: Chain = SUPPORTED[EXPECTED_CHAIN_ID] ?? mainnet;

/**
 * OPTIONAL public fallback RPC, front-ranked ahead of the keyless list below.
 * MUST stay a PUBLIC/keyless URL — `NEXT_PUBLIC_*` is shipped to every visitor's
 * browser, so an Alchemy/Infura key here would be exposed. Empty/blank = unset.
 */
const _rawRpc = process.env.NEXT_PUBLIC_RPC_URL;
export const PUBLIC_RPC_URL =
  _rawRpc && _rawRpc.trim() !== "" ? _rawRpc.trim() : undefined;

/**
 * KEYLESS public fallback endpoints per chain, ordered best-first. Each mainnet
 * entry was verified to execute the V4 Quoter simulation, serve `ownerOf`, and
 * handle wide `eth_getLogs` ranges against the live pool — viem `fallback()`
 * tries them in order and rolls to the next on failure, so a single endpoint
 * hiccup (e.g. an occasional rate-limit) won't break reads.
 *
 * DELIBERATELY EXCLUDED for mainnet: cloudflare-eth (viem's `http()` default),
 * eth.merkle.io, eth.llamarpc.com — all of them fail the quoter `eth_call`.
 * All entries are keyless/public; NEVER put the owner's Alchemy/Infura key here.
 */
const PUBLIC_FALLBACK_RPCS: Record<number, string[]> = {
  [mainnet.id]: [
    "https://ethereum-rpc.publicnode.com", // verified: quoter + ownerOf + wide getLogs (≥9k blocks)
    "https://eth.drpc.org", // verified: quoter result + ≥9k-block getLogs
    // NOTE: https://1rpc.io/eth was REMOVED (2026-06-16). Its eth_getLogs is hard-capped
    // at 50 blocks, so when fallback() rotated to it any getLogs scan exploded into
    // hundreds of recursive sub-windows — the catastrophic slowdown on the /game page.
    // publicnode + drpc both handle the quoter AND wide getLogs; two endpoints keep redundancy.
  ],
  [sepolia.id]: [
    "https://ethereum-sepolia-rpc.publicnode.com", // keyless Sepolia (handles wide getLogs)
    "https://sepolia.drpc.org",
  ],
};

/** The provider config the cached client was built from, to detect when to rebuild. */
let _publicClient: ReturnType<typeof createPublicClient> | null = null;

/**
 * Retained as a HARMLESS NO-OP for backward compatibility. Reads no longer ride
 * the wallet provider, so registering one is intentionally ignored. WalletProvider
 * no longer calls this; kept only so any stale import doesn't break the build.
 */
export function setReadProvider(_provider: unknown): void {
  /* no-op: reads always use the configured-chain RPC, never the wallet */
}

/**
 * Build the read transport: optional NEXT_PUBLIC_RPC_URL (front-ranked) → the
 * verified keyless fallback list for the configured chain. NEVER the wallet.
 * Builds the SAME transport whether or not a wallet is connected.
 */
function buildTransport() {
  const keyless = PUBLIC_FALLBACK_RPCS[EXPECTED_CHAIN_ID] ?? [];
  const urls = [...(PUBLIC_RPC_URL ? [PUBLIC_RPC_URL] : []), ...keyless];
  // viem `fallback` rotates to the next transport on error/timeout. If somehow
  // no URL is known for the chain, fall back to viem's chain-default `http()`.
  return urls.length > 0 ? fallback(urls.map((u) => http(u))) : http();
}

/**
 * Singleton public client for reads/events/simulation. Always targets the
 * configured chain via the keyless public RPC (or an owner-set PUBLIC
 * NEXT_PUBLIC_RPC_URL) — never the connected wallet's provider.
 */
export function getPublicClient() {
  if (!_publicClient) {
    _publicClient = createPublicClient({
      chain: CHAIN,
      transport: buildTransport(),
    });
  }
  return _publicClient;
}

/** Reads never ride the wallet provider; kept for backward compat (always false). */
export function isUsingWalletRpc(): boolean {
  return false;
}
