/**
 * Pure mint-assembly logic for the WORDBANK mint bot.
 *
 * This module holds the *correctness-critical* decisions — which contract
 * function to call for the live phase, the exact msg.value to send, and the
 * underfunded-wallet guard — as PURE functions with no React, no ethers
 * provider, and no network. That keeps them unit-testable (see
 * scripts/check-mint.mjs) so we can prove the assembly is right without
 * broadcasting a real mainnet tx.
 *
 * MAINNET SAFETY: msg.value is ALWAYS price × count read live from the
 * contract — never hardcoded. The contract reverts (WrongPayment) on any
 * mismatch, so getting this exactly right is the whole job.
 */

/** WordBank SalePhase enum (src/WordBank.sol) — order is ABI-stable. */
export enum SalePhase {
  Setup = 0,
  EarlyBird = 1,
  Between = 2,
  PublicSale = 3,
}

export const PHASE_LABEL: Record<number, string> = {
  [SalePhase.Setup]: 'Setup',
  [SalePhase.EarlyBird]: 'Early Bird',
  [SalePhase.Between]: 'Between',
  [SalePhase.PublicSale]: 'Public Sale',
};

/** The mintable phases and the function each one uses. */
export interface MintPlan {
  /** Whether minting is possible in the current phase. */
  mintable: boolean;
  /** The exact contract function to call (only set when mintable). */
  fn?: 'earlyBirdMint' | 'publicMint';
  /** The per-tx unit price in wei for the live phase (only set when mintable). */
  unitPriceWei?: bigint;
  /** Human-readable reason minting is disabled (only set when NOT mintable). */
  reason?: string;
}

/**
 * Decide, from the live on-chain phase, which mint function to call and at what
 * unit price. EarlyBird → earlyBirdMint(count) @ earlyBirdPrice;
 * PublicSale → publicMint(count) @ publicPrice; every other phase disables
 * minting with a clear reason.
 */
export function selectMintPlan(
  phase: number,
  earlyBirdPriceWei: bigint,
  publicPriceWei: bigint,
): MintPlan {
  switch (phase) {
    case SalePhase.EarlyBird:
      return { mintable: true, fn: 'earlyBirdMint', unitPriceWei: earlyBirdPriceWei };
    case SalePhase.PublicSale:
      return { mintable: true, fn: 'publicMint', unitPriceWei: publicPriceWei };
    case SalePhase.Setup:
      return { mintable: false, reason: 'Sale is in Setup — minting is not open yet.' };
    case SalePhase.Between:
      return {
        mintable: false,
        reason: 'Early bird is closed and the public sale has not opened — minting is paused.',
      };
    default:
      return { mintable: false, reason: `Unknown phase (${phase}) — minting disabled.` };
  }
}

/**
 * The exact msg.value for one mint tx. value = unitPrice × count, computed in
 * wei with BigInt (no float). count must be a positive integer.
 */
export function mintValueWei(unitPriceWei: bigint, count: number): bigint {
  if (!Number.isInteger(count) || count <= 0) {
    throw new Error(`count must be a positive integer, got ${count}`);
  }
  return unitPriceWei * BigInt(count);
}

/**
 * Early-bird per-wallet cap check. The contract enforces earlyBirdWalletCap per
 * wallet across the whole early-bird phase; a cap of 0 blocks ALL early-bird
 * mints. We flag a wallet whose (alreadyMinted + count) would exceed the cap so
 * it is skipped client-side rather than reverting on-chain.
 *
 * Returns { ok, reason } — reason is set only when ok === false.
 */
export function earlyBirdCapCheck(
  walletCap: bigint,
  alreadyMintedByWallet: bigint,
  count: number,
): { ok: boolean; reason?: string } {
  if (walletCap === 0n) {
    return { ok: false, reason: 'Early-bird wallet cap is 0 — early-bird minting is blocked for all wallets.' };
  }
  const after = alreadyMintedByWallet + BigInt(count);
  if (after > walletCap) {
    return {
      ok: false,
      reason: `Would exceed early-bird wallet cap (${alreadyMintedByWallet.toString()} already + ${count} > cap ${walletCap.toString()}).`,
    };
  }
  return { ok: true };
}

/**
 * Underfunded-wallet guard. A wallet can only mint if its balance covers the
 * mint value PLUS the estimated gas cost (gasLimit × gasPriceWei). We add a
 * small safety pad so a tiny fee bump at broadcast time doesn't cause a revert.
 *
 * Returns the required wei and whether the balance is sufficient.
 */
export function fundingCheck(params: {
  balanceWei: bigint;
  valueWei: bigint;
  gasLimit: bigint;
  gasPriceWei: bigint;
  /** Extra headroom on the gas estimate, in basis points (default 1500 = +15%). */
  gasPadBps?: bigint;
}): { ok: boolean; requiredWei: bigint; shortfallWei: bigint } {
  const padBps = params.gasPadBps ?? 1500n;
  const gasCost = params.gasLimit * params.gasPriceWei;
  const paddedGas = (gasCost * (10000n + padBps)) / 10000n;
  const requiredWei = params.valueWei + paddedGas;
  const ok = params.balanceWei >= requiredWei;
  const shortfallWei = ok ? 0n : requiredWei - params.balanceWei;
  return { ok, requiredWei, shortfallWei };
}
