/**
 * Verifies every deployed WORDBANK contract on Etherscan with ONE command.
 *
 * Builds the `forge verify-contract` invocation for each contract, in the order they should be
 * verified (WordToken FIRST — RUNBOOK hygiene #1), and RUNS them sequentially with `--watch`
 * (each waits for Etherscan to confirm before the next). Foundry is the compiler of record, so
 * verification goes through forge, not hardhat-verify.
 *
 * Owner usage (ONE command — network baked into the npm script):
 *     npm run verify:mainnet          # or: npm run verify:sepolia
 *   First put ETHERSCAN_API_KEY=... in deploy/.env (one key works for every chain).
 *
 * Print-only (the old behavior, for debugging — prints the nine commands, runs nothing):
 *     npm run verify-commands                       (defaults to mainnet)
 *     npm run verify-commands -- --network sepolia
 *     npm run verify:mainnet -- --print             (force print on an execute script)
 *
 * The target network comes from `--network <name>` on the CLI (the npm scripts pass it), so the
 * script runs directly via ts-node — no hardhat runtime needed, cross-platform on Windows.
 * forge is auto-resolved from ~/.foundry/bin (it need NOT be on PATH); ETHERSCAN_API_KEY is read
 * from deploy/.env (loaded above). A contract that's already verified counts as success; one
 * failure does not abort the run — failures are collected and a clear summary is printed at the
 * end, and a re-run safely skips the already-verified ones.
 */
import * as dotenv from "dotenv";
import * as path from "path";
import {spawn} from "child_process";
import {REPO_ROOT, coder, loadAddresses, resolveForge} from "./lib";

// Load deploy/.env (ETHERSCAN_API_KEY etc.) explicitly by path — needed when this script runs via
// ts-node (the npm scripts) rather than under hardhat, and robust to the caller's cwd.
dotenv.config({path: path.join(__dirname, "..", ".env")});

/** The target network for verification. Read from `--network <name>` on the CLI (so this works
 *  under plain ts-node — the npm scripts pass it), falling back to HARDHAT_NETWORK then mainnet.
 *  Self-contained (no hardhat runtime needed) so the npm scripts can run it directly cross-platform. */
function resolveNetwork(): string {
  const i = process.argv.indexOf("--network");
  if (i !== -1 && process.argv[i + 1]) return process.argv[i + 1];
  const env = (process.env.HARDHAT_NETWORK ?? "").trim();
  return env || "mainnet";
}
const network = {name: resolveNetwork()};

/** One contract's verification: a human label + the exact forge argv (after the `forge` binary). */
interface VerifyJob {
  label: string;
  args: string[];
}

/** The friendly, specific message shown when ETHERSCAN_API_KEY is missing/blank — returns the
 *  message string if the key is unusable, or null if it's fine. Pure, so it's unit-testable. */
export function apiKeyError(key: string | undefined): string | null {
  if ((key ?? "").trim()) return null;
  return (
    "\nETHERSCAN_API_KEY is not set.\n" +
    "  Add a line to deploy/.env:   ETHERSCAN_API_KEY=your_key_here\n" +
    "  Get a free key at https://etherscan.io/myapikey (one key works for all chains).\n"
  );
}

/** True when the user asked for print-only (the old behavior). Works whether the script is run
 *  via `hardhat run` (use VERIFY_PRINT=1, since hardhat rejects unknown --flags) or directly via
 *  ts-node with HARDHAT_NETWORK set (then --print / --dry-run on the CLI works too). */
function wantsPrint(): boolean {
  if (process.argv.includes("--print") || process.argv.includes("--dry-run")) return true;
  const v = (process.env.VERIFY_PRINT ?? "").trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}

/** Builds the nine verification jobs. The command order, addresses and constructor-args here are
 *  the FROZEN, deploy-matching logic — do not change them (only the execution wrapper is new). */
function buildJobs(): VerifyJob[] {
  const a = loadAddresses(network.name);
  const chain = network.name === "mainnet" ? "1" : network.name === "sepolia" ? "11155111" : "31337";
  const base = ["verify-contract", "--chain", chain, "--watch"];

  const enc = (types: string[], values: unknown[]) => coder.encode(types, values).slice(2);
  const job = (label: string, ...rest: string[]): VerifyJob => ({label, args: [...base, ...rest]});

  return [
    // WordToken FIRST (scanner hygiene). Deployed by WordBank's constructor; same compiler input.
    job("WordToken", a.wordToken, "src/WordToken.sol:WordToken", "--constructor-args", enc(["address"], [a.admin])),
    job("WordBank", a.wordBank, "src/WordBank.sol:WordBank", "--constructor-args", enc(["address"], [a.admin])),
    job("Renderer", a.renderer, "src/Renderer.sol:Renderer"),
    job("BountyEngine", a.bountyEngine, "src/BountyEngine.sol:BountyEngine", "--constructor-args", enc(["address", "address"], [a.wordBank, a.admin])),
    job("RewardsDistributor", a.rewardsDistributor, "src/RewardsDistributor.sol:RewardsDistributor", "--constructor-args", enc(["address", "address"], [a.wordBank, a.bountyEngine])),
    job("BurnEngine", a.burnEngine, "src/BurnEngine.sol:BurnEngine", "--constructor-args", enc(["address", "address", "address", "address"], [a.poolManager, a.wordToken, a.rewardsDistributor, a.admin])),
    job("FeeHook", a.feeHook, "src/FeeHook.sol:FeeHook", "--constructor-args", a.feeHookConstructorArgs.slice(2)),
    job("LPLocker", a.lpLocker, "src/LPLocker.sol:LPLocker", "--constructor-args", enc(["address", "address"], [a.positionManager, a.admin])),
    job("RoyaltySplitter", a.royaltySplitter, "src/RoyaltySplitter.sol:RoyaltySplitter", "--constructor-args", enc(["address", "address", "address", "address"], [a.burnEngine, a.bountyEngine, a.admin, a.weth])),
  ];
}

