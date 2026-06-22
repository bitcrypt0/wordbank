/**
 * WORD v2 RELAUNCH — Phase 2: seed the new ETH/WORD pool.
 *
 * Initializes the canonical ETH/WORD-v2 pool (hooked by FeeHookV2) at a launch price derived
 * from the seed ratio, then mints a full-range position with the deployer's `lpPremint` WORD +
 * `ETH_LIQUIDITY` ETH. The position NFT lands UNlocked in the admin wallet — locking is done on
 * UNCX (manual, see the printed steps), NOT the in-house LPLocker. Trading stays OFF until
 * v2-03-enable-trading.ts.
 *
 * The launch price (sqrtPriceX96) is COMPUTED from the actual seed amounts (lpPremint : ETH), so
 * it always matches whatever the snapshot left for the LP — no hand-entered price.
 *
 * RESUMABLE: skips pool-init and position-mint if already done; records positionTokenIdV2 the
 * instant the position mints (crash-after-mint recoverable).
 *
 * Env: ETH_LIQUIDITY (wei, e.g. 500000000000000000 = 0.5 ETH); optional WORD_LIQUIDITY (default:
 *   the deployer's full WORD-v2 balance = lpPremint), POSITION_TOKEN_ID (recovery).
 * Run: npx hardhat run scripts/v2-02-seed-and-launch.ts --network mainnet
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
];
const POOL_MANAGER_ABI = [
  `function initialize(${POOL_KEY_TUPLE} key, uint160 sqrtPriceX96) returns (int24)`,
  "function extsload(bytes32 slot) view returns (bytes32)",
];
const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
];

const MASK_160 = (1n << 160n) - 1n;
const POOLS_SLOT = "0x0000000000000000000000000000000000000000000000000000000000000006";
const Q96 = 2n ** 96n;

/** Integer square root (Newton's method) for BigInt. */
function isqrt(n: bigint): bigint {
  if (n < 0n) throw new Error("isqrt of negative");
  if (n < 2n) return n;
  let x = n;
  let y = (x + 1n) / 2n;
  while (y < x) {
    x = y;
    y = (x + n / x) / 2n;
  }
  return x;
}

/** sqrtPriceX96 for currency0=ETH (amount0), currency1=WORD (amount1): sqrt(amount1/amount0)*2^96. */
function sqrtPriceX96For(amount0: bigint, amount1: bigint): bigint {
  // (sqrtP)^2 = (amount1/amount0) * 2^192  →  sqrtP = isqrt(amount1 * 2^192 / amount0)
  return isqrt((amount1 * (Q96 * Q96)) / amount0);
}

async function poolInitialized(poolManager: Contract, key: any): Promise<boolean> {
  const poolId = ethers.keccak256(coder.encode([POOL_KEY_TUPLE], [key]));
  const stateSlot = ethers.keccak256(ethers.concat([poolId, POOLS_SLOT]));
  const slot0 = await poolManager.extsload(stateSlot);
  return (BigInt(slot0) & MASK_160) !== 0n;
}

