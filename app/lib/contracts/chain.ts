/**
 * Chain + RPC config — ENV-DRIVEN so ONE build serves mainnet, a mainnet-fork,
 * AND Sepolia. Set `NEXT_PUBLIC_CHAIN_ID` (default 1 → mainnet; 11155111 →
 * Sepolia) to choose the network.
 *
 * READ RPC RESOLUTION (owner decision 2026-06-16 — reads NEVER ride the wallet):
 *   Reads ALWAYS target the configured chain's own RPC, regardless of whether a
 *   wallet is connected and regardless of which network the wallet is on. This
 *   guarantees the Dashboard, owned-NFT discovery, and swap quotes work pre- and
 *   post-connect identically. The read transport is, in order:
 *     1. SAME-ORIGIN PROXY (/api/rpc) → front-ranked ONLY when the owner has set
 *        up the optional server-side RPC proxy (server-only `RPC_PROXY_URL` +
 *        the public opt-in flag `NEXT_PUBLIC_RPC_PROXY=1`). The proxy forwards
 *        JSON-RPC to a KEYED endpoint (e.g. Alchemy) that lives ONLY on the
 *        server — the key is NEVER shipped to the browser or the repo. See
 *        app/app/api/rpc/route.ts. This is the most reliable read path.
 *     2. NEXT_PUBLIC_RPC_URL → used ONLY if explicitly set (must be a PUBLIC/
 *        keyless URL). OPTIONAL.
 *     3. PUBLIC FALLBACK   → an explicit viem `fallback([...])` of KEYLESS public
 *        endpoints, ordered best-first, that can execute the V4 Quoter's heavy
 *        `eth_call` simulation AND serve ownerOf/eth_getLogs (see
 *        PUBLIC_FALLBACK_RPCS below). Each `http()` is given retry/backoff +
 *        timeout so a 429/5xx burst is retried and rotated rather than thrown.
 *
 * RATE-LIMIT RESILIENCE (change order 2026-06-16): a read-heavy page (the /game
 * console especially) fires ~10+ JSON-RPC requests on mount; free public
 * endpoints 429 that burst, so a read throws and content never renders. Two
 * mitigations on the READ client:
 *   - Each `http(url)` carries `{ retryCount, retryDelay, timeout }` so a 429/5xx
 *     is retried with backoff before viem `fallback()` rotates to the next URL.
 *   - The public client enables request coalescing (`batch: { multicall: true }`)
 *     so per-render `readContract`s collapse into far fewer Multicall3 calls,
 *     shrinking the burst that triggers the limiter in the first place.
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
import { createPublicClient, custom, fallback, http, type Chain } from "viem";
import { mainnet, sepolia } from "viem/chains";
import type { Eip1193Provider } from "@/lib/wallet/types";

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
 * Block the WORDBANK contracts went live (the first WordBank mint Transfer,
 * verified on-chain 2026-06-20). Used as the FLOOR for whole-history log scans
 * (e.g. lifetime-claimed totals) so they sweep ~the collection's age instead of a
 * blanket 250k-block lookback that wastes ~24 empty windows on pre-deploy blocks.
 * undefined for chains where it's unknown (e.g. a Sepolia rehearsal) → callers use
 * their default lookback.
 */
const DEPLOY_BLOCK_BY_CHAIN: Record<number, bigint> = {
  [mainnet.id]: 25_330_799n,
};
export const DEPLOY_BLOCK: bigint | undefined = DEPLOY_BLOCK_BY_CHAIN[EXPECTED_CHAIN_ID];

/**
 * OPTIONAL public fallback RPC, front-ranked ahead of the keyless list below.
 * MUST stay a PUBLIC/keyless URL — `NEXT_PUBLIC_*` is shipped to every visitor's
 * browser, so an Alchemy/Infura key here would be exposed. Empty/blank = unset.
 */
const _rawRpc = process.env.NEXT_PUBLIC_RPC_URL;
export const PUBLIC_RPC_URL =
  _rawRpc && _rawRpc.trim() !== "" ? _rawRpc.trim() : undefined;

/**
 * OPTIONAL server-side RPC proxy opt-in. The proxy ROUTE (app/app/api/rpc) reads
 * the SERVER-ONLY `RPC_PROXY_URL` (a keyed endpoint, e.g. Alchemy) — that secret
 * is NEVER exposed to the browser. But the browser-side read client can't see a
 * server-only env var, so the owner sets this PUBLIC flag alongside it to tell
 * the client to front-rank the same-origin `/api/rpc` transport:
 *
 *     RPC_PROXY_URL=https://eth-mainnet.g.alchemy.com/v2/<key>   (server-only)
 *     NEXT_PUBLIC_RPC_PROXY=1                                    (public opt-in)
 *
 * The flag carries NO secret (it's just "1"); the key stays server-side. If the
 * flag is set but the route isn't actually configured, the route returns 503 and
 * viem `fallback()` rolls straight to the keyless public list — graceful, no crash.
 */
const _rawProxyFlag = process.env.NEXT_PUBLIC_RPC_PROXY;
export const RPC_PROXY_ENABLED =
  !!_rawProxyFlag && _rawProxyFlag.trim() !== "" && _rawProxyFlag.trim() !== "0";

