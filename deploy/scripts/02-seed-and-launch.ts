/**
 * Phase 2a — mint the 1M liquidity WORD and seed the canonical ETH/WORD pool
 * (mirror of script/02_SeedPoolAndLaunch.s.sol).
 *
 * SEEDING ONLY. As of the 2026-06-16 change order, locking the position and enabling trading
 * are carved out into separate, owner-paced manual scripts so the owner controls their timing:
 *   • 04-lock-liquidity.ts  (npm run lock-liquidity)   — lock the position in the LPLocker
 *   • 05-enable-trading.ts  (npm run enable-trading)   — flip the trading switch
 * This script stops after the pool is seeded and wired into the BurnEngine. Trading stays OFF
 * and the position NFT sits UNlocked in the admin wallet until those two steps are run.
 *
 * RESUMABLE: every step checks on-chain state and is skipped if already done, so a re-run
 * after a crash (or a manual partial run) safely continues from where it stopped — it never
 * re-mints liquidity, re-mints a position, or double-spends.
 *
 * Env: SQRT_PRICE_X96 (launch price — see RUNBOOK), ETH_LIQUIDITY (wei); optional
 *   WORD_LIQUIDITY (1,000,000e18), POSITION_TOKEN_ID (resume/recovery: adopt an existing
 *   position instead of minting a new one — see RUNBOOK "if something goes wrong").
 * Addresses come from addresses/<network>.json (phase 1 output); positionTokenId is written
 * back the instant a position is minted so a crash-after-mint is recoverable.
 * Run:  npx hardhat run scripts/02-seed-and-launch.ts --network <net>
 */
import {ethers, network} from "hardhat";
import type {Contract} from "ethers";
import {
  PERMIT2,
  POOL_KEY_TUPLE,
  attach,
  coder,
  env,
  getDeploySigner,
  liquidityForAmounts,
  loadAddresses,
  saveAddresses,
  sqrtPriceAtTick,
} from "./lib";

// v4-periphery Actions (frozen byte values).
const MINT_POSITION = "0x02";
const SETTLE_PAIR = "0x0d";
const SWEEP = "0x14";

const PERMIT2_ABI = [
  "function approve(address token, address spender, uint160 amount, uint48 expiration)",
  "function allowance(address owner, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)",
];
const POSM_ABI = [
  "function modifyLiquidities(bytes unlockData, uint256 deadline) payable",
  "function nextTokenId() view returns (uint256)",
  "function approve(address to, uint256 tokenId)",
  "function ownerOf(uint256 tokenId) view returns (address)",
];
const POOL_MANAGER_ABI = [
  `function initialize(${POOL_KEY_TUPLE} key, uint160 sqrtPriceX96) returns (int24)`,
  "function extsload(bytes32 slot) view returns (bytes32)",
];

const MASK_160 = (1n << 160n) - 1n;
const POOLS_SLOT = "0x0000000000000000000000000000000000000000000000000000000000000006"; // StateLibrary.POOLS_SLOT

/** True if the canonical pool already has a non-zero sqrtPrice (i.e. it is initialized). Read
 *  straight from the PoolManager via extsload + StateLibrary slot math — no StateView needed. */
async function poolInitialized(poolManager: Contract, key: any): Promise<boolean> {
  const poolId = ethers.keccak256(coder.encode([POOL_KEY_TUPLE], [key]));
  const stateSlot = ethers.keccak256(ethers.concat([poolId, POOLS_SLOT]));
  const slot0 = await poolManager.extsload(stateSlot);
  const sqrtPriceX96 = BigInt(slot0) & MASK_160;
  return sqrtPriceX96 !== 0n;
}

