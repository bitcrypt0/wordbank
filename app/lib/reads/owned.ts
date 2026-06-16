"use client";

import type { PublicClient } from "viem";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { enumerateOwnedTokens } from "@/lib/reads/ownerEnum";
import { useWallet } from "@/lib/wallet/WalletProvider";

/**
 * Tokens currently owned by an account. WordBank is not ERC721Enumerable (gas),
 * so ownership is discovered by enumerating the sequential id space `1..
 * totalMinted()` with `ownerOf` in multicall batches (early-stop at balanceOf) —
 * NOT by scanning Transfer logs, which restricted public RPCs refuse. See
 * lib/reads/ownerEnum.ts. Returns ascending tokenIds.
 */
export function useOwnedTokens() {
  const { account } = useWallet();

  return useChainData<number[]>(
    async (client: PublicClient) => {
      if (!isDeployed("wordBank")) throw new NotDeployedError();
      if (!account) return [];
      const bank = requireAddress("wordBank");

      const { owned } = await enumerateOwnedTokens(client, bank, account);
      return owned.map(Number);
    },
    [account],
    { enabled: !!account, refetchInterval: 30_000 },
  );
}
