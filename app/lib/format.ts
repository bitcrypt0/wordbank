/**
 * Display formatting for onchain values. All mock amounts are wei strings
 * (what viem returns as bigint) so agent 9 swaps data sources, not formats.
 */

/** "12372500000000000" → "0.0124" (ETH, trimmed trailing zeros). */
export function formatEth(wei: string | bigint, maxDecimals = 4): string {
  const v = typeof wei === "bigint" ? wei : BigInt(wei);
  const whole = v / 10n ** 18n;
  const frac = v % 10n ** 18n;
  const fracStr = frac.toString().padStart(18, "0").slice(0, maxDecimals);
  const trimmed = fracStr.replace(/0+$/, "");
  return trimmed.length > 0
    ? `${whole.toLocaleString("en-US")}.${trimmed}`
    : whole.toLocaleString("en-US");
}

/** Whole-token WORD amounts: "1000000000000000000000" → "1,000". */
export function formatWord(wei: string | bigint): string {
  const v = typeof wei === "bigint" ? wei : BigInt(wei);
  return (v / 10n ** 18n).toLocaleString("en-US");
}

/** "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" → "0x3C44…93BC" */
export function shortAddress(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/** Truncate a bytes32 hash for compact display: "0xd164…ffd1". */
export function truncateHash(hash: string): string {
  return `${hash.slice(0, 6)}…${hash.slice(-4)}`;
}

export function formatInt(n: number): string {
  return n.toLocaleString("en-US");
}

/** Days/hours remaining until an ISO timestamp (mock clock-friendly). */
export function timeRemaining(deadlineIso: string, now = new Date()): string {
  const ms = new Date(deadlineIso).getTime() - now.getTime();
  if (ms <= 0) return "expired";
  const days = Math.floor(ms / 86_400_000);
  const hours = Math.floor((ms % 86_400_000) / 3_600_000);
  if (days > 0) return `${days}d ${hours}h remaining`;
  const mins = Math.floor((ms % 3_600_000) / 60_000);
  return `${hours}h ${mins}m remaining`;
}
