"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import {
  EXPECTED_CHAIN_ID,
  CHAIN,
  PUBLIC_RPC_URL,
  setReadProvider,
} from "@/lib/contracts/chain";
import { providerStore } from "./eip6963";
import {
  forgetConnection,
  getRememberedRdns,
  rememberConnection,
  wasConnected,
} from "./storage";
import {
  isUserRejection,
  RPC_ERRORS,
  type Eip1193Provider,
  type Eip6963ProviderDetail,
  type Eip6963ProviderInfo,
  type ProviderRpcError,
} from "./types";

export type WalletStatus = "disconnected" | "connecting" | "connected";

export interface WalletContextValue {
  status: WalletStatus;
  account: `0x${string}` | null;
  chainId: number | null;
  /** True when connected but on a chain other than the configured one. */
  wrongNetwork: boolean;
  /** Identity of the connected provider (name/icon), or null. */
  providerInfo: Eip6963ProviderInfo | null;
  /** Raw provider for building viem wallet clients (write path, M2). */
  provider: Eip1193Provider | null;
  /** All discovered injected providers (for the picker). */
  providers: Eip6963ProviderDetail[];
  /** Non-fatal last error message (cleared on the next connect attempt). */
  error: string | null;
  /** True until the silent-reconnect attempt has resolved. */
  initializing: boolean;
  /** Explicit connect. With multiple providers, pass the chosen rdns. */
  connect: (rdns?: string) => Promise<void>;
  /** Explicit, instant, app-side disconnect (no reload). */
  disconnect: () => void;
  /** Offer wallet_switchEthereumChain (+ add fallback) to the configured chain. */
  switchToMainnet: () => Promise<void>;
}

const WalletContext = createContext<WalletContextValue | null>(null);

function parseChainId(hex: unknown): number | null {
  if (typeof hex === "string") return Number.parseInt(hex, 16);
  if (typeof hex === "number") return hex;
  return null;
}

async function readChainId(provider: Eip1193Provider): Promise<number | null> {
  try {
    return parseChainId(await provider.request({ method: "eth_chainId" }));
  } catch {
    return null;
  }
}

