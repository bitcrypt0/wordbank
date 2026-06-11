/**
 * Phase 1 — deploy and wire the protocol (mirror of script/01_DeployProtocol.s.sol).
 *
 * Order: WordBank (deploys WordToken) → Renderer → BountyEngine → RewardsDistributor →
 * BurnEngine → FeeHook (CREATE2 at a mined flag-encoding address) → LPLocker →
 * RoyaltySplitter → wiring (incl. setRoyalty(splitter, 300)).
 *
 * RESUMABLE + RECOVERABLE (mainnet-incident hardening):
 *  - Each contract is deployed only if not already recorded in addresses/<network>.json, and
 *    the file is written IMMEDIATELY after each deploy — so a crash mid-deploy never orphans a
 *    live contract; just re-run and it continues.
 *  - The one-time wiring calls are skipped if already done (read on-chain getters).
 *  - WORDBANK_ADDRESS env override: resume by REUSING an already-live WordBank (its WordToken
 *    is read from `wordBank.wordToken()`) instead of redeploying — for recovering a run that
 *    crashed after the WordBank tx mined.
 *  - The signer comes from getDeploySigner(), whose provider normalizes `to:""`→null so RPCs
 *    that return that for creation txs can't crash ethers v6.
 *
 * Env: ADMIN, POOL_MANAGER, POSITION_MANAGER, WETH (must equal the chain's canonical WETH9 —
 * RS-2 guard); optional LP_FEE (3000), TICK_SPACING (60), WETH_OVERRIDE (unknown chainid only),
 * WORDBANK_ADDRESS (resume/recovery — reuse this live WordBank).
 * Run:  npx hardhat run scripts/01-deploy-protocol.ts --network <net>
 */
import {network} from "hardhat";
import {ethers} from "ethers";
import {
  attach,
  coder,
  deployViaCreate2,
  env,
  factory,
  getDeploySigner,
  loadAddressesOrEmpty,
  mineHookSalt,
  saveAddresses,
} from "./lib";

const LAUNCH_ROYALTY_BPS = 300; // 3% at launch; admin-settable on WordBank (ceiling 1000)

// RS-2 (SYS-3): canonical WETH9 per chain, sourced from the official WETH/Uniswap deployments
// (same discipline as the V4 addresses). The RoyaltySplitter's `weth` has no on-chain
// validation beyond non-zero, and a wrong WETH breaks the trustless WETH split — so a wrong
// WETH must never ship on a known chain.
const CANONICAL_WETH9: Record<string, string> = {
  "1": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", // Ethereum mainnet
  "11155111": "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14", // Sepolia
};

async function resolveCanonicalWeth(chainId: string): Promise<string> {
  const canonical = CANONICAL_WETH9[chainId];
  if (canonical) {
    const configured = env("WETH");
    if (ethers.getAddress(configured) !== ethers.getAddress(canonical)) {
      throw new Error(`RS-2: WETH env (${configured}) != canonical WETH9 (${canonical}) for chainId ${chainId}`);
    }
    return ethers.getAddress(canonical);
  }
  const override = process.env.WETH_OVERRIDE;
  if (!override) {
    throw new Error(`RS-2: unknown chainId ${chainId} - set WETH_OVERRIDE to this chain's WETH9 (bare-anvil only)`);
  }
  return ethers.getAddress(override);
}

