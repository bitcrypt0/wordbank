"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { PublicClient } from "viem";
import { getPublicClient, getWalletPreferringClient } from "@/lib/contracts/chain";
import { useWallet } from "@/lib/wallet/WalletProvider";

/** Thrown by a fetcher when a needed contract has no deployed address yet. */
export class NotDeployedError extends Error {
  constructor() {
    super("not deployed");
    this.name = "NotDeployedError";
  }
}

export type ReadStatus = "loading" | "loaded" | "error" | "pending";

export interface ReadResult<T> {
  data: T | null;
  status: ReadStatus;
  /** True when status==="loaded" and the fetched value is "empty" (caller-defined). */
  error: string | null;
  refetch: () => void;
}

interface Options {
  /** Auto-refetch interval in ms (chain freshness). 0 disables. Default 15s. */
  refetchInterval?: number;
  /** When false, the fetcher is not run (e.g. gated on a connected account). */
  enabled?: boolean;
  /**
   * Delay (ms) before the FIRST fetch only — used to stagger two reads that
   * mount together so they don't fire their request bursts simultaneously and
   * trip a public RPC's rate limiter. Subsequent refetches are immediate.
   */
  initialDelayMs?: number;
  /**
   * Prefer the connected wallet's own RPC (direct EIP-1193, no /api/rpc proxy
   * hop) when the wallet is connected AND on the configured chain — falling back
   * to the public/proxy transport otherwise. Used by connected-only pages (the
   * Dashboard) to skip the Vercel serverless round-trip that dominates read
   * latency. Default false → the shared public client, identical to before.
   */
  preferWalletRpc?: boolean;
}

/**
 * Generic chain-read hook. The fetcher composes its reads on the shared public
 * client; this hook owns the loading/error/pending lifecycle, refetches on
 * account/chain change and on an interval, and exposes a manual refetch (used
 * by the designed ErrorState's Retry button). Throw NotDeployedError from the
 * fetcher to surface the "pending deployment" state instead of an error.
 */
export function useChainData<T>(
  fetcher: (client: PublicClient) => Promise<T>,
  deps: unknown[] = [],
  options: Options = {},
): ReadResult<T> {
  const { refetchInterval = 15_000, enabled = true, initialDelayMs = 0, preferWalletRpc = false } = options;
  const { account, chainId, provider } = useWallet();
  const [data, setData] = useState<T | null>(null);
  const [status, setStatus] = useState<ReadStatus>("loading");
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  // Keep the latest fetcher without making it a re-run trigger.
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;
  // After the very first run, drop any stagger delay so refetches are immediate.
  const hasRunRef = useRef(false);

  const refetch = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!enabled) {
      setStatus("loaded");
      setData(null);
      return;
    }
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    // Don't blank the screen on background refetches — only show the skeleton
    // the first time (no data yet).
    setStatus((prev) => (data === null ? "loading" : prev));

    const run = () => {
      hasRunRef.current = true;
      // Dashboard (preferWalletRpc) reads ride the connected wallet's RPC directly
      // when it's on the configured chain — no /api/rpc proxy hop. Everything else
      // uses the shared public client. getWalletPreferringClient falls back to the
      // public client when there's no wallet or it's on the wrong network.
      const client = preferWalletRpc
        ? getWalletPreferringClient(provider, chainId)
        : getPublicClient();
      fetcherRef.current(client as unknown as PublicClient)
        .then((result) => {
          if (cancelled) return;
          setData(result);
          setStatus("loaded");
          setError(null);
        })
        .catch((err) => {
          if (cancelled) return;
          if (err instanceof NotDeployedError) {
            setStatus("pending");
            setError(null);
            return;
          }
          setStatus("error");
          setError(err?.shortMessage ?? err?.message ?? "Read failed.");
        });
    };

    // Stagger only the first fetch (so two reads mounting together don't burst
    // simultaneously); refetches after that run immediately.
    if (initialDelayMs > 0 && !hasRunRef.current) {
      timer = setTimeout(run, initialDelayMs);
    } else {
      run();
    }
    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled, account, chainId, tick, initialDelayMs, preferWalletRpc, provider, ...deps]);

  // Background polling for freshness.
  useEffect(() => {
    if (!enabled || refetchInterval <= 0) return;
    const id = setInterval(refetch, refetchInterval);
    return () => clearInterval(id);
  }, [enabled, refetchInterval, refetch]);

  return { data, status, error, refetch };
}
