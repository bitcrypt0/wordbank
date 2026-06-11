/**
 * Unit test for the RPC `to: ""` normalizer (RS / mainnet-incident fix).
 * Run:  npm run test:normalize   (npx ts-node scripts/normalize.test.ts)
 *
 * Pure, no network — proves a contract-creation response's empty `to` becomes null while
 * everything else is left untouched, which is what stops ethers v6 from crashing on RPCs
 * that return `to: ""` for creation txs.
 */
import * as assert from "assert";
import {normalizeTxTo} from "./lib";

let passed = 0;
function check(name: string, fn: () => void) {
  fn();
  passed++;
  console.log(`  ok  ${name}`);
}

// 1. The bug case: a creation-tx receipt/response with to:"" → to:null.
check('{to:""} → to:null', () => {
  const r: any = {to: "", contractAddress: "0xabc", status: 1};
  normalizeTxTo(r);
  assert.strictEqual(r.to, null);
  assert.strictEqual(r.contractAddress, "0xabc"); // other fields untouched
});

// 2. A normal call tx (to set to a real address) is left untouched.
check('{to:"0x.."} untouched', () => {
  const addr = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
  const r: any = {to: addr};
  normalizeTxTo(r);
  assert.strictEqual(r.to, addr);
});

// 3. Already-null `to` (what well-behaved RPCs send for creations) stays null.
check("{to:null} stays null", () => {
  const r: any = {to: null, contractAddress: "0xabc"};
  normalizeTxTo(r);
  assert.strictEqual(r.to, null);
});

// 4. A response with no `to` field at all is untouched (no crash).
check("{} untouched", () => {
  const r: any = {hash: "0xdead"};
  normalizeTxTo(r);
  assert.strictEqual("to" in r, false);
});

// 5. null / undefined results are safe (the RPC returns null when a tx is not yet mined).
check("null / undefined safe", () => {
  assert.strictEqual(normalizeTxTo(null), null);
  assert.strictEqual(normalizeTxTo(undefined), undefined);
});

// 6. Does not coerce a legitimately empty-string elsewhere (only `to`).
check("only the `to` field is touched", () => {
  const r: any = {to: "0x..", input: ""};
  normalizeTxTo(r);
  assert.strictEqual(r.input, ""); // unrelated empty string preserved
});

console.log(`\nnormalizeTxTo: ${passed}/6 checks passed`);