export function WalletProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<WalletStatus>("disconnected");
  const [account, setAccount] = useState<`0x${string}` | null>(null);
  const [chainId, setChainId] = useState<number | null>(null);
  const [providerInfo, setProviderInfo] = useState<Eip6963ProviderInfo | null>(null);
  const [providers, setProviders] = useState<Eip6963ProviderDetail[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [initializing, setInitializing] = useState(true);

  // The live provider + its bound handlers, so we can detach cleanly.
  const activeProvider = useRef<Eip1193Provider | null>(null);
  const handlers = useRef<{
    accountsChanged: (...a: unknown[]) => void;
    chainChanged: (...a: unknown[]) => void;
    disconnect: (...a: unknown[]) => void;
  } | null>(null);
  const reconnectTried = useRef(false);

  const detach = useCallback(() => {
    const p = activeProvider.current;
    const h = handlers.current;
    if (p?.removeListener && h) {
      p.removeListener("accountsChanged", h.accountsChanged);
      p.removeListener("chainChanged", h.chainChanged);
      p.removeListener("disconnect", h.disconnect);
    }
    activeProvider.current = null;
    handlers.current = null;
    // Stop routing chain reads through the (now gone) wallet provider; the read
    // client falls back to the public endpoint on its next use.
    setReadProvider(null);
  }, []);

  const reset = useCallback(() => {
    detach();
    setStatus("disconnected");
    setAccount(null);
    setChainId(null);
    setProviderInfo(null);
  }, [detach]);

  const disconnect = useCallback(() => {
    forgetConnection();
    reset();
    setError(null);
  }, [reset]);

  /** Bind live-change listeners to a provider once connected. */
  const attach = useCallback(
    (provider: Eip1193Provider) => {
      if (!provider.on) return;
      const onAccounts = (...args: unknown[]) => {
        const accounts = (args[0] as string[]) ?? [];
        if (accounts.length === 0) {
          // Wallet locked / disconnected at the wallet — reflect it, no reload.
          forgetConnection();
          reset();
          return;
        }
        setAccount(accounts[0] as `0x${string}`);
      };
      const onChain = (...args: unknown[]) => {
        setChainId(parseChainId(args[0]));
      };
      const onDisconnect = () => {
        forgetConnection();
        reset();
      };
      provider.on("accountsChanged", onAccounts);
      provider.on("chainChanged", onChain);
      provider.on("disconnect", onDisconnect);
      activeProvider.current = provider;
      handlers.current = {
        accountsChanged: onAccounts,
        chainChanged: onChain,
        disconnect: onDisconnect,
      };
    },
    [reset],
  );

  const finishConnect = useCallback(
    async (detail: Eip6963ProviderDetail, accounts: string[]) => {
      const cid = await readChainId(detail.provider);
      detach();
      attach(detail.provider);
      // Route chain reads through the connected wallet's RPC (visitor's own node),
      // never the owner's. The read client rebuilds on the next read.
      setReadProvider(detail.provider);
      setAccount(accounts[0] as `0x${string}`);
      setChainId(cid);
      setProviderInfo(detail.info);
      setStatus("connected");
      rememberConnection(detail.info.rdns);
    },
    [attach, detach],
  );

  const connect = useCallback(
    async (rdns?: string) => {
      setError(null);
      const list = providerStore.list();
      const detail =
        (rdns ? providerStore.get(rdns) : undefined) ??
        (list.length === 1 ? list[0] : undefined);
      if (!detail) {
        if (list.length === 0) {
          setError("No injected wallet found. Install one to continue.");
        } else {
          // Multiple wallets, none chosen — caller should open the picker.
          setError("Choose a wallet to connect.");
        }
        return;
      }
      setStatus("connecting");
      try {
        const accounts = (await detail.provider.request({
          method: "eth_requestAccounts",
        })) as string[];
        if (!accounts || accounts.length === 0) {
          setStatus("disconnected");
          return;
        }
        await finishConnect(detail, accounts);
      } catch (err) {
        // Clean recovery: rejection returns to idle with no error spam.
        setStatus("disconnected");
        if (!isUserRejection(err)) {
          setError((err as ProviderRpcError)?.message ?? "Connection failed.");
        }
      }
    },
    [finishConnect],
  );

  const switchToMainnet = useCallback(async () => {
    const provider = activeProvider.current;
    if (!provider) return;
    const hexId = `0x${EXPECTED_CHAIN_ID.toString(16)}`;
    try {
      await provider.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: hexId }],
      });
    } catch (err) {
      if ((err as ProviderRpcError)?.code === RPC_ERRORS.CHAIN_NOT_ADDED) {
        // Derive add-chain metadata from the configured chain (mainnet/Sepolia/…).
        // We do NOT inject the owner's RPC here — prefer an optional PUBLIC url if
        // the owner set one, then the chain's own default public RPC endpoints.
        const rpcUrls = [
          ...(PUBLIC_RPC_URL ? [PUBLIC_RPC_URL] : []),
          ...CHAIN.rpcUrls.default.http,
        ].filter((u) => /^https?:\/\//.test(u));
        await provider.request({
          method: "wallet_addEthereumChain",
          params: [
            {
              chainId: hexId,
              chainName: CHAIN.name,
              nativeCurrency: CHAIN.nativeCurrency,
              rpcUrls: rpcUrls.length > 0 ? rpcUrls : CHAIN.rpcUrls.default.http,
              blockExplorerUrls: CHAIN.blockExplorers
                ? [CHAIN.blockExplorers.default.url]
                : [],
            },
          ],
        });
      } else if (!isUserRejection(err)) {
        setError((err as ProviderRpcError)?.message ?? "Network switch failed.");
      }
    }
    // chainChanged listener updates state; no reload.
  }, []);

  // Discover providers + attempt one silent reconnect.
  useEffect(() => {
    providerStore.start();
    const unsub = providerStore.subscribe((list) => {
      setProviders(list);
      if (reconnectTried.current) return;
      if (!wasConnected()) {
        reconnectTried.current = true;
        setInitializing(false);
        return;
      }
      const rdns = getRememberedRdns();
      const detail = rdns ? providerStore.get(rdns) : undefined;
      if (!detail) return; // wait for the remembered provider to announce
      reconnectTried.current = true;
      detail.provider
        .request({ method: "eth_accounts" }) // silent — never prompts
        .then(async (res) => {
          const accounts = (res as string[]) ?? [];
          if (accounts.length > 0) await finishConnect(detail, accounts);
        })
        .catch(() => {
          /* stay disconnected */
        })
        .finally(() => setInitializing(false));
    });
    // If no provider ever announces, stop initializing shortly after mount.
    const t = setTimeout(() => {
      if (!reconnectTried.current) {
        reconnectTried.current = true;
        setInitializing(false);
      }
    }, 1500);
    return () => {
      unsub();
      clearTimeout(t);
    };
  }, [finishConnect]);

  // Re-sync on focus / tab-visible. Some wallets (Rabby, MetaMask) don't reliably
  // emit `accountsChanged` to the connected dApp after an in-wallet account switch,
  // so re-reading accounts + chain whenever the user returns to the tab guarantees a
  // freshly-switched account is picked up live (no disconnect/reconnect needed).
  useEffect(() => {
    if (status !== "connected") return;
    const resync = async () => {
      const p = activeProvider.current;
      if (!p) return;
      try {
        const accounts = (await p.request({ method: "eth_accounts" })) as string[];
        if (!accounts || accounts.length === 0) {
          forgetConnection();
          reset();
          return;
        }
        setAccount((prev) =>
          prev && prev.toLowerCase() === accounts[0].toLowerCase()
            ? prev
            : (accounts[0] as `0x${string}`),
        );
        const cid = await readChainId(p);
        if (cid !== null) setChainId(cid);
      } catch {
        /* transient — leave state as-is */
      }
    };
    const onVisible = () => {
      if (document.visibilityState === "visible") void resync();
    };
    window.addEventListener("focus", resync);
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      window.removeEventListener("focus", resync);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [status, reset]);

  // Detach listeners on unmount.
  useEffect(() => detach, [detach]);

  const value = useMemo<WalletContextValue>(
    () => ({
      status,
      account,
      chainId,
      wrongNetwork: status === "connected" && chainId !== EXPECTED_CHAIN_ID,
      providerInfo,
      provider: activeProvider.current,
      providers,
      error,
      initializing,
      connect,
      disconnect,
      switchToMainnet,
    }),
    [
      status,
      account,
      chainId,
      providerInfo,
      providers,
      error,
      initializing,
      connect,
      disconnect,
      switchToMainnet,
    ],
  );

  return <WalletContext.Provider value={value}>{children}</WalletContext.Provider>;
}

export function useWallet(): WalletContextValue {
  const ctx = useContext(WalletContext);
  if (!ctx) throw new Error("useWallet must be used within <WalletProvider>");
  return ctx;
}
