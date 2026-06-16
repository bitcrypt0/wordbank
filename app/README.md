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
| `NEXT_PUBLIC_RPC_URL` | _(unset → wallet / public fallback)_ | **OPTIONAL** public pre-connect read RPC |

With the default (unset) it targets **mainnet**. The wrong-network banner and the
one-click switch always target the configured chain, and the WORD swap uses that
chain's canonical Uniswap V4 set (mainnet vs. Sepolia, in `lib/contracts/addresses.ts`).

#### RPC: the dApp never ships the owner's key

Chain reads (balances, stats, events, simulation) resolve in this order
(`lib/contracts/chain.ts`):

1. **Connected wallet** → reads ride the **visitor's own node** via their wallet's
   EIP-1193 provider (viem `custom(provider)`). The dApp never proxies our RPC.
2. **`NEXT_PUBLIC_RPC_URL`**, *only if set* → used before a wallet connects. It is
   **optional** and must be a **PUBLIC / keyless** URL — `NEXT_PUBLIC_*` is inlined
   into the browser bundle, so an Alchemy/Infura key here would be exposed to every
   visitor.
3. **Public fallback** → an explicit viem `fallback([...])` of **keyless** public
   endpoints, ordered best-first (mainnet: `ethereum-rpc.publicnode.com` →
   `eth.drpc.org` → `1rpc.io/eth`). These are NOT viem's chain default
   (cloudflare-eth): cloudflare/merkle/llama all return `-32603` on the V4 Quoter's
   heavy `eth_call`, so swap quotes showed `0` for disconnected visitors. The
   chosen endpoints are each verified to execute the quoter against the live
   mainnet pool; viem rotates to the next on any error.

The dApp works fully with `NEXT_PUBLIC_RPC_URL` **unset** (it falls back to the
keyless list above, which CAN run the quoter). In Vercel, set only
`NEXT_PUBLIC_CHAIN_ID=1` (and optionally a *public* `NEXT_PUBLIC_RPC_URL`, e.g.
`https://ethereum-rpc.publicnode.com`, to pin the pre-connect fallback) —
**never** the Alchemy/Infura key. The wrong-network guard reads the chainId from
the wallet provider, so it keeps working regardless of which read path is active.

> **Degradation note (pre-connect only):** the public-default RPCs are aggressively
> rate-limited and cap `eth_getLogs` ranges/results. The event-history loader
> (`lib/events/logs.ts`) already auto-shrinks oversized windows, backs off on 429s,
> and surfaces partial results via gaps — so history still loads, just slower /
> best-effort, before a wallet connects. Once a wallet is connected, reads ride the
> wallet's RPC and behave normally. Setting a reliable **public** `NEXT_PUBLIC_RPC_URL`
> improves the pre-connect experience without exposing a key.

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
