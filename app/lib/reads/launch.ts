"use client";

import type { PublicClient } from "viem";
import { wordBankAbi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";

/** 256-block blockhash availability window (EVM). */
const BLOCKHASH_WINDOW = 256n;

export interface LaunchData {
  publicMinted: number; // earlyBirdMinted + publicMinted
  publicSupply: number; // PUBLIC_SUPPLY (9,800)
  offsetArmed: boolean; // offsetTargetBlock != 0
  offsetSet: boolean;
  /** Armed, unrevealed, target mined and still inside the 256-block window. */
  revealWindowOpen: boolean;
  /** Armed, unrevealed, target hash no longer available → rearm. */
  revealWindowLapsed: boolean;
  registryCursor: number;
  registryTarget: number; // preRevealMinted
  registrySynced: boolean;
}

export function useLaunchData() {
  return useChainData<LaunchData>(async (client: PublicClient) => {
    if (!isDeployed("wordBank")) throw new NotDeployedError();
    const address = requireAddress("wordBank");
    const base = { address, abi: wordBankAbi } as const;

    const [r, head] = await Promise.all([
      client.multicall({
        allowFailure: false,
        contracts: [
          { ...base, functionName: "earlyBirdMinted" },
          { ...base, functionName: "publicMinted" },
          { ...base, functionName: "PUBLIC_SUPPLY" },
          { ...base, functionName: "offsetTargetBlock" },
          { ...base, functionName: "offsetSet" },
          { ...base, functionName: "registryCursor" },
          { ...base, functionName: "preRevealMinted" },
          { ...base, functionName: "registrySynced" },
        ],
      }),
      client.getBlockNumber(),
    ]);

    const target = r[3] as bigint;
    const offsetSet = Boolean(r[4]);
    const armed = target !== 0n;
    const mined = head > target;
    const withinWindow = head <= target + BLOCKHASH_WINDOW;

    return {
      publicMinted: Number(r[0]) + Number(r[1]),
      publicSupply: Number(r[2]),
      offsetArmed: armed,
      offsetSet,
      revealWindowOpen: armed && !offsetSet && mined && withinWindow,
      revealWindowLapsed: armed && !offsetSet && mined && !withinWindow,
      registryCursor: Number(r[5]),
      registryTarget: Number(r[6]),
      registrySynced: Boolean(r[7]),
    };
  });
}

/** Batch size for buildRegistry — kept modest to bound gas per push. */
export const REGISTRY_BATCH = 2_000n;
