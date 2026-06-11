/**
 * Contract registry — pairs each contract's synced ABI with its deployed
 * address. The single place components resolve "which contract + which ABI".
 * Addresses come from deployed.json (sync:addresses); ABIs from out/ (sync:abis).
 */
import {
  wordTokenAbi,
  wordBankAbi,
  rendererAbi,
  rewardsDistributorAbi,
  bountyEngineAbi,
  burnEngineAbi,
  feeHookAbi,
  lpLockerAbi,
  royaltySplitterAbi,
} from "./abis";
import { OUR_ADDRESSES, type Address, type ContractKey } from "./addresses";

/** ABI per contract key (always available, even pre-deployment). */
export const ABIS = {
  wordToken: wordTokenAbi,
  wordBank: wordBankAbi,
  renderer: rendererAbi,
  rewardsDistributor: rewardsDistributorAbi,
  bountyEngine: bountyEngineAbi,
  burnEngine: burnEngineAbi,
  feeHook: feeHookAbi,
  lpLocker: lpLockerAbi,
  royaltySplitter: royaltySplitterAbi,
} as const;

export type ContractConfig = {
  address: Address;
  abi: (typeof ABIS)[ContractKey];
};

/** All ABIs as a flat list — used by the error decoder to resolve any revert. */
export const ALL_ABIS = Object.values(ABIS);

/**
 * viem-ready `{ address, abi }` for a contract, or null when not yet deployed
 * (callers render the designed "pending deployment" state instead of reading).
 */
export function contract(key: ContractKey): ContractConfig | null {
  const address = OUR_ADDRESSES[key];
  if (!address) return null;
  return { address, abi: ABIS[key] };
}
