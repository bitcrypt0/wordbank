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
  { key: "wordToken", name: "WordToken", description: "The WORD ERC-20. 11M cap, sealed at launch, burnable down to the live backing floor." },
  { key: "wordBank", name: "WordBank", description: "The 10,000 NFTs, the locked backing, the word registry, and the unbind (cash-out) path." },
  { key: "renderer", name: "Renderer", description: "Assembles each NFT's artwork onchain." },
  { key: "rewardsDistributor", name: "RewardsDistributor", description: "Splits the 50% holder-rewards slice equally across living NFTs." },
  { key: "bountyEngine", name: "BountyEngine", description: "The daily game: templates, commit-reveal draw, prizes, claims." },
  { key: "burnEngine", name: "BurnEngine", description: "Buy-and-burn excess WORD down to the live backing floor, for the protocol's life." },
  { key: "feeHook", name: "FeeHook", description: "Skims the 1% trading fee and routes the three-way split." },
  { key: "lpLocker", name: "LPLocker", description: "Time-locks the initial liquidity." },
  { key: "royaltySplitter", name: "RoyaltySplitter", description: "Receives marketplace royalties and forwards them in immutable equal thirds — burn / bounty / team." },
];

export const CONTRACTS: ContractInfo[] = DEFS.map((d) => ({
  name: d.name,
  description: d.description,
  address: OUR_ADDRESSES[d.key],
}));

export function etherscanUrl(c: ContractInfo): string | null {
  return c.address ? `${ETHERSCAN_BASE}${c.address}` : null;
}
