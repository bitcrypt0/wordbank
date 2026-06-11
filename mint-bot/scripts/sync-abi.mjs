/**
 * ABI sync — the mint bot uses the SAME Foundry-compiled WordBank ABI as the
 * protocol (root AGENTS.md: Foundry is the compiler of record). This reads the
 * forge artifact under ../../out and writes lib/WordBank.json. NEVER hand-copy
 * the ABI; re-run after any `forge build` that changes WordBank's surface.
 *
 *   node scripts/sync-abi.mjs        (or: npm run sync:abi)
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.resolve(HERE, "..", "..", "out", "WordBank.sol", "WordBank.json");
const OUT = path.resolve(HERE, "..", "lib", "WordBank.json");

if (!fs.existsSync(SRC)) {
  console.error(`Missing forge artifact ${SRC} — run \`forge build\` at the repo root first.`);
  process.exit(1);
}

const artifact = JSON.parse(fs.readFileSync(SRC, "utf8"));
if (!Array.isArray(artifact.abi)) {
  console.error("Artifact has no abi array.");
  process.exit(1);
}

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(
  OUT,
  JSON.stringify({ contractName: "WordBank", abi: artifact.abi }, null, 2) + "\n",
);
console.log(`sync-abi: wrote ${artifact.abi.length} ABI entries → lib/WordBank.json`);
