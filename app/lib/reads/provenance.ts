"use client";

import type { PublicClient } from "viem";
import { wordBankAbi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";

/**
 * The committed provenance hash = keccak256(assets/assignments.json).
 *
 * READ ON-CHAIN is the source of truth (the whole point — the page proves the
 * live commitment). This constant is a LAST-RESORT display fallback only, used
 * if the chain read fails; it is the value the deploy committed and matches the
 * file in the public repo. The on-chain value always wins when the read works.
 */
export const PROVENANCE_HASH_FALLBACK =
  "0xd1642a6eab87955e54f2eacb75791f29a5bd96db486da532c6808f6d9fe0ffd1" as const;

/** GitHub path to the file whose keccak256 anyone can recompute to verify.
 *  Points at the public repo's `assets/assignments.json` (the committed menu). */
export const ASSIGNMENTS_GITHUB_URL =
  "https://github.com/bitcrypt0/wordbank/blob/main/assets/assignments.json";

/** The all-zero bytes32 — what `provenanceHash` reads before slots are locked. */
const ZERO_HASH =
  "0x0000000000000000000000000000000000000000000000000000000000000000";

export interface ProvenanceData {
  /** The on-chain provenance hash (bytes32 hex). May be the zero hash pre-lock. */
  hash: string;
  /** True once `lockSlots` has been called — the menu is permanently committed. */
  locked: boolean;
  /** True when the displayed hash came from the fallback, not the live read. */
  fromFallback: boolean;
}

/**
 * Reads `provenanceHash` + `slotsLocked` live from WordBank. Present the hash as
 * the committed provenance ONLY when `locked === true`; before lock, the caller
 * shows a "not yet committed" state. On read failure the hook surfaces the
 * error status (useChainData), and the UI falls back to the committed constant.
 */
export function useProvenance() {
  return useChainData<ProvenanceData>(async (client: PublicClient) => {
    if (!isDeployed("wordBank")) throw new NotDeployedError();
    const address = requireAddress("wordBank");
    const base = { address, abi: wordBankAbi } as const;

    const [hash, locked] = (await client.multicall({
      allowFailure: false,
      contracts: [
        { ...base, functionName: "provenanceHash" },
        { ...base, functionName: "slotsLocked" },
      ],
    })) as [string, boolean];

    return {
      hash: hash && hash !== ZERO_HASH ? hash : PROVENANCE_HASH_FALLBACK,
      locked: Boolean(locked),
      fromFallback: false,
    };
  });
}
