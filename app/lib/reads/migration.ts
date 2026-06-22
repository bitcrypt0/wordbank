"use client";

import { type PublicClient } from "viem";
import { wordMigratorAbi, wordTokenAbi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { useWallet } from "@/lib/wallet/WalletProvider";

/** A single holder's migration entry, as emitted by deploy/scripts/snapshot-merkle.ts. */
export interface MigrationClaim {
  oldAmount: string; // snapshot old-WORD balance to burn (wei)
  newAmount: string; // new-WORD allocation to receive (wei)
  proof: string[]; // Merkle proof
}

/** The snapshot proofs file (app/public/migration-proofs.json). */
export interface MigrationProofs {
  root: string;
  snapshotBlock?: string;
  claims: Record<string, MigrationClaim>;
}

export interface MigrationOnchain {
  /** True once this wallet has migrated. */
  claimed: boolean;
  /** This wallet's current old-WORD balance (must be ≥ its snapshot amount to burn it). */
  oldBalanceWei: bigint;
  /** This wallet's old-WORD approval to the migrator. */
  allowanceWei: bigint;
}

/** Reads the on-chain side of migration (claimed flag + old-WORD balance/allowance). The
 *  eligibility + amounts come from the proofs file, fetched separately by the page. */
export function useMigrationOnchain() {
  const { account } = useWallet();

  return useChainData<MigrationOnchain>(
    async (client: PublicClient) => {
      if (!isDeployed("wordMigrator") || !isDeployed("wordToken")) throw new NotDeployedError();
      const migrator = requireAddress("wordMigrator");
      const oldToken = requireAddress("wordToken");
      if (!account) return { claimed: false, oldBalanceWei: 0n, allowanceWei: 0n };

      const [claimed, bal, allowance] = (await client.multicall({
        allowFailure: false,
        contracts: [
          { address: migrator, abi: wordMigratorAbi, functionName: "claimed", args: [account] },
          { address: oldToken, abi: wordTokenAbi, functionName: "balanceOf", args: [account] },
          { address: oldToken, abi: wordTokenAbi, functionName: "allowance", args: [account, migrator] },
        ],
      })) as [boolean, bigint, bigint];

      return { claimed, oldBalanceWei: bal, allowanceWei: allowance };
    },
    [account],
    { refetchInterval: 20_000, preferWalletRpc: true },
  );
}
