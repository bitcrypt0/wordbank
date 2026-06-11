"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { PublicClient } from "viem";
import { getPublicClient } from "@/lib/contracts/chain";
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
  const { refetchInterval = 15_000, enabled = true } = options;
  const { account, chainId } = useWallet();
  const [data, setData] = useState<T | null>(null);
  const [status, setStatus] = useState<ReadStatus>("loading");
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  // Keep the latest fetcher without making it a re-run trigger.
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;

  const refetch = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!enabled) {
      setStatus("loaded");
      setData(null);
      return;
    }
    let cancelled = false;
    // Don't blank the screen on background refetches — only show the skeleton
    // the first time (no data yet).
    setStatus((prev) => (data === null ? "loading" : prev));
    fetcherRef.current(getPublicClient() as unknown as PublicClient)
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
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled, account, chainId, tick, ...deps]);

  // Background polling for freshness.
  useEffect(() => {
    if (!enabled || refetchInterval <= 0) return;
    const id = setInterval(refetch, refetchInterval);
    return () => clearInterval(id);
  }, [enabled, refetchInterval, refetch]);

  return { data, status, error, refetch };
}
