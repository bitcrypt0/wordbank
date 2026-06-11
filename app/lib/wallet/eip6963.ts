/**
 * EIP-6963 multi-provider discovery, with a window.ethereum (EIP-1193)
 * fallback for wallets that don't announce. Framework-agnostic store so it is
 * trivially testable against a mock provider; React subscribes in WalletProvider.
 */
import type {
  Eip1193Provider,
  Eip6963AnnounceEvent,
  Eip6963ProviderDetail,
} from "./types";

/** Synthetic rdns for a non-announcing window.ethereum provider. */
export const FALLBACK_RDNS = "injected.window.ethereum";

type Listener = (details: Eip6963ProviderDetail[]) => void;

class ProviderStore {
  private byRdns = new Map<string, Eip6963ProviderDetail>();
  private listeners = new Set<Listener>();
  private started = false;

  private onAnnounce = (event: Event) => {
    const detail = (event as Eip6963AnnounceEvent).detail;
    if (!detail?.info?.rdns || !detail.provider) return;
    // Last announcement for a given rdns wins (wallets may re-announce).
    this.byRdns.set(detail.info.rdns, detail);
    this.emit();
  };

  /** Begin listening + request announcements; idempotent. */
  start(): void {
    if (this.started || typeof window === "undefined") return;
    this.started = true;
    window.addEventListener("eip6963:announceProvider", this.onAnnounce);
    window.dispatchEvent(new Event("eip6963:requestProvider"));
    this.addWindowEthereumFallback();
  }

  /** Add window.ethereum as a fallback entry only if nothing announced it. */
  private addWindowEthereumFallback(): void {
    if (typeof window === "undefined") return;
    const injected = (window as unknown as { ethereum?: Eip1193Provider }).ethereum;
    if (!injected) return;
    // If an announcing wallet already exposes this exact provider, skip the dup.
    for (const d of this.byRdns.values()) {
      if (d.provider === injected) return;
    }
    if (this.byRdns.has(FALLBACK_RDNS)) return;
    this.byRdns.set(FALLBACK_RDNS, {
      info: {
        uuid: FALLBACK_RDNS,
        name: detectInjectedName(injected),
        icon: "",
        rdns: FALLBACK_RDNS,
      },
      provider: injected,
    });
    this.emit();
  }

  list(): Eip6963ProviderDetail[] {
    return [...this.byRdns.values()];
  }

  get(rdns: string): Eip6963ProviderDetail | undefined {
    return this.byRdns.get(rdns);
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    listener(this.list());
    return () => this.listeners.delete(listener);
  }

  private emit(): void {
    const snapshot = this.list();
    for (const l of this.listeners) l(snapshot);
  }

  /** Test-only reset. */
  _reset(): void {
    if (typeof window !== "undefined" && this.started) {
      window.removeEventListener("eip6963:announceProvider", this.onAnnounce);
    }
    this.byRdns.clear();
    this.listeners.clear();
    this.started = false;
  }
}

/** Best-effort friendly name for a non-announcing injected provider. */
function detectInjectedName(p: Eip1193Provider): string {
  const flags = p as unknown as Record<string, boolean>;
  if (flags.isMetaMask) return "MetaMask";
  if (flags.isRabby) return "Rabby";
  if (flags.isCoinbaseWallet) return "Coinbase Wallet";
  if (flags.isBraveWallet) return "Brave Wallet";
  return "Browser Wallet";
}

export const providerStore = new ProviderStore();
