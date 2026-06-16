/**
 * Mint-assembly correctness check (no network, no broadcast).
 *
 * We cannot fire real mainnet mints here, so instead we PROVE the call-assembly
 * logic in lib/mint.ts is correct:
 *   1. phase → correct function (earlyBirdMint vs publicMint vs disabled)
 *   2. exact msg.value = unitPrice × count (BigInt, no float)
 *   3. early-bird per-wallet cap detection (incl. cap 0 blocks all)
 *   4. underfunded-wallet detection (balance < value + gas → skip)
 *
 * lib/mint.ts is the SINGLE source of truth — this script transpiles it with
 * the TypeScript compiler (a devDependency) and imports the real functions, so
 * the test can never drift from the shipped code.
 *
 *   node scripts/check-mint.mjs   (or: npm run check:mint)
 */
import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import ts from 'typescript';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.resolve(HERE, '..', 'lib', 'mint.ts');
const OUT = path.resolve(HERE, '..', 'lib', '.mint.check.mjs');

// Transpile lib/mint.ts → ESM JS and import the REAL functions.
const source = fs.readFileSync(SRC, 'utf8');
const js = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
}).outputText;
fs.writeFileSync(OUT, js);

const { SalePhase, selectMintPlan, mintValueWei, earlyBirdCapCheck, fundingCheck } = await import(
  pathToFileURL(OUT).href
);
fs.rmSync(OUT, { force: true });

let pass = 0;
let fail = 0;
function check(name, cond, detail = '') {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; console.log(`  FAIL  ${name}  ${detail}`); }
}

const eb = 10_000_000_000_000_000n; // 0.01 ETH
const pub = 20_000_000_000_000_000n; // 0.02 ETH

console.log('1) Phase → function + unit price');
{
  const ebPlan = selectMintPlan(SalePhase.EarlyBird, eb, pub);
  check('EarlyBird selects earlyBirdMint', ebPlan.mintable && ebPlan.fn === 'earlyBirdMint', JSON.stringify(ebPlan, bi));
  check('EarlyBird unit price = earlyBirdPrice', ebPlan.unitPriceWei === eb, `${ebPlan.unitPriceWei}`);

  const pubPlan = selectMintPlan(SalePhase.PublicSale, eb, pub);
  check('PublicSale selects publicMint', pubPlan.mintable && pubPlan.fn === 'publicMint', JSON.stringify(pubPlan, bi));
  check('PublicSale unit price = publicPrice', pubPlan.unitPriceWei === pub, `${pubPlan.unitPriceWei}`);

  const setup = selectMintPlan(SalePhase.Setup, eb, pub);
  check('Setup disables mint with reason', !setup.mintable && !!setup.reason, JSON.stringify(setup, bi));
  const between = selectMintPlan(SalePhase.Between, eb, pub);
  check('Between disables mint with reason', !between.mintable && !!between.reason, JSON.stringify(between, bi));
  const unknown = selectMintPlan(99, eb, pub);
  check('Unknown phase disables mint', !unknown.mintable, JSON.stringify(unknown, bi));
}

console.log('2) Exact msg.value = price × count');
{
  check('eb × 1 = 0.01', mintValueWei(eb, 1) === eb, `${mintValueWei(eb, 1)}`);
  check('eb × 3 = 0.03', mintValueWei(eb, 3) === 30_000_000_000_000_000n, `${mintValueWei(eb, 3)}`);
  check('pub × 5 = 0.10', mintValueWei(pub, 5) === 100_000_000_000_000_000n, `${mintValueWei(pub, 5)}`);
  // odd price that floats would mangle
  const odd = 33_333_333_333_333_333n;
  check('odd × 7 exact (no float drift)', mintValueWei(odd, 7) === odd * 7n, `${mintValueWei(odd, 7)}`);
  let threw = false;
  try { mintValueWei(eb, 0); } catch { threw = true; }
  check('count 0 throws', threw);
  threw = false;
  try { mintValueWei(eb, 1.5); } catch { threw = true; }
  check('non-integer count throws', threw);
}

console.log('3) Early-bird per-wallet cap');
{
  check('cap 0 blocks all', earlyBirdCapCheck(0n, 0n, 1).ok === false);
  check('within cap ok', earlyBirdCapCheck(5n, 2n, 3).ok === true);
  check('at cap exactly ok', earlyBirdCapCheck(5n, 0n, 5).ok === true);
  check('over cap flagged', earlyBirdCapCheck(5n, 3n, 3).ok === false);
  check('over cap has reason', !!earlyBirdCapCheck(5n, 3n, 3).reason);
}

console.log('4) Underfunded-wallet detection');
{
  const gasLimit = 300_000n;
  const gasPrice = 20_000_000_000n; // 20 gwei
  const value = mintValueWei(pub, 1); // 0.02 ETH
  // required = value + gas*1.15
  const gasCost = gasLimit * gasPrice; // 0.006 ETH
  const required = value + (gasCost * 11500n) / 10000n;

  const exactlyEnough = fundingCheck({ balanceWei: required, valueWei: value, gasLimit, gasPriceWei: gasPrice });
  check('balance == required → ok', exactlyEnough.ok === true, JSON.stringify(exactlyEnough, bi));
  check('required matches formula', exactlyEnough.requiredWei === required, `${exactlyEnough.requiredWei} vs ${required}`);

  const oneWeiShort = fundingCheck({ balanceWei: required - 1n, valueWei: value, gasLimit, gasPriceWei: gasPrice });
  check('1 wei short → skip', oneWeiShort.ok === false);
  check('shortfall = 1 wei', oneWeiShort.shortfallWei === 1n, `${oneWeiShort.shortfallWei}`);

  const broke = fundingCheck({ balanceWei: value, valueWei: value, gasLimit, gasPriceWei: gasPrice });
  check('exactly value but no gas → skip', broke.ok === false, JSON.stringify(broke, bi));

  const flush = fundingCheck({ balanceWei: required * 2n, valueWei: value, gasLimit, gasPriceWei: gasPrice });
  check('plenty → ok', flush.ok === true);
}

function bi(_k, v) { return typeof v === 'bigint' ? v.toString() : v; }

console.log(`\n${fail === 0 ? 'ALL CHECKS PASSED' : 'CHECKS FAILED'}: ${pass} passed, ${fail} failed.`);
process.exit(fail === 0 ? 0 : 1);