/** The exact one-line `forge ...` command for a job — used by --print (byte-identical to the
 *  historical print output) and quoted in error messages so the owner can copy/paste-retry one. */
function commandLine(j: VerifyJob): string {
  return "forge " + j.args.join(" ");
}

/** Print-only path — restores the original behavior exactly (byte-identical output). */
function printOnly(jobs: VerifyJob[]): void {
  console.log("# Run from the repo root, with ETHERSCAN_API_KEY set, in this order:\n");
  for (const j of jobs) console.log(commandLine(j) + "\n");
}

/** Runs one forge verify-contract job, returning success/failure + captured tail of output.
 *  Treats forge's "already verified" / "is already verified" response as success (idempotent). */
function runJob(forgeBin: string, job: VerifyJob): Promise<{ok: boolean; reason: string}> {
  return new Promise((resolve) => {
    // Use a shell on Windows for anything that isn't a plain *.exe (the PATH "forge" fallback,
    // or a *.cmd/*.bat shim) so PATH resolution + the script-extension launch work; spawning a
    // .cmd/.bat directly with shell:false throws a synchronous EINVAL on Windows. A real
    // forge.exe spawns directly — avoids Node's shell-arg deprecation warning.
    const useShell = process.platform === "win32" && !/\.exe$/i.test(forgeBin);

    let child: import("child_process").ChildProcess;
    try {
      child = spawn(forgeBin, job.args, {
        cwd: REPO_ROOT,
        stdio: ["ignore", "pipe", "pipe"],
        shell: useShell,
      });
    } catch (err: any) {
      // A synchronous spawn failure (e.g. EINVAL) must be collected like any other failure,
      // never abort the whole run.
      resolve({ok: false, reason: `could not start forge: ${err?.message ?? String(err)}`});
      return;
    }

    let out = "";
    const onData = (b: Buffer) => {
      const s = b.toString();
      out += s;
      process.stdout.write(s); // stream forge's progress live so the owner sees --watch polling
    };
    child.stdout?.on("data", onData);
    child.stderr?.on("data", onData);

    child.on("error", (err) => {
      resolve({ok: false, reason: `could not start forge: ${err.message}`});
    });

    child.on("close", (code) => {
      const lower = out.toLowerCase();
      const alreadyVerified =
        lower.includes("already verified") ||
        lower.includes("is already verified") ||
        lower.includes("already been verified");
      if (code === 0 || alreadyVerified) {
        resolve({ok: true, reason: alreadyVerified ? "already verified" : "verified"});
        return;
      }
      // Pull a short, human reason from forge's output for the summary.
      const tail = out.trim().split(/\r?\n/).filter(Boolean).slice(-1)[0] ?? `forge exited ${code}`;
      resolve({ok: false, reason: tail.slice(0, 200)});
    });
  });
}

async function main() {
  const jobs = buildJobs();

  if (wantsPrint()) {
    printOnly(jobs);
    return;
  }

  // ── Execute path ──────────────────────────────────────────────────────────────────────
  // Friendly, specific guard for the one thing the owner must supply.
  const keyErr = apiKeyError(process.env.ETHERSCAN_API_KEY);
  if (keyErr) {
    console.error(keyErr);
    process.exitCode = 1;
    return;
  }
  // forge reads the key from the env var; make sure it's exported to the child process env.
  process.env.ETHERSCAN_API_KEY = (process.env.ETHERSCAN_API_KEY ?? "").trim();

  let forgeBin: string;
  try {
    forgeBin = resolveForge();
  } catch (e: any) {
    console.error("\n" + (e?.message ?? String(e)) + "\n");
    process.exitCode = 1;
    return;
  }

  console.log(`Verifying ${jobs.length} WORDBANK contracts on '${network.name}' with forge --watch.`);
  console.log(`(forge: ${forgeBin}; running from ${REPO_ROOT})\n`);

  const failures: {label: string; reason: string; cmd: string}[] = [];
  for (let i = 0; i < jobs.length; i++) {
    const job = jobs[i];
    console.log(`\n──> Verifying ${job.label} (${i + 1}/${jobs.length})…`);
    const {ok, reason} = await runJob(forgeBin, job);
    if (ok) {
      console.log(`    ✅ ${job.label} — ${reason}`);
    } else {
      console.log(`    ❌ ${job.label} — ${reason}`);
      failures.push({label: job.label, reason, cmd: commandLine(job)});
    }
  }

  // ── Final summary ─────────────────────────────────────────────────────────────────────
  const ok = jobs.length - failures.length;
  console.log(`\n────────────────────────────────────────────────────────`);
  console.log(`${ok}/${jobs.length} verified ✅`);
  if (failures.length > 0) {
    console.log(`FAILED:`);
    for (const f of failures) {
      console.log(`  - ${f.label} — ${f.reason}`);
    }
    console.log(
      `\nRe-run \`npm run verify:${network.name}\` to retry (already-verified contracts are skipped).`,
    );
    console.log(`To debug one by hand, run from the repo root:`);
    for (const f of failures) console.log(`  ${f.cmd}`);
    process.exitCode = 1;
  } else {
    console.log(`All contracts verified. Nothing left to do.`);
  }
}

// Auto-run only when invoked as the entry script (so importing apiKeyError for tests is side-effect free).
if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exitCode = 1;
  });
}
