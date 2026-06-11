/**
 * Phase 3 — seal WORD minting and renounce token ownership (mirror of
 * script/03_SealAndRenounce.s.sol). IRREVERSIBLE — read the preconditions.
 *
 * Run ONLY after: all 10,000 NFTs minted (INCLUDING the 200 admin-reserve), the 1M liquidity
 * allotment minted (phase 2), burner wired (phase 1). Renouncing kills setBurner and
 * mintLiquidity forever; scanners then read owner = 0x0 — RUNBOOK hygiene #2.
 *
 * Run:  npx hardhat run scripts/03-seal-and-renounce.ts --network <net>
 */
import {ethers, network} from "hardhat";
import {attach, getDeploySigner, loadAddresses} from "./lib";

async function main() {
  const {signer} = getDeploySigner(network);
  const a = loadAddresses(network.name);
  const token = attach("WordToken.sol", "WordToken", a.wordToken, signer) as any;

  // Hard preconditions — abort loudly rather than renounce a half-wired token.
  if ((await token.burner()) === ethers.ZeroAddress) throw new Error("burner not wired");
  if ((await token.liquidityMinted()) !== (await token.LIQUIDITY_CAP()))
    throw new Error("liquidity allotment not fully minted");
  if ((await token.backingMinted()) !== (await token.BACKING_CAP()))
    throw new Error("NFT mint-out incomplete (did you mint the 200 admin-reserve?)");

  if (!(await token.mintingSealed())) {
    console.log("sealing minting…");
    await (await token.sealMinting()).wait();
  }
  console.log("renouncing WordToken ownership (IRREVERSIBLE)…");
  await (await token.renounceOwnership()).wait();

  console.log(`sealed at totalSupply ${await token.totalSupply()}; owner is now ${await token.owner()}`);
  console.log("Supply can now only fall, via buy-and-burn, to the 10,000,000e18 floor.");
  console.log("BUY-AND-BURN IS NOW LIVE: executeBuyback() works from this moment (SYS-1) —");
  console.log("keepers will start spending the accrued burn slice for the 1% tip.");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
