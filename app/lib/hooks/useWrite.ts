"use client";

import { useCallback, useState } from "react";
import type { Abi } from "viem";
import { getPublicClient } from "@/lib/contracts/chain";
import { getWalletClient } from "@/lib/contracts/clients";
import { decodeError } from "@/lib/contracts/errors";
import { useWallet } from "@/lib/wallet/WalletProvider";

export type WriteState =
  | "idle"
  | "simulating"
  | "pending" // user is signing in the wallet
  | "confirming" // broadcast, waiting for the receipt
  | "confirmed"
  | "error";

export interface WriteConfig {
  address: `0x${string}`;
  abi: Abi | readonly unknown[];
  functionName: string;
  args?: readonly unknown[];
  /** Payable value in wei. */
  value?: bigint;
}

export interface WriteResult {
  state: WriteState;
  error: string | null;
  txHash: `0x${string}` | null;
  /** Simulate → sign → wait. Resolves true on confirmation. */
  execute: (config: WriteConfig) => Promise<boolean>;
  reset: () => void;
}

/**
 * One write lifecycle. EVERY write goes through simulateContract first (so an
 * out-of-bounds / reverting call is never broadcast), then through the injected
 * wallet, then waits for the receipt. Custom-error reverts are decoded to plain
 * English. Wallet rejection returns cleanly to idle.
 */
export function useWrite(onConfirmed?: () => void): WriteResult {
  const { provider, account } = useWallet();
  const [state, setState] = useState<WriteState>("idle");
  const [error, setError] = useState<string | null>(null);
  const [txHash, setTxHash] = useState<`0x${string}` | null>(null);

  const reset = useCallback(() => {
    setState("idle");
    setError(null);
    setTxHash(null);
  }, []);

  const execute = useCallback(
    async (config: WriteConfig): Promise<boolean> => {
      if (!provider || !account) {
        setError("Connect your wallet first.");
        setState("error");
        return false;
      }
      setError(null);
      setTxHash(null);
      const publicClient = getPublicClient();
      const walletClient = getWalletClient(provider, account);
      try {
        setState("simulating");
        const { request } = await publicClient.simulateContract({
          account,
          address: config.address,
          abi: config.abi as Abi,
          functionName: config.functionName,
          args: config.args ?? [],
          value: config.value,
        });

        setState("pending");
        const hash = await walletClient.writeContract(request);
        setTxHash(hash);

        setState("confirming");
        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        if (receipt.status === "reverted") {
          setState("error");
          setError("The transaction was mined but reverted.");
          return false;
        }
        setState("confirmed");
        onConfirmed?.();
        return true;
      } catch (err) {
        const decoded = decodeError(err);
        // A clean rejection returns to idle without a loud error.
        setState(decoded.rejected ? "idle" : "error");
        setError(decoded.rejected ? null : decoded.message);
        return false;
      }
    },
    [provider, account, onConfirmed],
  );

  return { state, error, txHash, execute, reset };
}
