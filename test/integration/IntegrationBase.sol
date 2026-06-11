// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {WETH} from "solmate/src/tokens/WETH.sol";

import {BountyEngine} from "../../src/BountyEngine.sol";
import {BurnEngine} from "../../src/BurnEngine.sol";
import {FeeHook} from "../../src/FeeHook.sol";
import {Renderer} from "../../src/Renderer.sol";
import {RewardsDistributor} from "../../src/RewardsDistributor.sol";
import {RoyaltySplitter} from "../../src/RoyaltySplitter.sol";
import {WordBank} from "../../src/WordBank.sol";
import {WordToken} from "../../src/WordToken.sol";
import {Category, WordData} from "../../src/interfaces/Types.sol";
import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";
import {IWordToken} from "../../src/interfaces/IWordToken.sol";
import {RendererAssets} from "../utils/RendererAssets.sol";

/// @title  IntegrationBase — full-stack fixture for the scenario suites (agent 6)
/// @notice Deploys the ENTIRE protocol — real WordBank/WordToken/Renderer/RewardsDistributor/
///         BountyEngine/BurnEngine/FeeHook — against a real local Uniswap V4 PoolManager
///         (v4-core test utilities, the same wiring agent 5's unit suites use), with the
///         real FeeHook placed at a flag-encoded address via deployCodeTo (a deployment
///         mechanism, not a mock: the bytecode is the production contract).
///
///         The fixture is deliberately granular — each scenario composes exactly the launch
///         stages it needs, in runbook order:
///           _deployProtocol() → _mintOutCollection() → _syncRegistry() → _seedPool()
///           → _seal() → trading/guard helpers → swap helpers → _addLaunchTemplates()
///
///         Pool economics mirror agent 5's BurnEngine suite: 1,000 WORD per ETH, ~1,000 ETH
///         / ~1,000,000 WORD of full-range depth, so a 10,000-WORD whale-cap buy is ~1% of
///         depth and the BurnEngine's 0.1–1 ETH spend band sits well inside tolerance.
abstract contract IntegrationBase is Test, Deployers {
    using Strings for uint256;

    // ─────────────────────────────────── constants ─────────────────────────────────────

    uint256 internal constant NUM_CATEGORIES = 4;
    uint256 internal constant MAX_NFT_SUPPLY = 10_000;
    uint256 internal constant PUBLIC_SUPPLY = 9_800;
    uint256 internal constant ADMIN_RESERVE = 200;
    uint256 internal constant BACKING = 1_000e18;
    uint256 internal constant LIQUIDITY_CAP = 1_000_000e18;
    uint256 internal constant EB_PRICE = 0.05 ether;
    uint256 internal constant PUB_PRICE = 0.08 ether;
    uint256 internal constant BOND = 0.01 ether;

    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant LP_FEE = 3000;
    uint160 internal constant HOOK_FLAGS = uint160((1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    // ─────────────────────────────── system under test ─────────────────────────────────

    WordBank internal bank;
    WordToken internal token;
    Renderer internal renderer;
    RewardsDistributor internal distributor;
    BountyEngine internal bounty;
    BurnEngine internal burnEngine;
    FeeHook internal hook;
    RoyaltySplitter internal royaltySplitter;
    WETH internal weth;
    PoolKey internal poolKey;

    uint96 internal constant LAUNCH_ROYALTY_BPS = 300; // 3% (matches deploy script)

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");

    // ────────────────────────────── stage 0: deployment ────────────────────────────────

    /// @dev Deploys and wires the whole protocol in the deploy-script order (01_Deploy-
    ///      Protocol): bank+token → bounty → distributor → burn engine → hook (flag address)
    ///      → wiring. Word slots uploaded and locked. No pool yet.
    function _deployProtocol() internal {
        deployFreshManagerAndRouters();

        bank = new WordBank(admin);
        token = bank.wordToken();
        renderer = new Renderer();
        bounty = new BountyEngine(address(bank), admin);
        distributor = new RewardsDistributor(address(bank), address(bounty));
        burnEngine =
            new BurnEngine(manager, IWordToken(address(token)), IRewardsDistributor(address(distributor)), admin);

        address hookAddr = address(uint160(0x6666 << 144) | HOOK_FLAGS);
        deployCodeTo(
            "FeeHook.sol:FeeHook",
            abi.encode(
                manager,
                address(token),
                LP_FEE,
                TICK_SPACING,
                address(distributor),
                address(bounty),
                address(burnEngine),
                admin
            ),
            hookAddr
        );
        hook = FeeHook(payable(hookAddr));

        // RoyaltySplitter (trustless ERC-2981 receiver) + canonical WETH — deploy-script order
        // (after the engines exist; admin is the EOA here, a reverting-admin variant lives in
        // the griefing scenario). Wired as WordBank's royalty receiver at 3% via setRoyalty.
        weth = new WETH();
        royaltySplitter = new RoyaltySplitter(address(burnEngine), address(bounty), admin, address(weth));

        vm.startPrank(admin);
        bank.setRenderer(address(renderer));
        bank.setRewardsDistributor(address(distributor));
        token.setBurner(address(burnEngine));
        bank.setRoyalty(address(royaltySplitter), LAUNCH_ROYALTY_BPS);
        _uploadAllSlots();
        bank.lockSlots(keccak256("agent6-integration-provenance"));
        vm.stopPrank();

        vm.deal(alice, 5_000 ether);
        vm.deal(bob, 5_000 ether);
        vm.deal(carol, 5_000 ether);
        vm.deal(keeper, 10 ether);
    }

    /// @dev Loads the REAL Renderer content (font + 19 materials + 25 honors) and seals it —
    ///      the launch-ordering precondition for any `tokenURI`/`unrevealedTokenURI` call. Only
    ///      the placeholder/art scenarios need this; the rest of the suite never calls tokenURI,
    ///      so they skip the (expensive) load. The Renderer's admin is this test contract (it
    ///      deployed the Renderer), so no prank is needed.
    function _sealRenderer() internal {
        RendererAssets.loadAll(renderer);
    }

    /// @dev Deterministic slot data identical to the invariant fixture: word-i, category
    ///      i % 4, so every category holds exactly 2,500 of the 10,000 words.
    function _uploadAllSlots() internal {
        uint256 batchSize = 1_000;
        for (uint256 b = 0; b < MAX_NFT_SUPPLY / batchSize; ++b) {
            WordData[] memory batch = new WordData[](batchSize);
            for (uint256 i = 0; i < batchSize; ++i) {
                uint256 idx = b * batchSize + i;
                batch[i] = WordData({
                    word: string.concat("word-", idx.toString()),
                    category: Category(idx % NUM_CATEGORIES),
                    material: uint8(idx % 19),
                    ink: uint8(idx % 5),
                    background: uint8(idx % 7),
                    honors: idx < 25
                });
            }
            bank.setWordSlots(b * batchSize, batch);
        }
    }

    // ─────────────────────────── stage 1: mint the collection ──────────────────────────

    /// @dev Sells out the whole collection: 9,800 public split across alice/bob/carol
    ///      (arming the provenance offset on the last mint) + the 200-token admin reserve.
    function _mintOutCollection() internal {
        vm.startPrank(admin);
        bank.setSaleConfig(0, PUBLIC_SUPPLY, EB_PRICE, PUB_PRICE, 1);
        bank.openEarlyBird();
        bank.closeEarlyBird();
        bank.openPublicSale();
        vm.stopPrank();

        vm.prank(alice);
        bank.publicMint{value: 3_300 * PUB_PRICE}(3_300);
        vm.prank(bob);
        bank.publicMint{value: 3_300 * PUB_PRICE}(3_300);
        vm.prank(carol);
        bank.publicMint{value: 3_200 * PUB_PRICE}(3_200);

        vm.prank(admin);
        bank.adminMint(ADMIN_RESERVE, admin);
    }

    /// @dev Mints the entire collection to ONE owner (edge-case scenarios that unbind at scale).
    function _mintOutCollectionTo(address owner_) internal {
        vm.startPrank(admin);
        bank.setSaleConfig(0, PUBLIC_SUPPLY, EB_PRICE, PUB_PRICE, 1);
        bank.openEarlyBird();
        bank.closeEarlyBird();
        bank.openPublicSale();
        vm.stopPrank();

        vm.deal(owner_, 1_000 ether);
        vm.prank(owner_);
        bank.publicMint{value: PUBLIC_SUPPLY * PUB_PRICE}(PUBLIC_SUPPLY);
        vm.prank(admin);
        bank.adminMint(ADMIN_RESERVE, owner_);
    }

    // ──────────────────────── stage 2: provenance + registry sync ──────────────────────

    /// @dev Reveals the provenance offset and builds the registry to sync (02b script's job).
    function _syncRegistry() internal {
        vm.roll(bank.offsetTargetBlock() + 1);
        bank.revealOffset();
        while (!bank.registrySynced()) {
            bank.buildRegistry(2_500);
        }
    }

    // ───────────────────────────── stage 3: pool + liquidity ───────────────────────────

    /// @dev Seeds the canonical pool at 1,000 WORD/ETH with ~1,000 ETH / ~1M WORD full-range
    ///      depth (the full liquidity allotment), then wires it into the BurnEngine —
    ///      mirroring 02_SeedPoolAndLaunch minus the PositionManager/locker leg (that leg
    ///      runs against the real PositionManager in the fork suite; the local v4-periphery
    ///      pin cannot compile it, per agent 5's script 00 note).
    function _seedPool() internal {
        vm.prank(admin);
        token.mintLiquidity(address(this), LIQUIDITY_CAP);

        uint160 sqrtPrice1000 = uint160(FixedPointMathLib.sqrt(1000 << 192));
        (key,) = initPool(
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(token)),
            IHooks(address(hook)),
            LP_FEE,
            TICK_SPACING,
            sqrtPrice1000
        );
        poolKey = key;

        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        vm.deal(address(this), address(this).balance + 1_100 ether);
        // L = 31,600e18 needs ~999,280 WORD — inside the exact 1,000,000e18 allotment
        // (31,623e18 would need ~1,000,007 and the liquidity cap is hard).
        modifyLiquidityRouter.modifyLiquidity{value: 1_010 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 31_600e18, salt: 0
            }),
            ZERO_BYTES
        );

        vm.prank(admin);
        burnEngine.setPool(key);
    }

    /// @dev Permissionless seal at exactly 11M (phase 3 of the runbook).
    function _seal() internal {
        token.sealMinting();
    }

    // ─────────────────────────────── trading lifecycle ─────────────────────────────────

    function _enableTrading() internal {
        vm.prank(admin);
        hook.enableTrading();
    }

    /// @dev Ends the anti-whale guard the no-admin way: warp past the 1-hour auto-expiry.
    function _expireGuard() internal {
        vm.warp(uint256(hook.tradingEnabledAt()) + 1 hours);
    }

    // ──────────────────────────────── swap helpers ─────────────────────────────────────

    /// @dev Buys WORD with exact ETH input as `actor`.
    function _buyExactIn(address actor, uint256 ethIn) internal returns (BalanceDelta delta) {
        vm.prank(actor);
        delta = swapRouter.swap{value: ethIn}(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev Buys an exact WORD output as `actor`, over-funding the router with `maxEth`.
    function _buyExactOut(address actor, uint256 wordOut, uint256 maxEth) internal returns (BalanceDelta delta) {
        vm.prank(actor);
        delta = swapRouter.swap{value: maxEth}(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: int256(wordOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev Sells exact WORD input as `actor` (approves the router on the way).
    function _sellExactIn(address actor, uint256 wordIn) internal returns (BalanceDelta delta) {
        vm.startPrank(actor);
        token.approve(address(swapRouter), type(uint256).max);
        delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -int256(wordIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        vm.stopPrank();
    }

    // ─────────────────────────────── game-side helpers ─────────────────────────────────

    /// @dev Adds a small launch template menu (admin). Slot mixes chosen so every category
    ///      is drawable and the 7-slot normative maximum is represented.
    function _addLaunchTemplates() internal {
        // "The {ADJ} {NOUN} {VERB}."
        Category[] memory t1 = new Category[](3);
        t1[0] = Category.ADJ;
        t1[1] = Category.NOUN;
        t1[2] = Category.VERB;
        string[] memory f1 = new string[](4);
        f1[0] = "The ";
        f1[1] = " ";
        f1[2] = " ";
        f1[3] = ".";

        // "{NOUN} {ADV} {VERB} the {ADJ} {NOUN} {ADV} {VERB}." — 7 slots (normative max).
        Category[] memory t2 = new Category[](7);
        t2[0] = Category.NOUN;
        t2[1] = Category.ADV;
        t2[2] = Category.VERB;
        t2[3] = Category.ADJ;
        t2[4] = Category.NOUN;
        t2[5] = Category.ADV;
        t2[6] = Category.VERB;
        string[] memory f2 = new string[](8);
        f2[0] = "";
        f2[1] = " ";
        f2[2] = " ";
        f2[3] = " the ";
        f2[4] = " ";
        f2[5] = " ";
        f2[6] = " ";
        f2[7] = ".";

        vm.startPrank(admin);
        bounty.addTemplate(t1, f1);
        bounty.addTemplate(t2, f2);
        vm.stopPrank();
    }

    /// @dev Runs one full commit→reveal cycle as `committer`, returning the eventId.
    ///      Requires a synced registry, a funded treasury, and `committer` holding an NFT.
    function _commitAndReveal(address committer, address revealer) internal returns (uint256 eventId) {
        vm.prank(committer);
        bounty.commit{value: BOND}();
        (, uint64 targetBlock, uint256 id) = bounty.currentCommit();
        eventId = id;
        vm.roll(uint256(targetBlock) + 1);
        vm.prank(revealer);
        bounty.reveal();
    }

    /// @dev First alive tokenId owned by `owner_` (scan; test-only convenience).
    function _firstOwnedToken(address owner_) internal view returns (uint256) {
        uint256 minted = bank.totalMinted();
        for (uint256 id = 1; id <= minted; ++id) {
            if (bank.isAlive(id) && bank.ownerOf(id) == owner_) return id;
        }
        revert("no token owned");
    }

    // NB: Deployers already declares receive() — the fixture can take ETH refunds.
}
