/**
 * Mock-data types — the single seam agent 9 replaces with contract reads.
 *
 * Field-by-field, each value names the frozen-interface view that powers it
 * (src/interfaces/). Keep wei values as decimal strings: they become viem
 * bigints 1:1 at wiring time.
 */

/** Mirrors Types.sol `Category`. */
export type Category = "NOUN" | "VERB" | "ADJ" | "ADV";

export const CATEGORY_LABEL: Record<Category, string> = {
  NOUN: "Noun",
  VERB: "Verb",
  ADJ: "Adjective",
  ADV: "Adverb",
};

/** A revealed bounty share attached to a token (IBountyEngine). */
export interface MockBountyShare {
  /** Event the word appeared in. */
  eventId: number;
  /** IBountyEngine.eventInfo(eventId).sharePerWord — wei string. */
  sharePerWordWei: string;
  /** IBountyEngine.eventInfo(eventId).deadline — ISO timestamp. */
  deadline: string;
  /** IBountyEngine.isClaimable(eventId, tokenId). */
  claimable: boolean;
}

export interface MockToken {
  tokenId: number;
  /** IWordBank.wordOf(tokenId) */
  word: string;
  /** IWordBank.categoryOf(tokenId) */
  category: Category;
  /** WordData trait indices into the Renderer tables (from tokenURI metadata). */
  material: number;
  ink: number;
  background: number;
  /** WordData.honors — 25 one-of-ones with bespoke path art. */
  honors: boolean;
  /** Static file for honors art (regular words render from fragments). */
  honorsArtSrc?: string;
  /** IWordBank.isAlive(tokenId) — false after unbind (NFT burned). */
  alive: boolean;
  /** IWordBank.ownerOf(tokenId) — reverts on burned ids onchain; null here. */
  owner: string | null;
  /** IWordBank.bondedBalance(tokenId) — 1,000e18 alive, 0 after unbind. */
  bondedBalanceWei: string;
  /** IRewardsDistributor.pendingRewards(tokenId) — wei string. */
  pendingRewardsWei: string;
  /** Open bounty share, if this word appeared in a recent sentence. */
  bounty: MockBountyShare | null;
}

/** Protocol-level numbers for stat strips (sources noted per field). */
export interface MockProtocolStats {
  /** IWordToken.totalSupply() — wei string. */
  wordTotalSupplyWei: string;
  /** 11,000,000e18 − totalSupply — burned so far, wei string. */
  wordBurnedWei: string;
  /** IWordBank.totalAlive() */
  totalAlive: number;
  /** IWordBank.aliveCount(category) per category */
  aliveByCategory: Record<Category, number>;
  /** NFTs minted to date (mint progress, of 10,000) */
  minted: number;
  /** BountyEngine free treasury (balance − lockedFunds()) — wei string. */
  bountyTreasuryWei: string;
}
