/**
 * Failure-path tests for the one-command verifier (verify:mainnet / verify:sepolia).
 * Run:  npm run test:verify   (npx ts-node scripts/verify.test.ts)
 *
 * These are the paths a keyless / misconfigured owner run hits — they must fail CLEARLY, not
 * cryptically. A real Etherscan verification needs the owner's key, so that final proof is the
 * owner's run; here we lock down the guards around it.
 */
import * as assert from "assert";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import {apiKeyError} from "./verify-commands";
import {resolveForge} from "./lib";

let passed = 0;
function check(name: string, fn: () => void) {
  fn();
  passed++;
  console.log(`  ok  ${name}`);
}

// ── 1. Missing / blank ETHERSCAN_API_KEY → friendly, specific error ─────────────────────────
check("undefined key → friendly error mentioning deploy/.env + how to get a key", () => {
  const msg = apiKeyError(undefined);
  assert.ok(msg, "expected an error message for an undefined key");
  assert.ok(msg!.includes("ETHERSCAN_API_KEY"), "names the var");
  assert.ok(msg!.includes("deploy/.env"), "tells the owner where to put it");
  assert.ok(msg!.includes("etherscan.io/myapikey"), "points to where to get a free key");
});

check("empty / whitespace key → same friendly error", () => {
  assert.ok(apiKeyError(""), "empty string is treated as missing");
  assert.ok(apiKeyError("   "), "whitespace-only is treated as missing");
});

check("a present key → no error (null)", () => {
  assert.strictEqual(apiKeyError("SOME_REAL_KEY"), null);
  assert.strictEqual(apiKeyError("  spaced_key  "), null); // trimmed, still present
});

// ── 2. forge not found → clear, actionable error (bogus path + no PATH forge) ───────────────
check("resolveForge throws a clear error when forge is nowhere", () => {
  const savedHome = process.env.HOME;
  const savedUserProfile = process.env.USERPROFILE;
  const savedPath = process.env.PATH;
  // Point HOME/USERPROFILE at an empty temp dir (no .foundry/bin) and blank PATH so the PATH
  // fallback probe can't find forge either.
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), "no-foundry-"));
  try {
    process.env.HOME = empty;
    process.env.USERPROFILE = empty;
    process.env.PATH = "";
    let threw: Error | null = null;
    try {
      resolveForge();
    } catch (e: any) {
      threw = e;
    }
    assert.ok(threw, "expected resolveForge to throw when forge is absent");
    assert.ok(threw!.message.includes("forge"), "error names forge");
    assert.ok(
      threw!.message.toLowerCase().includes("not found") ||
        threw!.message.toLowerCase().includes("install"),
      "error is actionable (not found / install Foundry)",
    );
  } finally {
    process.env.HOME = savedHome;
    process.env.USERPROFILE = savedUserProfile;
    process.env.PATH = savedPath;
    fs.rmSync(empty, {recursive: true, force: true});
  }
});

// ── 3. resolveForge finds the real binary on this machine (~/.foundry/bin) ──────────────────
check("resolveForge resolves the real forge on this machine", () => {
  const bin = resolveForge();
  assert.ok(typeof bin === "string" && bin.length > 0, "returns a non-empty binary path/name");
});

console.log(`\nverify failure-paths: ${passed}/5 checks passed`);
