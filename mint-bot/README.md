# WORDBANK Mint Bot

A standalone, **owner-run** tool to mint WORDBANK NFTs on **mainnet** from
**multiple imported wallets** — **one mint transaction per wallet, all fired
together**. It is phase-aware: it reads the live sale phase and calls
`earlyBirdMint` or `publicMint` accordingly, sending the exact on-chain price.

It is **not** part of the production dApp (`app/`). It is a simple, careful
multi-wallet minter — **not** a high-speed mass-minter. Correctness and safety
come before speed: this spends real ETH.

> ## ⚠️ Security — this is a key-handling tool
> - It holds the **private keys** of the wallets you import (and, optionally,
>   your **primary key** for funding/sweeping). Everything stays **in your
>   browser** (client-side `ethers`) — nothing is sent anywhere except your
>   chosen RPC.
> - **Never commit keys.** `.env`, `mint-wallets/`, `wallets.json`,
>   `wallets-*.json`, and `*.key` are gitignored.
> - Exported `wallets.json` is **plaintext private keys** — store it offline and
>   delete it after use. Use wallets you control; do not paste a key you can't
>   afford to expose into any browser tool.

## What it does

- **Import N wallets** (JSON `[{address,privateKey}]`, or paste one private key
  per line). Generate/export are kept as a secondary convenience.
- **One "Mint" action.** Each imported wallet sends **exactly one** mint
  transaction; all of them are fired together (`Promise.allSettled`). Each
  wallet is its own signer with its own nonce, so there is no cross-wallet nonce
  contention and one wallet's revert never blocks the others.
- **"NFTs per wallet" count** (default `1`) — every wallet mints that many in
  its single transaction.
- **Phase-aware + exact value.** It reads `phase()` on-chain. In **Early Bird**
  it calls `earlyBirdMint(count)`; in **Public Sale** it calls
  `publicMint(count)`; in any other phase minting is disabled with a clear
  reason. The `msg.value` is **always** `price × count`, with the price read
  live from the contract (`earlyBirdPrice` / `publicPrice`) — never hardcoded
  (the contract reverts `WrongPayment` on a mismatch).
- **Early-bird wallet cap respected.** In early bird it checks
  `earlyBirdWalletCap` against each wallet's `earlyBirdMintedBy` and flags any
  wallet whose `count` would exceed the cap. A cap of **0 blocks all** early-bird
  mints.
- **Underfunded-wallet guard.** Before sending, each wallet's balance is checked
  against `value + estimated gas`. Wallets that can't cover it are **skipped and
  flagged** (so they never revert on-chain), not sent.
- **Per-wallet results.** Each wallet shows pending → tx hash (Etherscan link) →
  success / fail with the revert reason.
- **Read-only sale dashboard:** live phase, early-bird/public minted vs
  allocations, prices, and the early-bird wallet cap.
- **Optional fund-from-primary + sweep** helpers (simple parallel sends).
- **Sale admin** (set config / open phases / admin mint) is kept as a
  **secondary** convenience — the dApp admin panel now owns sale configuration.

## Setup

```bash
cd mint-bot
npm install
npm run sync:abi      # regenerates lib/WordBank.json from ../out (after any forge build)
npm run dev           # http://localhost:5173
```

The WordBank ABI in `lib/WordBank.json` is **synced from Foundry `out/`**, never
hand-copied (`npm run sync:abi` ⟵ `../out/WordBank.sol/WordBank.json`).

Config is entered in the UI (no keys in files): **RPC URL**, **chain ID**,
**WordBank address**, and (only for fund/sweep/admin) a **primary private key**.

For mainnet: paste a mainnet RPC URL, chain ID `1`, and the live WordBank
address `0x63a92C4E448847c906b7657C20630650e6bA1218`.

## How to mint on mainnet

1. **Connect.** Paste your mainnet RPC URL, chain ID `1`, and the WordBank
   address. The **Sale dashboard** populates with the live phase, prices,
   minted vs allocations, and the early-bird wallet cap. Confirm the phase is
   **Early Bird** or **Public Sale** — minting is disabled in any other phase.
2. **🔴 Smoke test FIRST — one wallet, count 1.** Import a **single** wallet
   (one you've already funded with the mint price + a little gas), set **NFTs
   per wallet = 1**, and press **Mint**. Watch the per-wallet result go pending
   → tx hash → success, and confirm the NFT arrived (check the dashboard count
   and the wallet on Etherscan). **Do not proceed until this works.**
3. **Import the rest.** Once the smoke test succeeds, import all the wallets you
   want to mint from (JSON file or paste keys). Make sure each is funded with at
   least `price × count + gas` — the bot will skip any that aren't and tell you.
4. **Set "NFTs per wallet"** (default 1). The preview shows the exact function
   it will call and the exact ETH value per wallet.
5. **Press Mint.** Every cleared wallet fires one `earlyBirdMint`/`publicMint`
   transaction together. Watch the per-wallet results; click each tx link to
   view it on Etherscan.
6. **(Optional) Fund / sweep.** If your wallets need ETH, use **Fund wallets**
   (sends from the primary key). After minting, **Sweep → primary** returns
   leftover ETH.

### Early-bird notes

- In early bird, each wallet is capped at `earlyBirdWalletCap` total mints. If a
  wallet has already minted some, the bot accounts for that (`earlyBirdMintedBy`)
  and skips a wallet whose new count would exceed the cap.
- If the cap is **0**, early-bird minting is blocked for everyone — the bot
  disables the Mint button and says so.

## Verifying the mint logic (no broadcast)

You can't broadcast real mainnet mints from a dev box, so the correctness-
critical assembly lives in pure, testable functions in `lib/mint.ts`
(phase → function, exact `value = price × count`, early-bird cap, underfunded
detection). Run the check (it transpiles and imports the real module, so the
test can't drift from the shipped code):

```bash
npm run check:mint
```

It proves: each phase selects the right function and unit price; the value is
computed exactly with BigInt (including odd prices, with no float drift);
out-of-cap early-bird mints are flagged (and cap 0 blocks all); and wallets
short on `value + gas` are detected as underfunded.

## Scripts

| Command | What |
|---|---|
| `npm run sync:abi` | Regenerate `lib/WordBank.json` from `../out` |
| `npm run check:mint` | Run the no-network mint-assembly correctness check |
| `npm run dev` | Dev server (http://localhost:5173) |
| `npm run build` / `npm start` | Production build / serve |
| `npm run typecheck` | `tsc` |
