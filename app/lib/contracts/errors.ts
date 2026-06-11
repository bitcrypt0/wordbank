/**
 * Human-readable revert decoding. Every write simulates first; when a call
 * reverts (in simulation or on-chain), we walk the viem error to the contract
 * revert, recover the custom-error name from the synced ABIs, and map the ones
 * the user can actually hit to plain-English copy. Unknown reverts fall back to
 * the error name; non-revert failures (rejections, RPC) get sensible text.
 */
import {
  BaseError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
} from "viem";

/** Custom-error name → owner-readable copy. Names match src/ contracts. */
const FRIENDLY: Record<string, string> = {
  // Game / registry (BountyEngine, WordBank)
  RegistryNotSynced: "The daily game hasn't started yet — it opens once the sale sells out and the word registry is built.",
  NotWordHolder: "You need to hold at least one word to start the daily draw.",
  CommitTooSoon: "The daily draw has already run for this cycle. Try again after the next cycle opens.",
  AlreadyCommitted: "A draw is already in progress for this cycle.",
  NoCommit: "There's no pending draw to act on.",
  RevealTooEarly: "Too early to reveal — wait for the reveal block.",
  RevealWindowPassed: "The reveal window has passed. The draw can be cleared and restarted.",
  NotClaimable: "This word isn't eligible to claim on this sentence.",
  AlreadyClaimed: "This bounty share has already been claimed.",
  ClaimWindowClosed: "The 7-day claim window for this sentence has closed.",
  // Mint / sale (WordBank)
  WrongPhase: "The sale isn't in the right phase for that action right now.",
  SaleNotOpen: "The sale isn't open yet.",
  WalletCapExceeded: "That would exceed your early-bird wallet cap.",
  AllocationExhausted: "This phase is sold out.",
  IncorrectPayment: "The ETH sent doesn't match the price. Try again.",
  // Unbind / backing (WordBank)
  NotOwner: "You don't own this token.",
  NotAlive: "This word has already been unbound.",
  // Swap / hook (FeeHook + Uniswap V4 router)
  TradingNotEnabled: "Trading isn't enabled yet — swaps open when the team flips the one-time trading switch.",
  BuyExceedsLaunchCap: "During the launch window, a single buy is capped at 10,000 WORD. Lower the amount.",
  V4TooLittleReceived: "Price moved past your slippage limit — you'd receive less than your minimum. Raise slippage or retry.",
  V4TooMuchRequested: "Price moved past your slippage limit — it would cost more than your maximum. Raise slippage or retry.",
  TooMuchRequested: "Price moved past your slippage limit — it would cost more than your maximum. Raise slippage or retry.",
  TransactionDeadlinePassed: "The swap took too long and its deadline passed. Try again.",
  ETHNotAccepted: "The router rejected the ETH value for this swap. Try again.",
  // Burn (BurnEngine)
  NothingToBurn: "There's no burnable excess right now — burning resumes after a word is unbound.",
  BuybackTooSoon: "A buyback already ran in this block. Try again shortly.",
  BelowMinBuyback: "There isn't enough accrued ETH for a buyback yet.",
  // Royalty splitter
  NothingToDistribute: "There's nothing to distribute right now.",
  NothingPending: "There's no admin slice pending withdrawal.",
  CannotRescueWeth: "WETH can't be rescued — it's part of the trustless split.",
  // Admin bounds (defense-in-depth; UI blocks these before send)
  ExceedsMaxFee: "Fee exceeds the 2% ceiling.",
  ExceedsMaxRoyalty: "Royalty exceeds the 10% ceiling.",
  ExceedsMaxSlippage: "Slippage exceeds the 5% ceiling.",
  InvalidSplit: "The split values are out of bounds or don't sum to 100%.",
};

export interface DecodedError {
  /** Owner-readable message for the UI. */
  message: string;
  /** Raw custom-error name if one was recovered (for logs/telemetry). */
  errorName?: string;
  /** True when the user rejected the request in their wallet. */
  rejected: boolean;
}

export function decodeError(err: unknown): DecodedError {
  if (err instanceof BaseError) {
    // Wallet rejection — not an error to surface loudly.
    const rejected = err.walk((e) => e instanceof UserRejectedRequestError);
    if (rejected) {
      return { message: "You rejected the request.", rejected: true };
    }
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName ?? revert.reason ?? undefined;
      if (name && FRIENDLY[name]) {
        return { message: FRIENDLY[name], errorName: name, rejected: false };
      }
      if (name) {
        return {
          message: `The transaction would fail (${name}). It was not sent.`,
          errorName: name,
          rejected: false,
        };
      }
    }
    return { message: err.shortMessage ?? err.message, rejected: false };
  }
  const message =
    typeof err === "object" && err && "message" in err
      ? String((err as { message: unknown }).message)
      : "Something went wrong.";
  return { message, rejected: false };
}
