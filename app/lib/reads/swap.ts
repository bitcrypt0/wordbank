"use client";

import type { PublicClient } from "viem";
import { wordTokenV2Abi, feeHookV2Abi } from "@/lib/contracts/abis";
import { permit2Abi } from "@/lib/contracts/uniswapAbis";
import { isDeployed, requireAddress, UNISWAP } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { useWallet } from "@/lib/wallet/WalletProvider";

export interface SwapData {
  // gate flags (readable without a connected account)
  tradingEnabled: boolean;
  guardActive: boolean;
  buyCapWei: bigint;
  // connected-wallet state (zero when disconnected)
  ethBalanceWei: bigint;
  wordBalanceWei: bigint;
  /** ERC-20 WORD allowance granted to Permit2 (one-time max approval). */
  erc20ToPermit2Wei: bigint;
  /** Permit2 allowance the UniversalRouter holds to pull WORD. */
  permit2AllowanceWei: bigint;
  /** Permit2 allowance expiry (unix seconds; 0 if none). */
  permit2Expiration: number;
}

export function useSwapData() {
  const { account } = useWallet();

  return useChainData<SwapData>(
    async (client: PublicClient) => {
      if (!isDeployed("wordTokenV2") || !isDeployed("feeHookV2")) throw new NotDeployedError();
      const word = requireAddress("wordTokenV2");
      const hook = requireAddress("feeHookV2");

      const gate = (await client.multicall({
        allowFailure: false,
        contracts: [
          { address: hook, abi: feeHookV2Abi, functionName: "tradingEnabledAt" },
          { address: hook, abi: feeHookV2Abi, functionName: "guardActive" },
          { address: hook, abi: feeHookV2Abi, functionName: "BUY_CAP" },
        ],
      })) as [bigint, boolean, bigint];

      let ethBalanceWei = 0n;
      let wordBalanceWei = 0n;
      let erc20ToPermit2Wei = 0n;
      let permit2AllowanceWei = 0n;
      let permit2Expiration = 0;

      if (account) {
        const [eth, wordReads, permit2] = await Promise.all([
          client.getBalance({ address: account }),
          client.multicall({
            allowFailure: false,
            contracts: [
              { address: word, abi: wordTokenV2Abi, functionName: "balanceOf", args: [account] },
              { address: word, abi: wordTokenV2Abi, functionName: "allowance", args: [account, UNISWAP.permit2] },
            ],
          }),
          client.readContract({
            address: UNISWAP.permit2,
            abi: permit2Abi,
            functionName: "allowance",
            args: [account, word, UNISWAP.universalRouter],
          }),
        ]);
        ethBalanceWei = eth;
        wordBalanceWei = (wordReads as [bigint, bigint])[0];
        erc20ToPermit2Wei = (wordReads as [bigint, bigint])[1];
        const p2 = permit2 as readonly [bigint, number, number];
        permit2AllowanceWei = p2[0];
        permit2Expiration = Number(p2[1]);
      }

      return {
        tradingEnabled: gate[0] > 0n,
        guardActive: gate[1],
        buyCapWei: gate[2],
        ethBalanceWei,
        wordBalanceWei,
        erc20ToPermit2Wei,
        permit2AllowanceWei,
        permit2Expiration,
      };
    },
    [account],
    { refetchInterval: 20_000 },
  );
}
