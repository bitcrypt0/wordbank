/**
 * Mock EIP-1193 provider + EIP-6963 announcer for the wallet lifecycle tests.
 * No real wallet, no network — every branch of connect/reconnect/disconnect/
 * account-switch/network-switch is driven from here.
 */
import type { Eip1193Provider, Eip6963ProviderDetail } from "@/lib/wallet/types";

interface MockOpts {
  accounts?: string[];
  chainId?: number;
  /** True if the site is already authorized (eth_accounts returns accounts). */
  authorized?: boolean;
}

export class MockEip1193Provider implements Eip1193Provider {
  accounts: string[];
  chainId: number;
  authorized: boolean;
  private rejectRequest = false;
  private listeners = new Map<string, Set<(...a: unknown[]) => void>>();

  constructor(opts: MockOpts = {}) {
    this.accounts = opts.accounts ?? ["0x1111111111111111111111111111111111111111"];
    this.chainId = opts.chainId ?? 1;
    this.authorized = opts.authorized ?? false;
  }

  /** Make the next eth_requestAccounts reject as a user rejection (4001). */
  rejectNextConnect(): void {
    this.rejectRequest = true;
  }

  async request({ method, params }: { method: string; params?: unknown[] | object }): Promise<unknown> {
    switch (method) {
      case "eth_requestAccounts": {
        if (this.rejectRequest) {
          this.rejectRequest = false;
          throw { code: 4001, message: "User rejected the request." };
        }
        this.authorized = true;
        return this.accounts;
      }
      case "eth_accounts":
        return this.authorized ? this.accounts : [];
      case "eth_chainId":
        return `0x${this.chainId.toString(16)}`;
      case "wallet_switchEthereumChain": {
        const target = (params as Array<{ chainId: string }>)?.[0]?.chainId;
        if (target) this.emitChainChanged(Number.parseInt(target, 16));
        return null;
      }
      case "wallet_addEthereumChain":
        return null;
      default:
        return null;
    }
  }

  on(event: string, handler: (...a: unknown[]) => void): void {
    if (!this.listeners.has(event)) this.listeners.set(event, new Set());
    this.listeners.get(event)!.add(handler);
  }

  removeListener(event: string, handler: (...a: unknown[]) => void): void {
    this.listeners.get(event)?.delete(handler);
  }

  private fire(event: string, ...args: unknown[]): void {
    this.listeners.get(event)?.forEach((h) => h(...args));
  }

  // --- test drivers -----------------------------------------------------
  emitAccountsChanged(accounts: string[]): void {
    this.accounts = accounts;
    if (accounts.length === 0) this.authorized = false;
    this.fire("accountsChanged", accounts);
  }

  emitChainChanged(chainId: number): void {
    this.chainId = chainId;
    this.fire("chainChanged", `0x${chainId.toString(16)}`);
  }

  emitDisconnect(): void {
    this.fire("disconnect", { code: 1013, message: "disconnected" });
  }
}

/**
 * Install an EIP-6963 announcer for a provider: replies to requestProvider and
 * announces once immediately, mirroring a real wallet's behavior.
 */
export function installAnnouncer(detail: Eip6963ProviderDetail): () => void {
  const announce = () => {
    window.dispatchEvent(
      new CustomEvent("eip6963:announceProvider", { detail }),
    );
  };
  window.addEventListener("eip6963:requestProvider", announce);
  announce();
  return () => window.removeEventListener("eip6963:requestProvider", announce);
}

let uuidCounter = 0;
export function makeDetail(
  provider: Eip1193Provider,
  over: Partial<{ name: string; rdns: string; icon: string }> = {},
): Eip6963ProviderDetail {
  uuidCounter += 1;
  return {
    info: {
      uuid: `uuid-${uuidCounter}`,
      name: over.name ?? "Mock Wallet",
      icon: over.icon ?? "",
      rdns: over.rdns ?? "com.mock.wallet",
    },
    provider,
  };
}
