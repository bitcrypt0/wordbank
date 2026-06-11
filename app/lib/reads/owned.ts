"use client";

import { getAbiItem, type AbiEvent, type PublicClient } from "viem";
import { wordBankAbi } from "@/lib/contracts/abis";
import { isDeployed, requireAddress } from "@/lib/contracts/addresses";
import { NotDeployedError, useChainData } from "@/lib/hooks/useChainData";
import { getLogsChunked } from "@/lib/events/logs";
import { useWallet } from "@/lib/wallet/WalletProvider";

const TRANSFER_EVENT = getAbiItem({ abi: wordBankAbi, name: "Transfer" }) as AbiEvent;

/**
 * Tokens currently owned by an account. WordBank is not ERC721Enumerable
 * (gas), so we discover candidates from Transfer-to logs (chunked getLogs, no
 * indexer) then confirm current ownership with ownerOf (burned ids revert and
 * are dropped). Returns ascending tokenIds.
 */
export function useOwnedTokens() {
  const { account } = useWallet();

  return useChainData<number[]>(
    async (client: PublicClient) => {
      if (!isDeployed("wordBank")) throw new NotDeployedError();
      if (!account) return [];
      const address = requireAddress("wordBank");

      const logs = await getLogsChunked(client, {
        address,
        event: TRANSFER_EVENT,
        args: { to: account },
      });
      const candidates = [
        ...new Set(
          logs.map((l) => (l as unknown as { args: { tokenId: bigint } }).args.tokenId),
        ),
      ];
      if (candidates.length === 0) return [];

      const owners = await client.multicall({
        allowFailure: true,
        contracts: candidates.map((tokenId) => ({
          address,
          abi: wordBankAbi,
          functionName: "ownerOf" as const,
          args: [tokenId],
        })),
      });

      const owned: number[] = [];
      candidates.forEach((tokenId, i) => {
        const res = owners[i];
        if (
          res.status === "success" &&
          typeof res.result === "string" &&
          res.result.toLowerCase() === account.toLowerCase()
        ) {
          owned.push(Number(tokenId));
        }
      });
      return owned.sort((a, b) => a - b);
    },
    [account],
    { enabled: !!account, refetchInterval: 30_000 },
  );
}
