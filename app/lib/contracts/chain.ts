/**
 * Chain + RPC config — ENV-DRIVEN so ONE build serves mainnet, a mainnet-fork,
 * AND Sepolia. Set `NEXT_PUBLIC_CHAIN_ID` (default 1 → mainnet; 11155111 →
 * Sepolia) to choose the network.
 *
 * RPC RESOLUTION (owner decision 2026-06-16 — NEVER ship the owner's Alchemy key):
 *   1. CONNECTED WALLET  → reads ride the visitor's own node via the EIP-1193
 *      provider (viem `custom(provider)`). The dApp never proxies the owner's RPC.
 *   2. NEXT_PUBLIC_RPC_URL → used ONLY if explicitly set (must be a PUBLIC/keyless
 *      URL the owner chooses for the pre-connect fallback). OPTIONAL.
 *   3. PUBLIC FALLBACK   → an explicit viem `fallback([...])` of KEYLESS public
 *      endpoints, ordered best-first, that can actually execute the V4 Quoter's
 *      heavy `eth_call` simulation (see PUBLIC_FALLBACK_RPCS below).
 *
 * There is NO Alchemy/Infura/keyed URL as a committed default, hardcoded fallback,
 * or required value. The dApp works fully with `NEXT_PUBLIC_RPC_URL` unset.
 *
 * WHY AN EXPLICIT FALLBACK LIST (bug fix 2026-06-16): viem's chain-default
 * `http()` (no URL) resolves to cloudflare-eth on mainnet, which returns
 * `-32603 Internal error` on the V4 Quoter `quoteExactInputSingle` simulation —
 * so swap quotes showed `0` for disconnected visitors. The endpoints below were
 * each verified to return the real quote against the live mainnet pool.
 *
 * "Wrong network" is anything other than the configured chain; the one-click
 * switch and all reads/writes target it. Injected-only wallet rules unchanged.
 */
import { createPublicClient, custom, fallback, http, type Chain } from "viem";
import { mainnet, sepolia } from "viem/chains";

/**
 * Minimal EIP-1193 shape viem's `custom()` needs (a `request` method). Kept
 * structural so we don't couple chain.ts to the wallet layer's own provider type.
 */
type Eip1193Like = {
  request: (args: { method: string; params?: unknown[] | object }) => Promise<unknown>;
};

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
 * OPTIONAL public fallback RPC used only before a wallet connects. If unset we
 * fall through to the verified keyless `PUBLIC_FALLBACK_RPCS` list below. MUST
 * stay a PUBLIC/keyless URL — `NEXT_PUBLIC_*` is shipped to every visitor's
 * browser, so an Alchemy/Infura key here would be exposed. Empty/blank = unset.
 */
const _rawRpc = process.env.NEXT_PUBLIC_RPC_URL;
export const PUBLIC_RPC_URL =
  _rawRpc && _rawRpc.trim() !== "" ? _rawRpc.trim() : undefined;

/**
 * KEYLESS public fallback endpoints per chain, ordered best-first. Used only when
 * no wallet is connected and no owner-set `NEXT_PUBLIC_RPC_URL` is present. Each
 * mainnet entry was verified to execute the V4 Quoter simulation and return the
 * real WORD quote against the live pool — viem `fallback()` tries them
 * in order and rolls to the next on failure, so a single endpoint hiccup (e.g.
 * an occasional rate-limit) won't break quotes.
 *
 * DELIBERATELY EXCLUDED for mainnet: cloudflare-eth (viem's `http()` default),
 * eth.merkle.io, eth.llamarpc.com — all of them fail the quoter `eth_call`.
 * All entries are keyless/public; NEVER put the owner's Alchemy/Infura key here.
 */
const PUBLIC_FALLBACK_RPCS: Record<number, string[]> = {
  [mainnet.id]: [
    "https://ethereum-rpc.publicnode.com", // verified: returns the quoter result
    "https://eth.drpc.org", // verified: returns the quoter result
    "https://1rpc.io/eth", // verified: returns the quoter result
  ],
  [sepolia.id]: [
    "https://ethereum-sepolia-rpc.publicnode.com", // keyless Sepolia
    "https://sepolia.drpc.org",
  ],
};

/**
 * The connected wallet's EIP-1193 provider, registered by WalletProvider so chain
 * reads ride the visitor's own node. null before connect / after disconnect.
 */
let _walletProvider: Eip1193Like | null = null;

/** The provider the cached client was built from, to detect when to rebuild. */
let _clientProvider: Eip1193Like | null = null;
let _publicClient: ReturnType<typeof createPublicClient> | null = null;

/**
 * Register (or clear) the connected wallet's provider. Called by WalletProvider on
 * connect / disconnect / provider change. Invalidates the cached read client so the
 * next `getPublicClient()` rebuilds with the new transport (wallet → public).
 */
export function setReadProvider(provider: Eip1193Like | null): void {
  if (provider === _walletProvider) return;
  _walletProvider = provider;
  // Drop the cached client; it is lazily rebuilt with the right transport.
  _publicClient = null;
  _clientProvider = null;
}

/** Build the read transport per the resolution order (wallet → env URL → public). */
function buildTransport() {
  // 1. Connected wallet: reads ride the visitor's own node (custom EIP-1193).
  if (_walletProvider) return custom(_walletProvider);
  // 2. Optional owner-chosen PUBLIC url (front-rank it, then keep the keyless
  //    fallbacks behind it so a flaky owner URL still degrades gracefully).
  // 3. Else the verified keyless fallback list for the configured chain.
  const keyless = PUBLIC_FALLBACK_RPCS[EXPECTED_CHAIN_ID] ?? [];
  const urls = [...(PUBLIC_RPC_URL ? [PUBLIC_RPC_URL] : []), ...keyless];
  // viem `fallback` rotates to the next transport on error/timeout. If somehow
  // no URL is known for the chain, fall back to viem's chain-default `http()`.
  return urls.length > 0
    ? fallback(urls.map((u) => http(u)))
    : http();
}

/**
 * Singleton public client for reads/events/simulation. Reads ride the connected
 * wallet's RPC when available, otherwise a public endpoint. Rebuilt automatically
 * when the wallet provider changes (so post-connect reads switch to the wallet).
 */
export function getPublicClient() {
  if (!_publicClient || _clientProvider !== _walletProvider) {
    _publicClient = createPublicClient({
      chain: CHAIN,
      transport: buildTransport(),
    });
    _clientProvider = _walletProvider;
  }
  return _publicClient;
}

/** True when reads are currently riding the connected wallet's provider. */
export function isUsingWalletRpc(): boolean {
  return _walletProvider !== null;
}