async function main() {
  const {signer, provider} = getDeploySigner(network);
  const a = loadAddresses(network.name);
  const admin = a.admin as string;
  if (!a.wordTokenV2 || !a.feeHookV2) throw new Error("run v2-01-deploy.ts first (missing wordTokenV2/feeHookV2)");

  const ethLiquidity = BigInt(env("ETH_LIQUIDITY"));
  const wordToken = new ethers.Contract(a.wordTokenV2, ERC20_ABI, signer);
  const deployerBal: bigint = await wordToken.balanceOf(await signer.getAddress());
  const wordLiquidity = BigInt(env("WORD_LIQUIDITY", deployerBal.toString()));
  if (wordLiquidity > deployerBal) {
    throw new Error(`WORD_LIQUIDITY ${wordLiquidity} exceeds deployer balance ${deployerBal}`);
  }
  const positionOverride = process.env.POSITION_TOKEN_ID?.trim();

  const poolManager = new ethers.Contract(a.poolManager, POOL_MANAGER_ABI, signer);
  const posm = new ethers.Contract(a.positionManager, POSM_ABI, signer);
  const permit2 = new ethers.Contract(PERMIT2, PERMIT2_ABI, signer);

  const key = {
    currency0: ethers.ZeroAddress, // native ETH sorts first
    currency1: a.wordTokenV2,
    fee: a.lpFee,
    tickSpacing: a.tickSpacing,
    hooks: a.feeHookV2,
  };

  const sqrtPriceX96 = sqrtPriceX96For(ethLiquidity, wordLiquidity);
  console.log(`seed ${ethers.formatEther(ethLiquidity)} ETH + ${ethers.formatEther(wordLiquidity)} WORD`);
  console.log(`launch price sqrtPriceX96 = ${sqrtPriceX96} (~${Number(wordLiquidity) / Number(ethLiquidity)} WORD/ETH)`);

  const tickUpper = Math.floor(887272 / a.tickSpacing) * a.tickSpacing;
  const tickLower = -tickUpper;
  const liquidity = liquidityForAmounts(
    sqrtPriceX96,
    sqrtPriceAtTick(tickLower),
    sqrtPriceAtTick(tickUpper),
    ethLiquidity,
    wordLiquidity,
  );
  if (liquidity === 0n) throw new Error("computed liquidity is 0 — supply more ETH/WORD");
  console.log(`full range [${tickLower}, ${tickUpper}], liquidity ${liquidity}`);

  // 1. Approvals: WORD → Permit2 → PositionManager (idempotent).
  if ((await wordToken.allowance(admin, PERMIT2)) < wordLiquidity) {
    await (await wordToken.approve(PERMIT2, ethers.MaxUint256)).wait();
  }
  const [p2amount, p2exp] = await permit2.allowance(admin, a.wordTokenV2, a.positionManager);
  const nowTs = BigInt((await provider.getBlock("latest"))!.timestamp);
  if (!(BigInt(p2amount) >= wordLiquidity && BigInt(p2exp) > nowTs)) {
    await (await permit2.approve(a.wordTokenV2, a.positionManager, MASK_160, (1n << 48n) - 1n)).wait();
  }

  // 2. Initialize the pool (swaps gated until enableTrading — no snipe window).
  if (await poolInitialized(poolManager, key)) {
    console.log("pool already initialized — skip");
  } else {
    console.log("initializing pool…");
    await (await poolManager.initialize(key, sqrtPriceX96)).wait();
  }

  // 3. Mint the full-range position to the admin (UNlocked — UNCX lock is a separate manual step).
  let tokenId: bigint;
  if (positionOverride) {
    tokenId = BigInt(positionOverride);
    saveAddresses(network.name, {positionTokenIdV2: tokenId.toString()});
    console.log(`using POSITION_TOKEN_ID override ${tokenId}`);
  } else if (a.positionTokenIdV2) {
    tokenId = BigInt(a.positionTokenIdV2);
    console.log(`resuming recorded positionTokenIdV2 ${tokenId} — skip mint`);
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
    console.log("minting position…");
    await (await posm.modifyLiquidities(unlockData, nowTs + 1800n, {value: ethLiquidity})).wait();
    tokenId = (await posm.nextTokenId()) - 1n;
    saveAddresses(network.name, {positionTokenIdV2: tokenId.toString()});
    console.log(`position tokenId ${tokenId} (recorded)`);
  }

  console.log("");
  console.log("v2 Phase 2 complete — pool SEEDED. Trading is OFF; the position is UNlocked in the admin wallet.");
  console.log(`  position tokenId ${tokenId}`);
  console.log("REMAINING MANUAL STEPS:");
  console.log("  • Lock the LP on UNCX (https://app.uncx.network) — connect the admin wallet, pick the");
  console.log(`    V4 position #${tokenId}, choose a lock duration, approve + lock. (NOT the in-house LPLocker.)`);
  console.log("  • npx hardhat run scripts/v2-03-enable-trading.ts --network mainnet  — flip trading live");
  console.log("Do NOT announce the pool until AFTER enable-trading (gated swaps look like a honeypot).");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
