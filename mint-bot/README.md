# WORDBANK Mint Bot

A standalone, **owner-run** tool to drive a WordBank sale to the **9,800 public
sellout** (the event that arms the provenance reveal) so you can rehearse the
full launch on a testnet or a local fork: reveal → registry build → reward
claims → daily game → swaps → seal → buyback.

It is **not** part of the production dApp (`app/`). It adapts a multi-wallet
mint-bot reference: generate/import wallets, fund them from a primary key,
mass-mint across them with batched broadcast + retry/backoff, and sweep the
leftover ETH back.

> ## ⚠️ Security — this is a key-handling tool
> - It takes your **primary private key** and can generate/hold **many wallet
>   private keys**. Everything stays **in your browser** (client-side ethers) —
>   nothing is sent anywhere except your chosen RPC.
> - **Never commit keys.** `.env`, `wallets.json`, and `*.key*` are gitignored.
>   Use a throwaway funder key for rehearsals; do not reuse a mainnet key you
>   care about on a testnet bot.
> - Exported `wallets.json` is **plaintext private keys** — store it offline and
>   delete it after the rehearsal.

## Setup

```bash
cd mint-bot
npm install
npm run sync:abi      # regenerates lib/WordBank.json from ../out (after any forge build)
npm run dev           # http://localhost:5173
```

The WordBank ABI in `lib/WordBank.json` is **synced from Foundry `out/`**, never
hand-copied (`npm run sync:abi` ⟵ `../out/WordBank.sol/WordBank.json`).

Config is entered in the UI (no keys in files): **RPC URL** (http or ws —
Sepolia, a local mainnet-fork, or mainnet), **WordBank address**, **primary
private key**.

- Sepolia chainId `11155111`; local-fork keeps mainnet chainId `1`. Sepolia V4
  infra addresses are in the deploy runbook if you also rehearse swaps.

## The exact rehearsal mint sequence

Assumes WordBank is deployed and **setup is complete** (slots locked, renderer +
rewards distributor wired — Agent 5's deploy scripts do this). The bot covers
sale config → phases → minting → sellout.

1. **Connect** — paste RPC URL, WordBank address, and the owner/funder private key.
   The **Sale dashboard** shows phase, minted vs allocations, prices, and % to 9,800.
2. **Configure the sale** (Sale admin panel, owner only). For a fast public-only
   rehearsal: EB allocation `0`, public allocation `9800`, public price e.g.
   `0.02`, then **Set sale config**. (EB + public + 200 reserve must equal 10,000.)
3. **Open the sale**: **Open early bird** → **Close early bird** → **Open public
   sale** (Setup→EarlyBird→Between→PublicSale). With EB allocation 0 you can
   still walk the phases.
   - (Optional) exercise **early bird** first: open EB, mint a few via wallets,
     then close. EB auto-advances to public on EB sellout.
4. **Wallets** — set a count (e.g. 50), **Generate**, then **Fund wallets** from
   the primary key (funding each ≥ `publicPrice × NFTs-per-tx` + gas). **Export**
   to back up the keys.
5. **Mass mint → public sellout** — set **NFTs per tx** (~100; the contract has
   no per-tx cap, but the block gas limit does — drop it if a tx runs out of
   gas) and **Target NFTs** `0` (mint the whole remaining public allocation).
   Press **Mint to public sellout**. The bot splits the remainder into
   `publicMint(count)` txs, spreads them round-robin across the funded wallets
   (realistic ownership distribution for claim/transfer/reward tests), sends
   exactly `publicPrice × count` per tx (else `WrongPayment`), and batches the
   broadcast with retry/backoff. Watch the dashboard climb to **9,800 / 9,800
   (100%)** — that arms the provenance reveal.
6. **Admin reserve** (optional) — **Admin mint** up to 200 to any address, any phase.
7. **Sweep** — **Sweep all → primary** returns leftover ETH from the wallets.

Then continue the rehearsal in the dApp (`app/`): reveal offset → build registry
→ claim rewards → play the daily game → enable trading + swap → seal + renounce
→ buyback.

## Smoke test on a local mainnet-fork (no testnet needed)

```bash
# repo root: build artifacts, fork mainnet (keeps chainId 1), deploy
forge build
anvil --fork-url $MAINNET_RPC_URL --chain-id 1
cd deploy && npx hardhat run scripts/01-deploy-protocol.ts --network localhost
#   ...renderer content, lockSlots, then setSaleConfig/open phases (or use this bot)
# bot: RPC http://127.0.0.1:8545, the deployed WordBank address, an anvil key
```

Anvil's pre-funded accounts make funding instant; mint a few hundred to confirm
the dashboard + batching, then the full 9,800 if you want the reveal to arm.

> **Note (this environment):** Foundry/`anvil` and a mainnet RPC were not
> available where this bot was built, so the live 9,800 run is documented here
> rather than executed. The bot itself builds, typechecks, boots, and renders
> the live dashboard; the mint path uses the synced ABI + the exact
> `publicMint(count)` / `setSaleConfig` / phase ABIs from `src/WordBank.sol`.

## Scripts

| Command | What |
|---|---|
| `npm run sync:abi` | Regenerate `lib/WordBank.json` from `../out` |
| `npm run dev` | Dev server (http://localhost:5173) |
| `npm run build` / `npm start` | Production build / serve |
| `npm run typecheck` | `tsc` |
