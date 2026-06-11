/**
 * Phase 1.5 verification — read-only smoke test that the content pipeline landed correctly.
 *
 * Asserts: Renderer sealed; WordBank slots locked; on-chain provenanceHash == keccak256 of
 * assets/assignments.json; spot-check slots round-trip (incl. a honors 1/1); and the sealed
 * Renderer actually renders a real slot through tokenURI (the post-reveal render path — what
 * WordBank.tokenURI calls once the offset is set). Exits non-zero on any failure.
 *
 * Reads addresses/<network>.json. Run: npx hardhat run scripts/verify-content.ts --network <net>
 */
import {ethers, network} from "hardhat";
import {attach, getDeploySigner, loadAddresses} from "./lib";
import {loadArrangement} from "./content";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`FAIL: ${msg}`);
  console.log(`  ok — ${msg}`);
}

async function main() {
  const {signer} = getDeploySigner(network);
  const a = loadAddresses(network.name);
  const bank = attach("WordBank.sol", "WordBank", a.wordBank, signer);
  const renderer = attach("Renderer.sol", "Renderer", a.renderer, signer);
  const {words, provenanceHash} = loadArrangement();

  console.log(`verifying content on ${network.name} — WordBank ${a.wordBank}, Renderer ${a.renderer}`);

  assert(await (renderer as any).contentSealed(), "Renderer.contentSealed() == true");
  assert(await (bank as any).slotsLocked(), "WordBank.slotsLocked() == true");

  const onchainHash = await (bank as any).provenanceHash();
  assert(onchainHash.toLowerCase() === provenanceHash.toLowerCase(), `provenanceHash == ${provenanceHash}`);

  // Spot-check a spread of slots, including one honors 1/1, round-tripping against the file.
  const honorsIdx = words.findIndex((w) => w.honors);
  const sample = [0, 1234, 9999, honorsIdx].filter((i) => i >= 0);
  for (const i of sample) {
    const s = await (bank as any).slotAt(i);
    const w = words[i];
    const ok =
      s.word === w.word &&
      Number(s.category) === w.category &&
      Number(s.material) === w.material &&
      Number(s.ink) === w.ink &&
      Number(s.background) === w.background &&
      s.honors === w.honors;
    assert(ok, `slot ${i} round-trips ("${w.word}"${w.honors ? ", honors" : ""})`);
  }

  // The render path: the sealed Renderer must produce a self-contained data URI from a real
  // slot (this is exactly what WordBank.tokenURI does for a token once the offset is revealed).
  // slotAt returns a read-only ethers Result; copy it into a plain struct before re-encoding.
  for (const i of [0, honorsIdx].filter((j) => j >= 0)) {
    const s = await (bank as any).slotAt(i);
    const wd = {
      word: s.word,
      category: Number(s.category),
      material: Number(s.material),
      ink: Number(s.ink),
      background: Number(s.background),
      honors: s.honors,
    };
    const uri: string = await (renderer as any).tokenURI(i + 1, wd);
    assert(uri.startsWith("data:application/json;base64,"), `Renderer.tokenURI renders slot ${i}${wd.honors ? " (honors)" : ""}`);
  }

  console.log("PASS — content pipeline verified end to end.");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
