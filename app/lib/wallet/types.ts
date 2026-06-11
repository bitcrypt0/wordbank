/**
 * EIP-1193 / EIP-6963 types for the injected-only wallet layer.
 * No third-party connection SDK is used or permitted (root AGENTS.md).
 */

/** Minimal EIP-1193 provider surface the dApp relies on. */
export interface Eip1193Provider {
  request(args: { method: string; params?: unknown[] | object }): Promise<unknown>;
  on?(event: string, handler: (...args: unknown[]) => void): void;
  removeListener?(event: string, handler: (...args: unknown[]) => void): void;
}

/** EIP-6963 provider identity (name/icon/rdns) announced by each wallet. */
export interface Eip6963ProviderInfo {
  uuid: string;
  name: string;
  icon: string;
  rdns: string;
}

export interface Eip6963ProviderDetail {
  info: Eip6963ProviderInfo;
  provider: Eip1193Provider;
}

/** The `eip6963:announceProvider` CustomEvent payload. */
export type Eip6963AnnounceEvent = CustomEvent<Eip6963ProviderDetail>;

/** Common EIP-1193 / JSON-RPC error codes we special-case. */
export const RPC_ERRORS = {
  /** User rejected the request (e.g. closed the connect prompt). */
  USER_REJECTED: 4001,
  /** Chain not added to the wallet (switch failed → try add). */
  CHAIN_NOT_ADDED: 4902,
} as const;

export interface ProviderRpcError {
  code: number;
  message?: string;
}

export function isUserRejection(err: unknown): boolean {
  return (
    typeof err === "object" &&
    err !== null &&
    (err as ProviderRpcError).code === RPC_ERRORS.USER_REJECTED
  );
}
