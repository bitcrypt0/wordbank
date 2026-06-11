/** @type {import('next').NextConfig} */

/**
 * SECURITY HEADERS + CSP (Agent 9, 2026-06-16 — pre-launch hardening).
 *
 * Goal: real clickjacking / XSS hardening WITHOUT breaking the injected-wallet
 * flow or the on-chain data:-URI art. Verified against the production build (see
 * agents/09-frontend-dapp/SECURITY_REVIEW.md §B6 for the browser verification).
 *
 * App-specific facts that shape the policy (all confirmed):
 *  - Font is SELF-HOSTED via next/font/local (Fraunces-VF.ttf) — no Google Fonts
 *    → font-src 'self' (next/font emits same-origin /_next/static/media/*.ttf).
 *  - On-chain art renders as data: URIs (SVG composed client-side, injected via
 *    dangerouslySetInnerHTML / <img src="data:...">) → img-src 'self' data:.
 *  - Wallet is INJECTED EIP-6963 / window.ethereum — an in-page JS object, NOT a
 *    page network connection, so it needs NO connect-src entry. The EIP-1193
 *    request() path goes through the extension, not fetch from the page origin.
 *  - The PUBLIC RPC FALLBACK (viem http() to chain-default public endpoints, e.g.
 *    https://eth.merkle.io for mainnet / https://11155111.rpc.thirdweb.com for
 *    Sepolia) AND any owner-set public NEXT_PUBLIC_RPC_URL DO make page fetches
 *    → connect-src must allow them. Because the owner may set any public RPC in
 *    Vercel and viem's defaults can change, we allow `'self' https: wss:` rather
 *    than an exact-origin allowlist that would silently break reads if the owner
 *    picks a different public RPC. (Charter explicitly authorizes this pragmatic
 *    choice.) wss: covers any WebSocket-transport public RPC.
 *  - No API routes, no external analytics, no third-party scripts.
 *
 * script-src: App Router injects inline bootstrap/hydration scripts (and inline
 * JSON for RSC/flight data). A nonce-based strict CSP in Next 15 requires a
 * middleware that sets a per-request nonce AND forces every page to be
 * dynamically rendered (opting out of static optimization) — this app is almost
 * entirely static/client-rendered, so a nonce middleware would regress
 * performance/caching for no real gain here. We therefore use 'unsafe-inline'
 * for script-src in PROD (documented trade-off) and DELIBERATELY OMIT
 * 'unsafe-eval' in prod. Next dev (React Refresh / HMR) needs 'unsafe-eval', so
 * a dev-only branch adds it — prod stays free of eval.
 */

const isDev = process.env.NODE_ENV !== "production";

/** Build the CSP string. Dev adds 'unsafe-eval' (HMR) + ws: (HMR socket). */
function buildCsp() {
  const scriptSrc = isDev
    ? "script-src 'self' 'unsafe-inline' 'unsafe-eval'"
    : "script-src 'self' 'unsafe-inline'";

  // Dev needs ws: for the HMR websocket on localhost.
  const connectSrc = isDev
    ? "connect-src 'self' https: wss: ws:"
    : "connect-src 'self' https: wss:";

  const directives = [
    "default-src 'self'",
    scriptSrc,
    // Inline styles: Next + the design use inline style attributes (e.g. art
    // aspect-ratio). 'unsafe-inline' for style is low-risk (no script execution).
    "style-src 'self' 'unsafe-inline'",
    // Self-hosted font files only.
    "font-src 'self'",
    // Same-origin images + data: URIs for the on-chain SVG art.
    "img-src 'self' data:",
    // RPC fallback fetches (public endpoints / owner-set public RPC). The
    // injected wallet (EIP-1193) does NOT use this — it is an in-page object.
    connectSrc,
    // No <object>/<embed>/<applet>.
    "object-src 'none'",
    // Lock the document base URI (anti base-tag injection).
    "base-uri 'self'",
    // Restrict form posts to same origin (the app has no cross-origin forms).
    "form-action 'self'",
    // Anti-clickjacking — pairs with X-Frame-Options: DENY for older browsers.
    "frame-ancestors 'none'",
    // Block any nested browsing contexts (the app embeds no iframes).
    "frame-src 'none'",
  ];

  return directives.join("; ");
}

/**
 * Locked-down Permissions-Policy: disable powerful features the dApp never uses.
 * (Empty allowlist `()` = feature disabled for all origins including self.)
 */
const PERMISSIONS_POLICY = [
  "accelerometer=()",
  "autoplay=()",
  "camera=()",
  "display-capture=()",
  "encrypted-media=()",
  "fullscreen=(self)",
  "geolocation=()",
  "gyroscope=()",
  "magnetometer=()",
  "microphone=()",
  "midi=()",
  "payment=()",
  "usb=()",
  "xr-spatial-tracking=()",
].join(", ");

const securityHeaders = [
  {
    key: "Content-Security-Policy",
    value: buildCsp(),
  },
  {
    // 2 years, includeSubDomains, preload-eligible. HTTPS-only (Vercel is HTTPS).
    key: "Strict-Transport-Security",
    value: "max-age=63072000; includeSubDomains; preload",
  },
  {
    key: "X-Content-Type-Options",
    value: "nosniff",
  },
  {
    // Anti-clickjacking for browsers that don't honor frame-ancestors.
    key: "X-Frame-Options",
    value: "DENY",
  },
  {
    key: "Referrer-Policy",
    value: "strict-origin-when-cross-origin",
  },
  {
    key: "Permissions-Policy",
    value: PERMISSIONS_POLICY,
  },
];

const nextConfig = {
  // Static design mock origin — no rewrites, no server features beyond headers.
  outputFileTracingRoot: import.meta.dirname,
  async headers() {
    return [
      {
        // Apply to every route (pages + static assets).
        source: "/:path*",
        headers: securityHeaders,
      },
    ];
  },
};

export default nextConfig;
