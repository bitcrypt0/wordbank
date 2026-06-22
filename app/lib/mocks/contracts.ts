/**
 * Contract directory — THE ETHERSCAN LINK SEAM.
 *
 * WIRED (agent 9): addresses now come from the deploy-addresses config
 * (lib/contracts/addresses → OUR_ADDRESSES, filled by `npm run sync:addresses`),
 * never hand-typed here. The Docs contracts section renders a live Etherscan
 * link wherever an address exists, and the designed "pending deployment" state
 * wherever it is still null (pre-deploy).
 */
import { OUR_ADDRESSES, type ContractKey } from "@/lib/contracts/addresses";
import { ETHERSCAN_BASE } from "@/lib/contracts/explorer";

export { ETHERSCAN_BASE };

export interface ContractInfo {
  name: string;
  /** Owner-readable one-liner (from WHITEPAPER-PUBLIC.md §13). */
  description: string;
  /** Deployed address from config — null until deployment. */
  address: string | null;
}

interface ContractDef {
  key: ContractKey;
  name: string;
  description: string;
}

const DEFS: ContractDef[] = [
  // ── Active: the relaunch ──
  { key: "wordTokenV2", name: "WordTokenV2 (WORD)", description: "The WORD ERC-20 — fixed 1,000,000 supply, no minting, no bonding." },
  { key: "wordStaking", name: "WordStaking", description: "Stake WORD to earn 50% of the swap fee, paid in ETH." },
  { key: "wordMigrator", name: "WordMigrator", description: "One-way migration: snapshot holders burn old WORD to claim the new token." },
  { key: "feeHookV2", name: "FeeHookV2", description: "Skims the 1% trading fee and routes the fixed 25 / 25 / 50 split." },
  // ── Reused from the original launch ──
  { key: "wordBank", name: "WordBank", description: "The 10,000 word NFTs, the registry, and the unbind path." },
  { key: "renderer", name: "Renderer", description: "Assembles each NFT's artwork onchain." },
  { key: "rewardsDistributor", name: "RewardsDistributor", description: "Splits the 25% NFT-holder rewards slice equally across living NFTs." },
  { key: "bountyEngine", name: "BountyEngine", description: "The daily game: commit-reveal draw, prizes, claims (funded by 25% of the fee)." },
  { key: "royaltySplitter", name: "RoyaltySplitter", description: "Receives marketplace NFT royalties and forwards them in immutable equal thirds." },
  // ── Deprecated original WORD economy (still on-chain, no longer used) ──
  { key: "wordToken", name: "WordToken (deprecated)", description: "The original WORD ERC-20, replaced by WordTokenV2. Convert via the migrator." },
  { key: "feeHook", name: "FeeHook (deprecated)", description: "The original pool's fee hook, replaced by FeeHookV2." },
  { key: "burnEngine", name: "BurnEngine (deprecated)", description: "The original buy-and-burn, retired in the relaunch." },
  { key: "lpLocker", name: "LPLocker (deprecated)", description: "The original liquidity lock; the relaunch pool is locked on UNCX." },
];

export const CONTRACTS: ContractInfo[] = DEFS.map((d) => ({
  name: d.name,
  description: d.description,
  address: OUR_ADDRESSES[d.key],
}));

export function etherscanUrl(c: ContractInfo): string | null {
  return c.address ? `${ETHERSCAN_BASE}${c.address}` : null;
}
