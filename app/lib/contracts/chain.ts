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
 *   3. PUBLIC DEFAULT    → viem's chain-default public RPC (`http()` with no URL).
 *
 * There is NO Alchemy/Infura/keyed URL as a committed default, hardcoded fallback,
 * or required value. The dApp works fully with `NEXT_PUBLIC_RPC_URL` unset.
 *
 * "Wrong network" is anything other than the configured chain; the one-click
 * switch and all reads/writes target it. Injected-only wallet rules unchanged.
 */
import { createPublicClient, custom, http, type Chain } from "viem";
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
 * fall through to the chain's own public RPC (`http()` with no URL). MUST stay a
 * PUBLIC/keyless URL — `NEXT_PUBLIC_*` is shipped to every visitor's browser, so
 * an Alchemy/Infura key here would be exposed. Empty/blank is treated as unset.
 */
const _rawRpc = process.env.NEXT_PUBLIC_RPC_URL;
export const PUBLIC_RPC_URL =
  _rawRpc && _rawRpc.trim() !== "" ? _rawRpc.trim() : undefined;

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
  if (_walletProvider) return custom(_walletProvider);
  // No wallet: optional owner-chosen PUBLIC url, else the chain's default public RPC.
  return PUBLIC_RPC_URL ? http(PUBLIC_RPC_URL) : http();
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
