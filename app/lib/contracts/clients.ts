/**
 * viem clients. Reads go through the shared public client (RPC); writes go
 * through a wallet client built on the connected injected provider.
 */
import { createWalletClient, custom, type WalletClient } from "viem";
import { CHAIN } from "./chain";
import type { Eip1193Provider } from "@/lib/wallet/types";

/** Build a wallet client for the connected account (write path). */
export function getWalletClient(
  provider: Eip1193Provider,
  account: `0x${string}`,
): WalletClient {
  return createWalletClient({
    account,
    chain: CHAIN,
    transport: custom(provider as Parameters<typeof custom>[0]),
  });
}