async function main() {
  const {signer, provider} = getDeploySigner(network);
  const net = network.name;
  const chainId = (await provider.getNetwork()).chainId.toString();

  const admin = env("ADMIN", await signer.getAddress());
  const poolManager = env("POOL_MANAGER");
  const positionManager = env("POSITION_MANAGER");
  const weth = await resolveCanonicalWeth(chainId);
  const lpFee = Number(env("LP_FEE", "3000"));
  const tickSpacing = Number(env("TICK_SPACING", "60"));

  console.log(`deployer: ${await signer.getAddress()}  network: ${net}  chainId: ${chainId}  WETH9: ${weth}`);

  // Resume ledger: what (if anything) was already deployed. Persist config up-front so a crash
  // still leaves a usable file.
  const addrs = loadAddressesOrEmpty(net);
  saveAddresses(net, {admin, poolManager, positionManager, weth, lpFee, tickSpacing, royaltyBps: LAUNCH_ROYALTY_BPS});

  // Deploy a contract and WAIT for it to mine before returning its address — so nonces
  // serialize and the next deploy/wiring tx never collides ("nonce too low").
  const deployAndWait = async (file: string, name: string, args: unknown[]): Promise<string> => {
    const c = await factory(file, name, signer).deploy(...args);
    await c.waitForDeployment();
    return c.getAddress();
  };

  // Deploy `key` only if not already recorded (with code on-chain); save immediately on deploy.
  const deployOrReuse = async (key: string, label: string, deploy: () => Promise<string>): Promise<string> => {
    if (addrs[key]) {
      const code = await provider.getCode(addrs[key]);
      if (code && code !== "0x") {
        console.log(`${label}: already deployed at ${addrs[key]} — skip`);
        return addrs[key];
      }
      console.log(`${label}: recorded ${addrs[key]} has no code — redeploying`);
    }
    const addr = await deploy();
    addrs[key] = addr;
    saveAddresses(net, {[key]: addr}); // incremental: recoverable if the next step crashes
    console.log(`${label}: ${addr}`);
    return addr;
  };

  // 1. WordBank (deploys WordToken). WORDBANK_ADDRESS resumes by reusing a live one.
  const wordbankOverride = process.env.WORDBANK_ADDRESS?.trim();
  let wordBankAddr: string;
  if (wordbankOverride) {
    wordBankAddr = ethers.getAddress(wordbankOverride);
    const code = await provider.getCode(wordBankAddr);
    if (!code || code === "0x") throw new Error(`WORDBANK_ADDRESS ${wordBankAddr} has no code on chainId ${chainId}`);
    console.log(`WordBank:            ${wordBankAddr} (reused via WORDBANK_ADDRESS)`);
  } else if (addrs.wordBank && (await provider.getCode(addrs.wordBank)) !== "0x") {
    wordBankAddr = addrs.wordBank;
    console.log(`WordBank:            ${wordBankAddr} — skip`);
  } else {
    wordBankAddr = await deployAndWait("WordBank.sol", "WordBank", [admin]);
    console.log(`WordBank:            ${wordBankAddr}`);
  }
  const wordBank = attach("WordBank.sol", "WordBank", wordBankAddr, signer);
  // WordToken is whatever the WordBank deployed in its constructor (read from chain, not guessed).
  const wordToken = await (wordBank as any).wordToken();
  addrs.wordBank = wordBankAddr;
  addrs.wordToken = wordToken;
  saveAddresses(net, {wordBank: wordBankAddr, wordToken});
  console.log(`WordToken:           ${wordToken}`);

  // 2. Renderer (content upload is agent-2 tooling — runbook step).
  const renderer = await deployOrReuse("renderer", "Renderer", () => deployAndWait("Renderer.sol", "Renderer", []));

  // 3. Game-side fee consumers.
  const bountyEngine = await deployOrReuse("bountyEngine", "BountyEngine", () =>
    deployAndWait("BountyEngine.sol", "BountyEngine", [wordBankAddr, admin]),
  );
  const rewardsDistributor = await deployOrReuse("rewardsDistributor", "RewardsDistributor", () =>
    deployAndWait("RewardsDistributor.sol", "RewardsDistributor", [wordBankAddr, bountyEngine]),
  );

  // 4. BurnEngine (pool key wired in phase 2, after the pool exists).
  const burnEngine = await deployOrReuse("burnEngine", "BurnEngine", () =>
    deployAndWait("BurnEngine.sol", "BurnEngine", [poolManager, wordToken, rewardsDistributor, admin]),
  );

  // 5. FeeHook via CREATE2 at a mined address encoding exactly the four permission flags.
  const hookArgs = coder.encode(
    ["address", "address", "uint24", "int24", "address", "address", "address", "address"],
    [poolManager, wordToken, lpFee, tickSpacing, rewardsDistributor, bountyEngine, burnEngine, admin],
  );
  let feeHook: string;
  if (addrs.feeHook && (await provider.getCode(addrs.feeHook)) !== "0x") {
    feeHook = addrs.feeHook;
    console.log(`FeeHook:             ${feeHook} — skip`);
  } else {
    const hookArtifact = factory("FeeHook.sol", "FeeHook", signer);
    const initCode = ethers.concat([hookArtifact.bytecode, hookArgs]);
    const {salt, address: predictedHook} = mineHookSalt(initCode);
    console.log(`mined hook address ${predictedHook} (salt ${salt})`);
    feeHook = await deployViaCreate2(signer, salt, initCode);
    if (feeHook.toLowerCase() !== predictedHook.toLowerCase()) throw new Error("hook address mismatch");
    addrs.feeHook = feeHook;
    saveAddresses(net, {feeHook, feeHookSalt: salt, feeHookConstructorArgs: hookArgs});
    console.log(`FeeHook:             ${feeHook}`);
  }

  // 6. LPLocker.
  const lpLocker = await deployOrReuse("lpLocker", "LPLocker", () =>
    deployAndWait("LPLocker.sol", "LPLocker", [positionManager, admin]),
  );

  // 7. RoyaltySplitter — trustless ERC-2981 receiver (needs BurnEngine + BountyEngine).
  const royaltySplitter = await deployOrReuse("royaltySplitter", "RoyaltySplitter", () =>
    deployAndWait("RoyaltySplitter.sol", "RoyaltySplitter", [burnEngine, bountyEngine, admin, weth]),
  );

  // 8. One-time wiring (admin-gated, set-once). Each call is skipped if already done.
  const token = attach("WordToken.sol", "WordToken", wordToken, signer);
  if ((await (wordBank as any).renderer()) === ethers.ZeroAddress) {
    await (await (wordBank as any).setRenderer(renderer)).wait();
    console.log("wired: setRenderer");
  } else {
    console.log("wiring setRenderer: already done — skip");
  }
  if ((await (wordBank as any).rewardsDistributor()) === ethers.ZeroAddress) {
    await (await (wordBank as any).setRewardsDistributor(rewardsDistributor)).wait();
    console.log("wired: setRewardsDistributor");
  } else {
    console.log("wiring setRewardsDistributor: already done — skip");
  }
  if ((await (token as any).burner()) === ethers.ZeroAddress) {
    await (await (token as any).setBurner(burnEngine)).wait();
    console.log("wired: setBurner");
  } else {
    console.log("wiring setBurner: already done — skip");
  }
  // setRoyalty: ERC-2981 receiver should be the splitter (read royaltyInfo to detect).
  const [royaltyReceiver] = await (wordBank as any).royaltyInfo(0, 1_000_000);
  if (ethers.getAddress(royaltyReceiver) !== ethers.getAddress(royaltySplitter)) {
    await (await (wordBank as any).setRoyalty(royaltySplitter, LAUNCH_ROYALTY_BPS)).wait();
    console.log("wired: setRoyalty (splitter @ 300 bps)");
  } else {
    console.log("wiring setRoyalty: already done — skip");
  }

  // RS-2 post-deploy assertion: the live splitter's WETH must be the canonical WETH9.
  const onchainWeth = await attach("RoyaltySplitter.sol", "RoyaltySplitter", royaltySplitter, signer).weth();
  if (ethers.getAddress(onchainWeth) !== ethers.getAddress(weth)) {
    throw new Error(`RS-2: royaltySplitter.weth() (${onchainWeth}) != canonical WETH9 (${weth})`);
  }
  console.log(`verified RoyaltySplitter.weth() == canonical WETH9: ${onchainWeth}`);

  // Final consolidated save (idempotent — the file already has each piece from incremental saves).
  saveAddresses(net, {
    admin,
    poolManager,
    positionManager,
    weth,
    lpFee,
    tickSpacing,
    wordBank: wordBankAddr,
    wordToken,
    renderer,
    bountyEngine,
    rewardsDistributor,
    burnEngine,
    feeHook,
    lpLocker,
    royaltySplitter,
    royaltyBps: LAUNCH_ROYALTY_BPS,
  });

  console.log("Phase 1 complete.");
  console.log("NEXT: verify all contracts (npm run verify-commands), agent-2 renderer content upload,");
  console.log("      sale config + mint phase, then scripts/02-seed-and-launch.ts");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
