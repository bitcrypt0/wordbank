/**
 * OPTIONAL server-side JSON-RPC proxy (Agent 9, 2026-06-16 — rate-limit resilience).
 *
 * Lets the owner use a RELIABLE KEYED RPC (e.g. Alchemy) for chain reads WITHOUT
 * ever exposing the key to the browser or the repo. The browser-side read client
 * (lib/contracts/chain.ts) front-ranks this same-origin `/api/rpc` transport when
 * the owner opts in with NEXT_PUBLIC_RPC_PROXY=1; this route forwards the JSON-RPC
 * body to the SERVER-ONLY env var `RPC_PROXY_URL` and returns the upstream response.
 *
 *   RPC_PROXY_URL          (server-only)  e.g. https://eth-mainnet.g.alchemy.com/v2/<key>
 *   NEXT_PUBLIC_RPC_PROXY  (public "1")   tells the CLIENT to use /api/rpc
 *
 * The KEY stays server-side: `RPC_PROXY_URL` is a plain (non-NEXT_PUBLIC_) env var,
 * so Next never inlines it into the client bundle. It is read here, in a Node
 * runtime route that only runs on the server.
 *
 * HARDENING (so this is NOT an open relay):
 *  - POST only (other verbs → 405).
 *  - If RPC_PROXY_URL is unset → 503, so the client's viem fallback() rolls
 *    straight to the keyless public list (graceful; nothing crashes).
 *  - Body must be valid JSON, ≤ MAX_BODY_BYTES, and JSON-RPC shaped (single object
 *    or a bounded batch array).
 *  - METHOD ALLOWLIST: only read methods are forwarded (eth_call, eth_getLogs,
 *    multicall via eth_call, block/chain/fee reads, etc.). No eth_sendRawTransaction,
 *    no account/wallet methods — writes still go through the user's wallet, never us.
 *  - Upstream fetch has a timeout.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Max request body we will accept (a large multicall batch is still small). */
const MAX_BODY_BYTES = 256 * 1024; // 256 KB
/** Max calls in a single JSON-RPC batch array. */
const MAX_BATCH = 100;
/** Upstream fetch timeout. */
const UPSTREAM_TIMEOUT_MS = 15_000;

/**
 * Read-only JSON-RPC method allowlist. Everything the dApp's READ path needs
 * (multicall + ownerOf + getLogs + the V4 quoter eth_call + block/fee/chain).
 * Deliberately EXCLUDES eth_sendRawTransaction / eth_sendTransaction / accounts /
 * signing — writes ride the wallet, so the proxy never needs them. Keeps it from
 * being abused as an open write relay.
 */
const ALLOWED_METHODS = new Set<string>([
  "eth_call",
  "eth_getLogs",
  "eth_chainId",
  "eth_blockNumber",
  "eth_getBlockByNumber",
  "eth_getBlockByHash",
  "eth_getBalance",
  "eth_getCode",
  "eth_getStorageAt",
  "eth_getTransactionByHash",
  "eth_getTransactionReceipt",
  "eth_getTransactionCount",
  "eth_estimateGas",
  "eth_gasPrice",
  "eth_maxPriorityFeePerGas",
  "eth_feeHistory",
  "eth_getBlockTransactionCountByNumber",
  "net_version",
  "web3_clientVersion",
]);

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

/** A JSON-RPC error envelope (so viem decodes it cleanly instead of throwing on shape). */
function rpcError(id: unknown, code: number, message: string): Response {
  // Use HTTP 200 with a JSON-RPC error so viem surfaces the message; but for
  // transport-level conditions (proxy off / oversized) we use HTTP 4xx/5xx so
  // viem's fallback() rotates to the next transport.
  return jsonResponse({ jsonrpc: "2.0", id: id ?? null, error: { code, message } }, 200);
}

function isReadMethod(method: unknown): boolean {
  return typeof method === "string" && ALLOWED_METHODS.has(method);
}

export async function POST(req: Request): Promise<Response> {
  const upstream = process.env.RPC_PROXY_URL;
  // Proxy not configured → 503 so the client's fallback() rolls to the public list.
  if (!upstream || upstream.trim() === "") {
    return jsonResponse({ error: "rpc proxy not configured" }, 503);
  }

  // Size guard via Content-Length (best-effort) then by the actual read.
  const lenHeader = req.headers.get("content-length");
  if (lenHeader && Number(lenHeader) > MAX_BODY_BYTES) {
    return jsonResponse({ error: "request too large" }, 413);
  }

  let raw: string;
  try {
    raw = await req.text();
  } catch {
    return jsonResponse({ error: "could not read body" }, 400);
  }
  if (raw.length > MAX_BODY_BYTES) {
    return jsonResponse({ error: "request too large" }, 413);
  }

  let payload: unknown;
  try {
    payload = JSON.parse(raw);
  } catch {
    return jsonResponse({ error: "invalid json" }, 400);
  }

  // Validate JSON-RPC shape + method allowlist (single or bounded batch).
  if (Array.isArray(payload)) {
    if (payload.length === 0 || payload.length > MAX_BATCH) {
      return jsonResponse({ error: "invalid batch size" }, 400);
    }
    for (const item of payload) {
      const m = (item as { method?: unknown })?.method;
      if (!isReadMethod(m)) {
        return rpcError(
          (item as { id?: unknown })?.id,
          -32601,
          `method not allowed via proxy: ${String(m)}`,
        );
      }
    }
  } else if (payload && typeof payload === "object") {
    const m = (payload as { method?: unknown }).method;
    if (!isReadMethod(m)) {
      return rpcError(
        (payload as { id?: unknown }).id,
        -32601,
        `method not allowed via proxy: ${String(m)}`,
      );
    }
  } else {
    return jsonResponse({ error: "invalid json-rpc body" }, 400);
  }

  // Forward to the keyed upstream (server-side; key never leaves the server).
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS);
  try {
    const res = await fetch(upstream, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: raw,
      signal: controller.signal,
    });
    const text = await res.text();
    return new Response(text, {
      status: res.status,
      headers: {
        "content-type": res.headers.get("content-type") ?? "application/json",
        "cache-control": "no-store",
      },
    });
  } catch {
    // Upstream unreachable/timeout → 502 so the client rotates to the public list.
    return jsonResponse({ error: "upstream rpc failed" }, 502);
  } finally {
    clearTimeout(timer);
  }
}

/** Non-POST verbs are rejected (POST-only relay). */
export async function GET(): Promise<Response> {
  return jsonResponse({ error: "method not allowed; use POST json-rpc" }, 405);
}
