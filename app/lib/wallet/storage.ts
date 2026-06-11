/**
 * Connection persistence. Two facts survive reloads:
 *   - which provider (rdns) the user last chose, so reconnect targets it;
 *   - whether the user is in a "connected" session (vs. explicitly disconnected),
 *     which gates the SILENT reconnect — we restore via eth_accounts only when
 *     this is set, and never auto-prompt.
 * Explicit disconnect clears both, so a reload after disconnect stays idle.
 */
const RDNS_KEY = "wordbank.wallet.rdns";
const CONNECTED_KEY = "wordbank.wallet.connected";

function safeGet(key: string): string | null {
  try {
    return typeof window === "undefined" ? null : window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

function safeSet(key: string, value: string): void {
  try {
    window.localStorage.setItem(key, value);
  } catch {
    /* storage unavailable (private mode) — session simply won't persist */
  }
}

function safeRemove(key: string): void {
  try {
    window.localStorage.removeItem(key);
  } catch {
    /* ignore */
  }
}

export function rememberConnection(rdns: string): void {
  safeSet(RDNS_KEY, rdns);
  safeSet(CONNECTED_KEY, "1");
}

export function forgetConnection(): void {
  safeRemove(RDNS_KEY);
  safeRemove(CONNECTED_KEY);
}

export function getRememberedRdns(): string | null {
  return safeGet(RDNS_KEY);
}

export function wasConnected(): boolean {
  return safeGet(CONNECTED_KEY) === "1";
}