/** Same-origin proxy path — resolved relative to the page origin in the browser. */
const RPC_PROXY_PATH = "/api/rpc";

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
    "https://ethereum-rpc.publicnode.com", // PRIMARY — verified: quoter + ownerOf + wide getLogs (≥9k blocks) + multicall
    "https://eth.drpc.org", // verified: quoter result + ≥9k-block getLogs
    "https://rpc.ankr.com/eth", // rotation headroom (2026-06-16): keyless, verified quoter eth_call + multicall + getLogs
    // NOTE: https://1rpc.io/eth stays REMOVED. Its eth_getLogs is hard-capped at
    // 50 blocks, so when fallback() rotated to it any getLogs scan exploded into
    // hundreds of recursive sub-windows — the catastrophic slowdown on the /game page.
    // cloudflare-eth / eth.merkle.io / eth.llamarpc.com are excluded too: they fail
    // the V4 Quoter eth_call. Each endpoint above carries retry/backoff (see http()
    // wrapper in buildTransport) so a 429 burst is retried + rotated, not thrown.
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
 * Per-endpoint retry/backoff + timeout so a 429/5xx (the public-RPC rate-limit
 * failure mode) is retried with backoff before viem `fallback()` rotates to the
 * next URL. viem retries idempotent JSON-RPC requests on these; the timeout
 * bounds a hung endpoint so rotation isn't blocked.
 */
const HTTP_OPTS = { retryCount: 4, retryDelay: 300, timeout: 12_000 } as const;

/**
 * Read-client request coalescing. MUST be an OBJECT with an explicit batchSize:
 * `multicall: true` (a boolean) makes viem fall back to its 1024-BYTE default
 * chunk size, which shreds a single 400-call multicall into ~15 separate eth_calls
 * (measured). Through the /api/rpc → Alchemy proxy hop, that turned the Dashboard's
 * ownerOf sweep + per-token reads into dozens of 1-3s requests. A large byte budget
 * lets a whole 400-id batch ride in ONE aggregate3 call (~15x fewer requests).
 * `wait` is the coalescing window for separate readContract calls fired in the same
 * tick. batchSize is in BYTES of calldata, not number of calls. (perf fix 2026-06-20)
 */
const READ_BATCH = { multicall: { batchSize: 102_400, wait: 16 } } as const;

/**
 * The backup HTTP transports, best-first: same-origin /api/rpc proxy (when opted
 * in) → optional public NEXT_PUBLIC_RPC_URL → the verified keyless fallback list.
 * These NEVER ride the wallet. Returned as an array so callers can either wrap it
 * directly (the default public client) or front-rank the wallet provider ahead of
 * it (the Dashboard's wallet-preferring client — see getWalletPreferringClient).
 */
function backupTransports() {
  const keyless = PUBLIC_FALLBACK_RPCS[EXPECTED_CHAIN_ID] ?? [];
  const urls = [...(PUBLIC_RPC_URL ? [PUBLIC_RPC_URL] : []), ...keyless];
  const transports = urls.map((u) => http(u, HTTP_OPTS));
  // Front-rank the same-origin proxy when the owner opted in. Same-origin → no
  // CORS, covered by CSP `connect-src 'self'`. If the route 503s (RPC_PROXY_URL
  // unset on the server), viem rotates to the keyless list below.
  if (RPC_PROXY_ENABLED) {
    transports.unshift(http(RPC_PROXY_PATH, HTTP_OPTS));
  }
  return transports;
}

/**
 * Build the default read transport (NEVER the wallet). Same transport whether or
 * not a wallet is connected; wrapped in a single `fallback([...])` so any
 * 429/5xx/timeout rotates to the next one.
 */
function buildTransport() {
  const transports = backupTransports();
  // viem `fallback` rotates to the next transport on error/timeout. If somehow
  // no transport is known for the chain, fall back to viem's chain-default http().
  return transports.length > 0 ? fallback(transports) : http(undefined, HTTP_OPTS);
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
      batch: READ_BATCH,
    });
  }
  return _publicClient;
}

/**
 * Read client that PREFERS the connected wallet's own RPC, then falls back to the
 * normal public/proxy transport. Used ONLY by the Dashboard (gated on a connected
 * account anyway).
 *
 * WHY: the connected wallet talks DIRECTLY to its configured RPC (e.g. the user's
 * own Alchemy / the wallet's Infura) over EIP-1193 — no same-origin /api/rpc hop,
 * so it skips the Vercel serverless round-trip that dominates read latency (~1-3s
 * per call even for a tiny eth_call). The earlier reason reads were decoupled from
 * the wallet — getLogs-based discovery failing on restricted wallet RPCs — no
 * longer applies: owned-NFT discovery is now log-free ownerOf enumeration, which
 * every RPC serves. Read methods (eth_call/getLogs/chainId) never prompt the user.
 *
 * SAFETY: the wallet transport is front-ranked ONLY when the wallet is connected
 * AND on the configured chain (else reads would hit the wrong network) — otherwise
 * this returns the plain public client. And it is only FRONT-RANKED: viem
 * `fallback()` rotates to the public/proxy transports if a wallet RPC call fails
 * (e.g. a wallet RPC that caps eth_getLogs), so correctness never depends on the
 * wallet endpoint. Not cached — it depends on the live provider identity.
 */
export function getWalletPreferringClient(
  provider: Eip1193Provider | null,
  walletChainId: number | null,
) {
  if (!provider || walletChainId !== EXPECTED_CHAIN_ID) return getPublicClient();
  return createPublicClient({
    chain: CHAIN,
    transport: fallback([
      custom(provider as Parameters<typeof custom>[0]),
      ...backupTransports(),
    ]),
    batch: READ_BATCH,
  });
}

/** True when the Dashboard's wallet-preferring client would ride the wallet RPC. */
export function isUsingWalletRpc(provider?: unknown, walletChainId?: number | null): boolean {
  return !!provider && walletChainId === EXPECTED_CHAIN_ID;
}
