"use client";

import type { PublicClient } from "viem";
import { wordBankAbi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { useWallet } from "@/lib/wallet/WalletProvider";

/** WordBank.phase() enum order (HANDOFF §3). */
export const PHASE = {
  Setup: 0,
  EarlyBird: 1,
  Between: 2,
  PublicSale: 3,
} as const;

export interface MintData {
  phase: number;
  earlyBirdPriceWei: bigint;
  publicPriceWei: bigint;
  earlyBirdMinted: number;
  earlyBirdAllocation: number;
  publicMinted: number;
  publicAllocation: number;
  earlyBirdWalletCap: number;
  yourEarlyBirdMinted: number;
  totalMinted: number;
  maxSupply: number;
  publicSupply: number;
  adminMinted: number;
  offsetSet: boolean;
}

const ZERO = "0x0000000000000000000000000000000000000000" as const;

export function useMintData() {
  const { account } = useWallet();

  return useChainData<MintData>(
    async (client: PublicClient) => {
      if (!isDeployed("wordBank")) throw new NotDeployedError();
      const address = requireAddress("wordBank");
      const base = { address, abi: wordBankAbi } as const;
      const viewer = (account ?? ZERO) as `0x${string}`;

      const r = await client.multicall({
        allowFailure: false,
        contracts: [
          { ...base, functionName: "phase" },
          { ...base, functionName: "earlyBirdPrice" },
          { ...base, functionName: "publicPrice" },
          { ...base, functionName: "earlyBirdMinted" },
          { ...base, functionName: "earlyBirdAllocation" },
          { ...base, functionName: "publicMinted" },
          { ...base, functionName: "publicAllocation" },
          { ...base, functionName: "earlyBirdWalletCap" },
          { ...base, functionName: "earlyBirdMintedBy", args: [viewer] },
          { ...base, functionName: "totalMinted" },
          { ...base, functionName: "MAX_SUPPLY" },
          { ...base, functionName: "PUBLIC_SUPPLY" },
          { ...base, functionName: "adminMinted" },
          { ...base, functionName: "offsetSet" },
        ],
      });

      return {
        phase: Number(r[0]),
        earlyBirdPriceWei: r[1] as bigint,
        publicPriceWei: r[2] as bigint,
        earlyBirdMinted: Number(r[3]),
        earlyBirdAllocation: Number(r[4]),
        publicMinted: Number(r[5]),
        publicAllocation: Number(r[6]),
        earlyBirdWalletCap: Number(r[7]),
        yourEarlyBirdMinted: Number(r[8]),
        totalMinted: Number(r[9]),
        maxSupply: Number(r[10]),
        publicSupply: Number(r[11]),
        adminMinted: Number(r[12]),
        offsetSet: Boolean(r[13]),
      };
    },
    [account],
  );
}