async function main() {
  const {signer, provider} = getDeploySigner(network);
  const a = loadAddresses(network.name);
  const admin = a.admin as string;

  const sqrtPriceX96 = BigInt(env("SQRT_PRICE_X96"));
  const ethLiquidity = BigInt(env("ETH_LIQUIDITY"));
  const wordLiquidity = BigInt(env("WORD_LIQUIDITY", (1_000_000n * 10n ** 18n).toString()));
  const positionOverride = process.env.POSITION_TOKEN_ID?.trim();

  const wordToken = attach("WordToken.sol", "WordToken", a.wordToken, signer);
  const burnEngine = attach("BurnEngine.sol", "BurnEngine", a.burnEngine, signer);
  const poolManager = new ethers.Contract(a.poolManager, POOL_MANAGER_ABI, signer);
  const posm = new ethers.Contract(a.positionManager, POSM_ABI, signer);
  const permit2 = new ethers.Contract(PERMIT2, PERMIT2_ABI, signer);

  const key = {
    currency0: ethers.ZeroAddress, // native ETH always sorts first
    currency1: a.wordToken,
    fee: a.lpFee,
    tickSpacing: a.tickSpacing,
    hooks: a.feeHook,
  };

  // Full range, aligned to tick spacing (MIN/MAX_TICK = ±887272).
  const tickUpper = Math.floor(887272 / a.tickSpacing) * a.tickSpacing;
  const tickLower = -tickUpper;
  const liquidity = liquidityForAmounts(
    sqrtPriceX96,
    sqrtPriceAtTick(tickLower),
    sqrtPriceAtTick(tickUpper),
    ethLiquidity,
    wordLiquidity,
  );
  console.log(`full range [${tickLower}, ${tickUpper}], liquidity ${liquidity}`);

  // 1. Mint the liquidity allotment (≤ 1,000,000e18, enforced by the token). Skip if done.
  if ((await (wordToken as any).liquidityMinted()) >= wordLiquidity) {
    console.log("step 1 mintLiquidity: already done — skip");
  } else {
    console.log("minting liquidity WORD…");
    await (await (wordToken as any).mintLiquidity(admin, wordLiquidity)).wait();
  }

  // 2. Approvals: WORD → Permit2 → PositionManager. Idempotent (allowance-checked).
  if ((await (wordToken as any).allowance(admin, PERMIT2)) >= wordLiquidity) {
    console.log("step 2a WORD→Permit2 approval: already done — skip");
  } else {
    await (await (wordToken as any).approve(PERMIT2, ethers.MaxUint256)).wait();
  }
  const [p2amount, p2exp] = await permit2.allowance(admin, a.wordToken, a.positionManager);
  const nowTs = BigInt((await provider.getBlock("latest"))!.timestamp);
  if (BigInt(p2amount) >= wordLiquidity && BigInt(p2exp) > nowTs) {
    console.log("step 2b Permit2→POSM approval: already done — skip");
  } else {
    await (await permit2.approve(a.wordToken, a.positionManager, MASK_160, (1n << 48n) - 1n)).wait();
  }

  // 3. Initialize the canonical pool (swaps stay gated until enableTrading — no snipe window).
  if (await poolInitialized(poolManager, key)) {
    console.log("step 3 initialize pool: already done — skip");
  } else {
    console.log("initializing pool…");
    await (await poolManager.initialize(key, sqrtPriceX96)).wait();
  }

  // 4. Determine the position tokenId: an explicit override (recovery), else a previously
  //    recorded one (resume), else mint a fresh position and record it IMMEDIATELY.
  let tokenId: bigint;
  if (positionOverride) {
    tokenId = BigInt(positionOverride);
    console.log(`step 4 position: using POSITION_TOKEN_ID override ${tokenId} — skip mint`);
    saveAddresses(network.name, {positionTokenId: tokenId.toString()});
  } else if (a.positionTokenId) {
    tokenId = BigInt(a.positionTokenId);
    console.log(`step 4 position: resuming recorded tokenId ${tokenId} — skip mint`);
  } else {
    const actions = ethers.concat([MINT_POSITION, SETTLE_PAIR, SWEEP]);
    const params = [
      coder.encode(
        [POOL_KEY_TUPLE, "int24", "int24", "uint256", "uint128", "uint128", "address", "bytes"],
        [key, tickLower, tickUpper, liquidity, ethLiquidity, wordLiquidity, admin, "0x"],
      ),
      coder.encode(["address", "address"], [key.currency0, key.currency1]),
      coder.encode(["address", "address"], [key.currency0, admin]),
    ];
    const unlockData = coder.encode(["bytes", "bytes[]"], [actions, params]);
    const deadline = nowTs + 1800n;
    console.log("minting position…");
    await (await posm.modifyLiquidities(unlockData, deadline, {value: ethLiquidity})).wait();
    tokenId = (await posm.nextTokenId()) - 1n;
    // Record IMMEDIATELY so a crash before lock is recoverable (no need for POSITION_TOKEN_ID).
    saveAddresses(network.name, {positionTokenId: tokenId.toString()});
    console.log(`position tokenId ${tokenId} (recorded)`);
  }

  // 5. Wire the pool into the BurnEngine (one-time). This is pool wiring, not lock/trade
  //    activation, and it needs the pool initialized — so it belongs here. Skip if already set.
  //    (The old step-5 LPLocker lock + step-7 enableTrading were carved out into the separate
  //    04-lock-liquidity.ts / 05-enable-trading.ts manual scripts per the 2026-06-16 change order.)
  if (await (burnEngine as any).poolSet()) {
    console.log("step 5 setPool: already done — skip");
  } else {
    await (await (burnEngine as any).setPool(key)).wait();
    console.log("step 5 setPool: BurnEngine pointed at the pool");
  }

  console.log("");
  console.log("Phase 2a complete — pool SEEDED. Trading is OFF and the position is UNlocked.");
  console.log(`  position tokenId ${tokenId} held by ${admin}`);
  console.log("TWO MANUAL STEPS REMAIN, on your own schedule (recommended order: lock, then trading):");
  console.log("  • npm run lock-liquidity   (04-lock-liquidity.ts) — lock the position for >= 1 year");
  console.log("  • npm run enable-trading   (05-enable-trading.ts) — flip trading live");
  console.log("Do NOT announce the token/pool address until AFTER enable-trading (gated swaps look");
  console.log("like a honeypot to scanners), and do NOT publish the LPLocker claim until after lock.");
  console.log("Independent of Phase 2.5 (sync-registry) and Phase 3 (seal-and-renounce).");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
