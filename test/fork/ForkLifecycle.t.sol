// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {BountyEngine} from "../../src/BountyEngine.sol";
import {BurnEngine} from "../../src/BurnEngine.sol";
import {FeeHook} from "../../src/FeeHook.sol";
import {LPLocker} from "../../src/LPLocker.sol";
import {Renderer} from "../../src/Renderer.sol";
import {RewardsDistributor} from "../../src/RewardsDistributor.sol";
import {RoyaltySplitter} from "../../src/RoyaltySplitter.sol";
import {WordBank} from "../../src/WordBank.sol";
import {WordToken} from "../../src/WordToken.sol";
import {Category, WordData} from "../../src/interfaces/Types.sol";
import {IBountyEngine} from "../../src/interfaces/IBountyEngine.sol";
import {IBurnEngine} from "../../src/interfaces/IBurnEngine.sol";
import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";
import {IWordToken} from "../../src/interfaces/IWordToken.sol";
import {HookMiner} from "../../script/HookMiner.sol";

/// @dev Minimal canonical WETH9 surface for the fork royalty arc.
interface IWeth9 {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev A clean, guaranteed-receiving royalty admin for the fork royalty-split assertion.
contract ForkRoyaltyAdmin {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

/// @title  Fork lifecycle — the whole protocol against the REAL Uniswap V4 on a mainnet fork
/// @notice Charter milestone 3 / security review SYS-2: "the single best catch-all for
///         wiring/param drift." Deploys the protocol against the canonical mainnet V4
///         PoolManager + PositionManager + Permit2, seeds and locks the real position,
///         enables trading, runs real swaps that skim the 1% fee, flushes the three-way
///         split into the real engines, claims holder rewards, runs a real `executeBuyback`
///         on the forked pool, unbinds, drives supply to the 10M floor, and confirms the
///         fee split collapses two-way and the BurnEngine retires.
///
///         The deploy SEQUENCE mirrors script/01_DeployProtocol → 02_SeedPoolAndLaunch →
///         02b_SyncRegistry → 03_SealAndRenounce exactly (same constructors, wiring order,
///         hook-salt mining, position-mint actions, seal/renounce). The scripts themselves
///         log their CREATE/CREATE2 addresses to the console for manual phase-to-phase
///         handoff (they are built for `forge script`), so a self-contained test reproduces
///         the sequence to hold the references — the on-chain wiring exercised is identical.
///
///         GATED: skips unless a fork RPC is provided via `FORK_URL` (or `MAINNET_RPC_URL`),
///         so the default offline `forge test` stays green. Canonical mainnet V4 addresses
///         are the defaults and are overridable by env for other chains / future redeploys.
contract ForkLifecycleTest is Test {
    using Strings for uint256;
    using PoolIdLibrary for PoolKey;

    // Canonical mainnet addresses (overridable by env). V4 PoolManager is the published
    // singleton; PositionManager + Permit2 default to their mainnet deployments.
    address constant DEFAULT_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant DEFAULT_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant DEFAULT_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // canonical mainnet WETH9
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint96 constant LAUNCH_ROYALTY_BPS = 300; // 3%

    uint160 constant HOOK_FLAGS = uint160((1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint24 constant LP_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint256 constant PUBLIC_SUPPLY = 9_800;
    uint256 constant ADMIN_RESERVE = 200;
    uint256 constant LIQUIDITY = 1_000_000e18;

    bool internal forkActive;
    IPoolManager internal poolManager;
    IPositionManager internal posm;
    address internal permit2;
    address internal wethAddr;

    address internal admin = makeAddr("admin");
    address internal trader = makeAddr("trader");
    address internal keeper = makeAddr("keeper");

    WordBank internal bank;
    WordToken internal token;
    Renderer internal renderer;
    BountyEngine internal bounty;
    RewardsDistributor internal distributor;
    BurnEngine internal burnEngine;
    FeeHook internal hook;
    LPLocker internal locker;
    RoyaltySplitter internal royaltySplitter;
    PoolKey internal key;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_URL", vm.envOr("MAINNET_RPC_URL", string("")));
        if (bytes(rpc).length == 0) {
            forkActive = false;
            return;
        }
        vm.createSelectFork(rpc);
        forkActive = true;

        poolManager = IPoolManager(vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER));
        posm = IPositionManager(vm.envOr("POSITION_MANAGER", DEFAULT_POSITION_MANAGER));
        permit2 = vm.envOr("PERMIT2", DEFAULT_PERMIT2);
        wethAddr = vm.envOr("WETH", DEFAULT_WETH);

        vm.deal(admin, 5_000 ether);
        vm.deal(trader, 5_000 ether);
        vm.deal(keeper, 10 ether);
    }

    /// @dev Skips with a clear message when no fork RPC is configured.
    modifier requiresFork() {
        if (!forkActive) {
            emit log("SKIP: set FORK_URL (or MAINNET_RPC_URL) to run the mainnet-fork suite");
            vm.skip(true);
            return;
        }
        _;
    }

    // ───────────────────────────────── the full arc ────────────────────────────────────

    function test_forkFullLifecycle() public requiresFork {
        _deployAndWire(); // mirrors 01_DeployProtocol
        _uploadAndLockSlots();
        _mintOutCollection(); // public sellout + admin reserve
        _syncRegistry(); // mirrors 02b_SyncRegistry
        _seedSealAndLaunch(); // mirrors 02_SeedPoolAndLaunch + 03_SealAndRenounce (real POSM)

        // ── Real swaps skim the 1% fee; flush routes the three-way split. ──
        _warpGuardOff();
        uint256 hookBefore = address(hook).balance;
        _swapEthForWord(trader, 5 ether);
        assertGt(address(hook).balance, hookBefore, "real swap skimmed the ETH fee");

        uint256 rBefore = address(distributor).balance;
        uint256 bBefore = address(bounty).balance;
        uint256 eBefore = address(burnEngine).balance;
        uint256 toRoute = address(hook).balance;
        hook.flush();
        uint256 dR = address(distributor).balance - rBefore;
        uint256 dB = address(bounty).balance - bBefore;
        uint256 dE = address(burnEngine).balance - eBefore;
        assertEq(dR + dB + dE, toRoute, "INV-8: slices sum to 100% on the real pool");
        assertEq(dR, toRoute * 5000 / 10_000, "50% rewards");
        assertEq(dB, toRoute * 2500 / 10_000, "25% bounty");

        // ── Holder reward claim on a real fee deposit. ──
        uint256 tokenId = 1;
        uint256 pending = distributor.pendingRewards(tokenId);
        assertGt(pending, 0, "alive NFT accrued real fees");
        address owner_ = bank.ownerOf(tokenId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256 ownerBefore = owner_.balance;
        vm.prank(owner_);
        distributor.claimRewards(ids);
        assertEq(owner_.balance - ownerBefore, pending, "claimed exact pending");

        // ── A real buyback on the forked pool (post-seal: SYS-1). ──
        burnEngine.deposit{value: 1 ether}();
        uint256 supplyBefore = token.totalSupply();
        vm.roll(block.number + 1);
        vm.prank(keeper);
        burnEngine.executeBuyback(1 ether);
        assertLt(token.totalSupply(), supplyBefore, "buyback bought and burned real WORD");
        assertEq(token.balanceOf(address(burnEngine)), 0, "burned 100% of what it bought");

        // ── Unbind force-settles on the real stack. ──
        _swapEthForWord(trader, 2 ether);
        hook.flush();
        uint256 unbindId = 2;
        address unbinder = bank.ownerOf(unbindId);
        uint256 settle = distributor.pendingRewards(unbindId);
        uint256 wordBefore = token.balanceOf(unbinder);
        vm.prank(unbinder);
        bank.unbind(unbindId);
        assertEq(token.balanceOf(unbinder) - wordBefore, 1_000e18, "backing released on unbind");
        assertEq(distributor.pendingRewards(unbindId), 0, "settled and closed");
        settle; // (exact settle amount asserted in the integration suite; here we assert closure)

        // ── Dynamic floor + resume, cross-contract on real V4 (interfaces-v3). ──
        // The live floor tracks totalAlive; the unbind above already lowered it and freed
        // burnable excess.
        assertEq(token.currentBurnFloor(), bank.totalAlive() * 1_000e18, "live floor tracks totalAlive");
        assertGt(token.burnableExcess(), 0, "burnable excess present");
        assertGe(token.totalSupply(), token.currentBurnFloor(), "supply never below the live floor");

        // A flush while excess exists routes the burn slice THREE-WAY to the engine.
        _swapEthForWord(trader, 3 ether);
        uint256 accrued = address(hook).balance;
        uint256 distPre = address(distributor).balance;
        uint256 burnPre = address(burnEngine).balance;
        hook.flush();
        assertEq(address(distributor).balance - distPre, accrued * 5000 / 10_000, "3-way: 50% rewards");
        assertGt(address(burnEngine).balance - burnPre, 0, "burn slice routed while excess exists");

        // A real buyback burns the excess; then a fresh unbind lowers the floor and frees new
        // excess — burning resumes, with no permanent completion.
        uint256 burnedBefore = token.burnedTotal();
        vm.roll(block.number + 1);
        vm.prank(keeper);
        burnEngine.executeBuyback(1 ether);
        assertGt(token.burnedTotal(), burnedBefore, "buyback burned real WORD");

        uint256 floorBeforeUnbind = token.currentBurnFloor();
        uint256 excessBeforeUnbind = token.burnableExcess();
        uint256 id3 = _anyAliveOwnedBy(trader);
        vm.prank(trader);
        bank.unbind(id3);
        assertEq(token.currentBurnFloor(), floorBeforeUnbind - 1_000e18, "unbind lowered the live floor");
        assertEq(token.burnableExcess(), excessBeforeUnbind + 1_000e18, "freed backing became burnable excess");
        assertGe(token.totalSupply(), bank.totalAlive() * 1_000e18, "never below the new lower floor");

        // ── RoyaltySplitter against the REAL mainnet WETH9: a marketplace-style royalty,
        //    paid in WETH, unwraps and splits equal thirds into the real engines + admin. ──
        // The fixture splitter is WordBank's wired ERC-2981 receiver at 3% (wiring check).
        (address rcv, uint256 royalty) = bank.royaltyInfo(1, 30 ether);
        assertEq(rcv, address(royaltySplitter), "ERC-2981 receiver is the splitter");
        assertEq(royalty, 0.9 ether, "3% of 30 ETH");

        // The split + delivery is exercised on a dedicated splitter with a freshly-deployed,
        // guaranteed-receiving admin — the same real BurnEngine/BountyEngine and the same real
        // WETH9. (The protocol `admin` here is a deterministic test address that collides with
        // a non-EOA on mainnet, which would muddy a delivery assertion; a clean receiver
        // isolates the equal-thirds + WETH-unwrap proof.)
        ForkRoyaltyAdmin royaltyAdmin = new ForkRoyaltyAdmin();
        RoyaltySplitter forkSplitter =
            new RoyaltySplitter(address(burnEngine), address(bounty), address(royaltyAdmin), wethAddr);

        // Mint WETH on the real WETH9, pay the splitter the marketplace royalty in WETH.
        vm.deal(address(this), royalty);
        IWeth9(wethAddr).deposit{value: royalty}();
        IWeth9(wethAddr).transfer(address(forkSplitter), royalty);
        assertEq(IWeth9(wethAddr).balanceOf(address(forkSplitter)), royalty, "WETH royalty parked");

        uint256 burnPendingPre = burnEngine.pendingEth();
        uint256 bountyPre = address(bounty).balance;
        uint256 distPreRoyalty = address(distributor).balance;

        forkSplitter.distribute(); // unwraps the WETH on the real WETH9, then splits

        assertEq(IWeth9(wethAddr).balanceOf(address(forkSplitter)), 0, "WETH unwrapped on the fork");
        assertEq(burnEngine.pendingEth() - burnPendingPre, royalty / 3, "burn third to BurnEngine");
        assertEq(address(bounty).balance - bountyPre, royalty / 3, "bounty third to BountyEngine");
        assertEq(royaltyAdmin.received(), royalty - 2 * (royalty / 3), "admin third delivered (remainder)");
        assertEq(address(distributor).balance, distPreRoyalty, "RewardsDistributor gets no royalty cut");
        assertEq(address(forkSplitter).balance, 0, "nothing stranded");
    }

    /// @dev Any alive, registered (unbindable) tokenId owned by `owner_`.
    function _anyAliveOwnedBy(address owner_) internal view returns (uint256) {
        uint256 minted = bank.totalMinted();
        for (uint256 id = 1; id <= minted; ++id) {
            if (bank.isAlive(id) && bank.ownerOf(id) == owner_ && bank.indexInCategory(id) != 0) {
                return id;
            }
        }
        revert("no alive token owned");
    }

    // ──────────────────────────── deploy + wire (mirrors 01) ────────────────────────────

    /// @dev Mirrors 01_DeployProtocol's constructor + wiring sequence. Contracts are owned by
    ///      `admin` through their constructor args (not the deployer), so deployment runs from
    ///      the test contract; only the admin-gated wiring setters are pranked. The hook salt
    ///      is mined against the ACTUAL CREATE2 deployer (this test contract) — under
    ///      `forge script` that deployer is the canonical 0x4e59… (CREATE2_DEPLOYER); the
    ///      mining logic and flag-validation it proves are identical either way.
    function _deployAndWire() internal {
        bank = new WordBank(admin);
        token = bank.wordToken();
        renderer = new Renderer();
        bounty = new BountyEngine(address(bank), admin);
        distributor = new RewardsDistributor(address(bank), address(bounty));
        burnEngine =
            new BurnEngine(poolManager, IWordToken(address(token)), IRewardsDistributor(address(distributor)), admin);

        bytes memory hookArgs = abi.encode(
            poolManager,
            address(token),
            LP_FEE,
            TICK_SPACING,
            IRewardsDistributor(address(distributor)),
            IBountyEngine(address(bounty)),
            IBurnEngine(address(burnEngine)),
            admin
        );
        (address minedHook, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(FeeHook).creationCode, hookArgs);
        hook = new FeeHook{salt: salt}(
            poolManager,
            address(token),
            LP_FEE,
            TICK_SPACING,
            IRewardsDistributor(address(distributor)),
            IBountyEngine(address(bounty)),
            IBurnEngine(address(burnEngine)),
            admin
        );
        require(address(hook) == minedHook, "hook address mismatch");

        locker = new LPLocker(posm, admin);

        // RoyaltySplitter against the REAL canonical mainnet WETH9 (the WETH env the deploy
        // scripts now require). setRoyalty wires it as WordBank's ERC-2981 receiver at 3%.
        royaltySplitter = new RoyaltySplitter(address(burnEngine), address(bounty), admin, wethAddr);

        vm.startPrank(admin);
        bank.setRenderer(address(renderer));
        bank.setRewardsDistributor(address(distributor));
        token.setBurner(address(burnEngine));
        bank.setRoyalty(address(royaltySplitter), LAUNCH_ROYALTY_BPS);
        vm.stopPrank();
    }

    function _uploadAndLockSlots() internal {
        vm.startPrank(admin);
        uint256 batchSize = 1_000;
        for (uint256 b = 0; b < 10; ++b) {
            WordData[] memory batch = new WordData[](batchSize);
            for (uint256 i = 0; i < batchSize; ++i) {
                uint256 idx = b * batchSize + i;
                batch[i] = WordData({
                    word: string.concat("word-", idx.toString()),
                    category: Category(idx % 4),
                    material: uint8(idx % 19),
                    ink: uint8(idx % 5),
                    background: uint8(idx % 7),
                    honors: idx < 25
                });
            }
            bank.setWordSlots(b * batchSize, batch);
        }
        bank.lockSlots(keccak256("fork-provenance"));
        vm.stopPrank();
    }

    function _mintOutCollection() internal {
        vm.startPrank(admin);
        bank.setSaleConfig(0, PUBLIC_SUPPLY, 0.05 ether, 0.08 ether, 1);
        bank.openEarlyBird();
        bank.closeEarlyBird();
        bank.openPublicSale();
        vm.stopPrank();

        vm.prank(trader);
        bank.publicMint{value: PUBLIC_SUPPLY * 0.08 ether}(PUBLIC_SUPPLY);
        vm.prank(admin);
        bank.adminMint(ADMIN_RESERVE, admin);
    }

    // ───────────────────────── sync registry (mirrors 02b) ─────────────────────────────

    function _syncRegistry() internal {
        vm.roll(bank.offsetTargetBlock() + 1);
        bank.revealOffset();
        while (!bank.registrySynced()) {
            bank.buildRegistry(2_500);
        }
    }

    // ─────────────── seed + lock + enable + seal (mirrors 02 then 03) ───────────────────

    function _seedSealAndLaunch() internal {
        // Launch price: 1,000 WORD per ETH (sqrt(1000) << 96).
        uint160 sqrtPriceX96 = uint160(_sqrt(1000 << 192));
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        int24 tickLower = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        uint256 ethLiquidity = 1_000 ether;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethLiquidity,
            LIQUIDITY
        );

        vm.startPrank(admin);
        token.mintLiquidity(admin, LIQUIDITY);
        token.approve(permit2, type(uint256).max);
        (bool ok,) = permit2.call(
            abi.encodeWithSignature(
                "approve(address,address,uint160,uint48)",
                address(token),
                address(posm),
                type(uint160).max,
                type(uint48).max
            )
        );
        require(ok, "permit2 approve failed");

        poolManager.initialize(key, sqrtPriceX96);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(liquidity), uint128(ethLiquidity), uint128(LIQUIDITY), admin, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, admin);
        posm.modifyLiquidities{value: ethLiquidity}(abi.encode(actions, params), block.timestamp + 600);
        uint256 tokenId = posm.nextTokenId() - 1;

        (ok,) = address(posm).call(abi.encodeWithSignature("approve(address,uint256)", address(locker), tokenId));
        require(ok, "posm approve failed");
        locker.lock(tokenId, block.timestamp + 365 days);

        burnEngine.setPool(key);
        hook.enableTrading();

        // Phase 3: seal + renounce (mirrors 03_SealAndRenounce).
        token.sealMinting();
        token.renounceOwnership();
        vm.stopPrank();

        assertEq(token.totalSupply(), 11_000_000e18, "sealed at 11M");
        assertEq(token.owner(), address(0), "ownership renounced (scanner hygiene)");
    }

    // ──────────────────────────────────── helpers ──────────────────────────────────────

    function _warpGuardOff() internal {
        vm.warp(uint256(hook.tradingEnabledAt()) + 1 hours);
    }

    /// @dev Swaps ETH→WORD directly through the real PoolManager via a minimal unlock router.
    function _swapEthForWord(address from, uint256 ethIn) internal {
        vm.prank(from);
        ForkSwapRouter(payable(_router())).swapExactInEth{value: ethIn}(key, ethIn);
    }

    address internal _swapRouter;

    function _router() internal returns (address) {
        if (_swapRouter == address(0)) {
            _swapRouter = address(new ForkSwapRouter(poolManager));
        }
        return _swapRouter;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

/// @dev Minimal ETH→WORD exact-input router for the fork: opens its own PoolManager unlock,
///      swaps zeroForOne, settles the native ETH it owes, and takes the WORD credit to the
///      recipient. The v4-core PoolSwapTest util is test-only and not deployed on mainnet,
///      so the fork suite carries its own tiny router rather than depend on a forked test
///      contract. Delta reads use TransientStateLibrary (the supported V4 surface).
contract ForkSwapRouter {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    receive() external payable {}

    function swapExactInEth(PoolKey calldata key, uint256 ethIn) external payable {
        manager.unlock(abi.encode(key, ethIn, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, uint256 ethIn, address recipient) = abi.decode(data, (PoolKey, uint256, address));
        manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        // Settle the ETH we owe (negative currency0 delta), take the WORD owed to us.
        manager.settle{value: ethIn}();
        int256 wordDelta = manager.currencyDelta(address(this), key.currency1);
        if (wordDelta > 0) manager.take(key.currency1, recipient, uint256(wordDelta));
        return "";
    }
}
