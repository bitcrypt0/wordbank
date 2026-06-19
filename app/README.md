# WORDBANK dApp

The production dApp — Agent 8's design, wired to the contracts by Agent 9.
Injected wallets only (EIP-6963 + `window.ethereum` fallback; no
RainbowKit/WalletConnect/Web3Modal). Reads via viem; every write simulates first
and shows pending/confirmed/failed with decoded custom errors.

```bash
npm install
npm run sync:abis            # ABIs from Foundry out/  (after any forge build)
npm run sync:addresses -- <network>   # deployed addresses → lib/contracts/deployed.json
npm run dev                  # → http://localhost:3000
npm run build                # must stay green
npm test                     # vitest (wallet lifecycle, swap math, chain config)
```

## Chain configuration (env-driven — one build, any network)

The dApp is **not** hardwired to a chain. Two public env vars select the network
(inlined at build time):

| Env var | Default | Meaning |
|---|---|---|
| `NEXT_PUBLIC_CHAIN_ID` | `1` (mainnet) | `1` = Ethereum mainnet / mainnet-fork · `11155111` = Sepolia |
| `NEXT_PUBLIC_RPC_URL` | _(unset → keyless public fallback)_ | **OPTIONAL** public read RPC (must be keyless) |
| `RPC_PROXY_URL` | _(unset)_ | **OPTIONAL, SERVER-ONLY** keyed read RPC behind `/api/rpc` — never shipped to the browser |
| `NEXT_PUBLIC_RPC_PROXY` | _(unset)_ | Set to `1` to tell the client to front-rank the `/api/rpc` proxy |

With the default (unset) it targets **mainnet**. The wrong-network banner and the
one-click switch always target the configured chain, and the WORD swap uses that
chain's canonical Uniswap V4 set (mainnet vs. Sepolia, in `lib/contracts/addresses.ts`).

#### RPC: the dApp never ships the owner's key

Chain reads (balances, stats, events, simulation) **never ride the wallet** — they
always target the configured chain's own RPC, pre- and post-connect identically.
They resolve in this order (`lib/contracts/chain.ts`):

1. **`/api/rpc` server-side proxy** — front-ranked **only when `NEXT_PUBLIC_RPC_PROXY=1`**.
   The route (`app/app/api/rpc/route.ts`) forwards JSON-RPC to the **server-only**
   `RPC_PROXY_URL` (a keyed endpoint, e.g. Alchemy). The **key stays on the server** —
   `RPC_PROXY_URL` is **not** a `NEXT_PUBLIC_` var, so Next never inlines it into the
   browser bundle. This is the **most reliable** path (no public rate limits). See below.
2. **`NEXT_PUBLIC_RPC_URL`**, *only if set* → must be a **PUBLIC / keyless** URL —
   `NEXT_PUBLIC_*` is inlined into the browser bundle, so an Alchemy/Infura key here
   would be exposed to every visitor.
3. **Keyless public fallback** → an explicit viem `fallback([...])` of **keyless**
   public endpoints, ordered best-first (mainnet: `ethereum-rpc.publicnode.com` →
   `eth.drpc.org` → `rpc.ankr.com/eth`). These are NOT viem's chain default
   (cloudflare-eth): cloudflare/merkle/llama all return `-32603` on the V4 Quoter's
   heavy `eth_call`, so swap quotes showed `0`. Each endpoint is verified to execute
   the quoter against the live mainnet pool; viem rotates to the next on any error.

The dApp works fully with **all of these unset** (keyless fallback, which CAN run
the quoter). The wrong-network guard reads the chainId from the wallet provider, so
it keeps working regardless of which read path is active.

#### Rate-limit resilience (change order 2026-06-16)

A read-heavy page (the `/game` console especially) fires ~10+ JSON-RPC requests on
mount. Free public endpoints **429 that burst**, so a read throws and content never
renders. The read client is hardened so it survives the keyless fallback under load:

- **Retry/backoff + timeout** on every keyless `http()` (`{ retryCount: 4,
  retryDelay: 300, timeout: 12_000 }`) — a 429/5xx is retried before viem
  `fallback()` rotates to the next endpoint.
- **Request coalescing** on the read client (`batch: { multicall: true }`) — the
  per-render burst of `readContract`s collapses into a few Multicall3 calls.
- **Extra endpoint headroom** — `rpc.ankr.com/eth` added to the rotation
  (`1rpc.io/eth` stays out: its 50-block `eth_getLogs` cap is hostile).
- **Staggered game reads** — the heavy sentence/history read mounts ~250ms behind
  the live state read so they don't burst simultaneously.

> **The reliable option (recommended for a public deploy):** use the **server-side
> proxy**. In Vercel set `RPC_PROXY_URL` to a keyed, reliable endpoint (e.g.
> `https://eth-mainnet.g.alchemy.com/v2/<key>`) as a normal/secret env var, and set
> `NEXT_PUBLIC_RPC_PROXY=1`. The browser then sends reads to same-origin `/api/rpc`,
> which forwards them server-side to the keyed endpoint — the **key is never in the
> browser or the repo**. The route is POST-only, validates JSON-RPC shape/size, and
> only forwards **read methods** (no `eth_sendRawTransaction` — writes still go
> through the wallet), so it is not an open relay. If `NEXT_PUBLIC_RPC_PROXY` is set
> but `RPC_PROXY_URL` is missing on the server, the route returns 503 and the client
> falls through to the keyless fallback — no crash. CSP needs no change: `/api/rpc`
> is same-origin, already covered by `connect-src 'self'`.
>
> Without the proxy, the keyless public fallback still works — just less reliable
> under heavy load on free RPCs.

### Running the Sepolia rehearsal

Deploy + mint on Sepolia first, then point the dApp at it with three lines in
`app/.env.local`:

```bash
NEXT_PUBLIC_CHAIN_ID=11155111
NEXT_PUBLIC_RPC_URL=https://<your-sepolia-rpc>
# then sync the deployed addresses for the sepolia network:
#   npm run sync:addresses -- sepolia      (reads deploy/addresses/sepolia.json)
```

`npm run dev` (or `npm run build`) then reads the **live Sepolia contracts** —
home stats populate, a Sepolia wallet shows no "wrong network", claims / the
daily game / swaps all run against Sepolia. Unset the vars (or set
`NEXT_PUBLIC_CHAIN_ID=1`) and the same build is back on mainnet — no code change.

> Sepolia Uniswap addresses are from Uniswap's official docs (testnet). The
> mainnet Uniswap set carries a "verify before mainnet" note in `addresses.ts`.

## Layout

- `lib/contracts/` — chain config, registry (abi+address), clients, errors, explorer
- `lib/reads/` · `lib/hooks/` · `lib/events/` — read hooks, write lifecycle, chunked getLogs
- `lib/swap/` — V4 Quoter quote + UniversalRouter/Permit2 execute (canonical Uniswap)
- `components/` — `TxButton`, `TokenArt`, wallet UI, the seven surfaces' pieces
- `design/` — Agent 8's design system + [`HANDOFF.md`](design/HANDOFF.md) (do not edit)

Surfaces wired: home, mint, gallery + token due-diligence, daily game, rewards,
unbind, token/burn + royalties, the WORD swap, and the owner-gated admin
dashboard.
