/**
 * Phase 1.5 (B) — upload the Renderer's on-chain content, then seal.
 *
 * Uploads the subsetted Fraunces font (SSTORE2 chunks), the 20 material fragments + their
 * validInks/validBackgrounds tables, and the 25 honors 1/1 artworks, then calls seal().
 * Until sealed, WordBank.tokenURI reverts NotSealed (no art — not even the pre-reveal
 * placeholder). Mirrors test/utils/RendererAssets.sol; what is tested is what ships.
 *
 * IDEMPOTENT + RESUMABLE: skips font chunks / materials / honors already present, so an
 * RPC hiccup mid-run is fixed by simply re-running. Owner-only calls → signer must be the
 * Renderer admin (the Phase-1 deployer).
 *
 * Reads addresses/<network>.json. Run: npx hardhat run scripts/01b-upload-renderer.ts --network <net>
 */
import {ethers, network} from "hardhat";
import {attach, getDeploySigner, loadAddresses} from "./lib";
import {loadFontChunks, loadMaterials, loadHonors, requireAuthority} from "./content";

/** Counts already-uploaded font chunks by probing the public `fontChunks(i)` array getter. */
async function uploadedFontChunks(renderer: any): Promise<number> {
  let i = 0;
  for (;;) {
    try {
      await renderer.fontChunks(i);
      i++;
    } catch {
      return i;
    }
  }
}

async function main() {
  const {signer} = getDeploySigner(network);
  const a = loadAddresses(network.name);
  const renderer = attach("Renderer.sol", "Renderer", a.renderer, signer);

  requireAuthority(await signer.getAddress(), await (renderer as any).admin(), "Renderer admin");

  if (await (renderer as any).contentSealed()) {
    console.log(`Renderer ${a.renderer} is already sealed — nothing to do.`);
    return;
  }

  // 1. Font (append-only): upload any chunks not yet on-chain.
  const chunks = loadFontChunks();
  const haveChunks = await uploadedFontChunks(renderer);
  if (haveChunks >= chunks.length) {
    console.log(`font: ${haveChunks}/${chunks.length} chunks already present — skipping`);
  } else {
    const remaining = chunks.slice(haveChunks);
    console.log(`font: uploading chunks ${haveChunks}..${chunks.length - 1} (${remaining.length})`);
    await (await (renderer as any).addFontChunks(remaining)).wait();
  }

  // 2. Materials (append-only, id == index): upload from materialCount() onward.
  const materials = loadMaterials();
  let haveMats = Number(await (renderer as any).materialCount());
  console.log(`materials: ${haveMats}/${materials.length} present`);
  for (let i = haveMats; i < materials.length; i++) {
    const m = materials[i];
    await (await (renderer as any).addMaterial(m.name, m.tier, m.safeWidth, m.fragment, m.inks, m.backgrounds)).wait();
    console.log(`  + material ${i} ${m.name} (${m.inks.length} inks, ${m.backgrounds.length} backgrounds)`);
  }

  // 3. Honors (keyed by word): upload any not already stored.
  const honors = loadHonors();
  let added = 0;
  for (const h of honors) {
    if (await (renderer as any).hasHonorsArt(h.word)) continue;
    await (await (renderer as any).addHonorsArt(h.word, h.art)).wait();
    added++;
    console.log(`  + honors ${h.word} (${h.art.length} bytes)`);
  }
  console.log(`honors: ${honors.length - added} already present, ${added} uploaded`);

  // 4. Seal — irreversible; required before tokenURI serves.
  console.log("sealing Renderer content (irreversible)…");
  await (await (renderer as any).seal()).wait();
  if (!(await (renderer as any).contentSealed())) throw new Error("seal() did not take effect");
  console.log(`Renderer SEALED: font ${chunks.length} chunk(s), ${materials.length} materials, ${honors.length} honors.`);
  console.log("NEXT: scripts/01c-upload-slots.ts (write + lock the 10,000 word slots).");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
