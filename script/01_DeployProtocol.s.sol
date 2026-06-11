// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {BountyEngine} from "../src/BountyEngine.sol";
import {BurnEngine} from "../src/BurnEngine.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {LPLocker} from "../src/LPLocker.sol";
import {Renderer} from "../src/Renderer.sol";
import {RewardsDistributor} from "../src/RewardsDistributor.sol";
import {RoyaltySplitter} from "../src/RoyaltySplitter.sol";
import {WordBank} from "../src/WordBank.sol";
import {WordToken} from "../src/WordToken.sol";
import {IBountyEngine} from "../src/interfaces/IBountyEngine.sol";
import {IBurnEngine} from "../src/interfaces/IBurnEngine.sol";
import {IRewardsDistributor} from "../src/interfaces/IRewardsDistributor.sol";
import {IWordToken} from "../src/interfaces/IWordToken.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title  Phase 1 — deploy and wire the whole protocol (everything except pool seeding)
/// @notice Order matters (see deploy/RUNBOOK.md):
///         WordBank (deploys WordToken) → Renderer → RewardsDistributor → BountyEngine →
///         BurnEngine → FeeHook (CREATE2 at a mined, flag-encoding address) → LPLocker →
///         wiring (renderer, distributor, burner, pool key into the BurnEngine).
///
///         Required env:
///           ADMIN            protocol admin address (also the broadcaster)
///           POOL_MANAGER     canonical Uniswap V4 PoolManager on this chain
///           POSITION_MANAGER canonical Uniswap V4 PositionManager on this chain
///           WETH             canonical WETH9 on this chain (RoyaltySplitter unwraps it);
///                            MUST equal the hardcoded canonical for the chainid (RS-2 guard)
///         Optional env (defaults):
///           LP_FEE          (3000 = 0.30%)
///           TICK_SPACING    (60)
///           WETH_OVERRIDE   (required ONLY on an unknown chainid, e.g. bare local Anvil)
///           WORDBANK_ADDRESS (resume/recovery: reuse an already-live WordBank — its WordToken
///                            is read from wordBank.wordToken() — instead of redeploying)
///
///         The CREATE2 deployer behind `new FeeHook{salt: ...}` in a broadcast forge script
///         is the canonical deterministic deployer (0x4e59…956C), which is what HookMiner
///         mines against.
///
///         RESUMABILITY NOTE: the wiring calls below are idempotent (skipped if already done,
///         read from on-chain getters), and WORDBANK_ADDRESS lets you reuse a live WordBank.
///         But a forge script keeps no addresses ledger, so the OTHER contracts (Renderer,
///         BountyEngine, …) always redeploy on a re-run — use the Hardhat `01-deploy-protocol`
///         (which records each address and skips per-contract) as the primary tool for a
///         partial-failure resume; this mirror covers the WordBank-reuse recovery + wiring.
contract DeployProtocol is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant HOOK_FLAGS = uint160((1 << 7) | (1 << 6) | (1 << 3) | (1 << 2)); // 0x00CC
    uint96 constant LAUNCH_ROYALTY_BPS = 300; // 3% at launch; admin-settable on WordBank (≤ 1000)

    struct Deployment {
        address admin;
        IPoolManager poolManager;
        address positionManager;
        address weth;
        uint24 lpFee;
        int24 tickSpacing;
        WordBank wordBank;
        WordToken wordToken;
        Renderer renderer;
        BountyEngine bountyEngine;
        RewardsDistributor rewardsDistributor;
        BurnEngine burnEngine;
        FeeHook feeHook;
        bytes32 hookSalt;
        LPLocker lpLocker;
        RoyaltySplitter royaltySplitter;
        address wordbankOverride;
    }

    function run() external {
        Deployment memory d;
        d.admin = vm.envAddress("ADMIN");
        d.poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        d.positionManager = vm.envAddress("POSITION_MANAGER");
        // RS-2 (SYS-3): the RoyaltySplitter's `weth` has no on-chain validation beyond
        // non-zero, and a wrong WETH breaks the trustless WETH split. Resolve it to the chain's
        // canonical WETH9 and require the configured WETH env to match — so a wrong WETH can
        // never ship on a known chain.
        d.weth = _resolveCanonicalWeth();
        d.lpFee = uint24(vm.envOr("LP_FEE", uint256(3000)));
        d.tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        d.wordbankOverride = vm.envOr("WORDBANK_ADDRESS", address(0));

        vm.startBroadcast();

        // 1. WordBank — its constructor deploys WordToken with msg.sender = the bank. With
        //    WORDBANK_ADDRESS set, reuse the already-live WordBank (recovery) instead of
        //    redeploying; WordToken is read from it either way.
        if (d.wordbankOverride != address(0)) {
            d.wordBank = WordBank(d.wordbankOverride);
            console2.log("WordBank: reused via WORDBANK_ADDRESS", address(d.wordBank));
        } else {
            d.wordBank = new WordBank(d.admin);
        }
        d.wordToken = WordToken(address(d.wordBank.wordToken()));

        // 2. Renderer (content upload is a separate agent-2 tooling step — see runbook).
        d.renderer = new Renderer();

        // 3. Game-side fee consumers.
        d.bountyEngine = new BountyEngine(address(d.wordBank), d.admin);
        d.rewardsDistributor = new RewardsDistributor(address(d.wordBank), address(d.bountyEngine));

        // 4. BurnEngine (needs no pool key yet — wired post-pool-creation in phase 2).
        d.burnEngine = new BurnEngine(
            d.poolManager, IWordToken(address(d.wordToken)), IRewardsDistributor(address(d.rewardsDistributor)), d.admin
        );

        // 5. FeeHook at a mined address that encodes exactly the four permission flags.
        d.feeHook = _deployHook(d);

        // 6. LPLocker.
        d.lpLocker = new LPLocker(IPositionManager(d.positionManager), d.admin);

        // 7. RoyaltySplitter — trustless ERC-2981 receiver (needs BurnEngine + BountyEngine).
        d.royaltySplitter = new RoyaltySplitter(address(d.burnEngine), address(d.bountyEngine), d.admin, d.weth);

        // 8. One-time wiring (all admin-gated). Each call is skipped if already done (read the
        //    on-chain getter) so a resume — including the WORDBANK_ADDRESS recovery — is
        //    idempotent. setRoyalty points WordBank's ERC-2981 receiver at the splitter at 3%.
        if (address(d.wordBank.renderer()) == address(0)) {
            d.wordBank.setRenderer(address(d.renderer));
        } else {
            console2.log("setRenderer: already done - skip");
        }
        if (address(d.wordBank.rewardsDistributor()) == address(0)) {
            d.wordBank.setRewardsDistributor(address(d.rewardsDistributor));
        } else {
            console2.log("setRewardsDistributor: already done - skip");
        }
        if (d.wordToken.burner() == address(0)) {
            d.wordToken.setBurner(address(d.burnEngine));
        } else {
            console2.log("setBurner: already done - skip");
        }
        (address royaltyReceiver,) = d.wordBank.royaltyInfo(0, 1_000_000);
        if (royaltyReceiver != address(d.royaltySplitter)) {
            d.wordBank.setRoyalty(address(d.royaltySplitter), LAUNCH_ROYALTY_BPS);
        } else {
            console2.log("setRoyalty: already done - skip");
        }

        vm.stopBroadcast();

        // RS-2 post-deploy assertion: the live splitter's WETH must be the canonical WETH9 we
        // resolved for this chainid. Belt-and-suspenders over the constructor arg.
        require(address(d.royaltySplitter.weth()) == d.weth, "RS-2: royaltySplitter.weth() != canonical WETH9");

        _log(d);
    }

    /// @dev Canonical WETH9 per chain (RS-2 / SYS-3). Sourced from the official WETH/Uniswap
    ///      deployments, same discipline as the V4 PoolManager/PositionManager addresses. On a
    ///      KNOWN chain the configured `WETH` env MUST equal the hardcoded canonical (a wrong
    ///      WETH can never silently ship). On an UNKNOWN chainid (e.g. a bare local Anvil) an
    ///      explicit `WETH_OVERRIDE` opt-in is required. A mainnet-fork Anvil keeps chainid 1,
    ///      so it takes the mainnet path and needs no override.
    function _resolveCanonicalWeth() internal view returns (address) {
        uint256 id = block.chainid;
        if (id == 1) return _requireConfiguredWeth(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, "mainnet (1)");
        if (id == 11155111) {
            return _requireConfiguredWeth(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14, "Sepolia (11155111)");
        }
        // Unknown chainid: never silently wrong — require an explicit opt-in override.
        address ovr = vm.envOr("WETH_OVERRIDE", address(0));
        require(ovr != address(0), "RS-2: unknown chainid - set WETH_OVERRIDE to this chain's WETH9 (bare-anvil only)");
        return ovr;
    }

    /// @dev Requires the operator-configured `WETH` env to equal the canonical for this chain.
    function _requireConfiguredWeth(address canonical, string memory chainName) internal view returns (address) {
        address configured = vm.envAddress("WETH");
        require(configured == canonical, string.concat("RS-2: WETH env != canonical WETH9 for ", chainName));
        return canonical;
    }

    function _deployHook(Deployment memory d) internal returns (FeeHook feeHook) {
        bytes memory hookArgs = abi.encode(
            d.poolManager,
            address(d.wordToken),
            d.lpFee,
            d.tickSpacing,
            IRewardsDistributor(address(d.rewardsDistributor)),
            IBountyEngine(address(d.bountyEngine)),
            IBurnEngine(address(d.burnEngine)),
            d.admin
        );
        (address minedHook, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(FeeHook).creationCode, hookArgs);
        d.hookSalt = salt;
        feeHook = new FeeHook{salt: salt}(
            d.poolManager,
            address(d.wordToken),
            d.lpFee,
            d.tickSpacing,
            IRewardsDistributor(address(d.rewardsDistributor)),
            IBountyEngine(address(d.bountyEngine)),
            IBurnEngine(address(d.burnEngine)),
            d.admin
        );
        require(address(feeHook) == minedHook, "hook address mismatch");
    }

    function _log(Deployment memory d) internal view {
        console2.log("WordBank:          ", address(d.wordBank));
        console2.log("WordToken:         ", address(d.wordToken));
        console2.log("Renderer:          ", address(d.renderer));
        console2.log("RewardsDistributor:", address(d.rewardsDistributor));
        console2.log("BountyEngine:      ", address(d.bountyEngine));
        console2.log("BurnEngine:        ", address(d.burnEngine));
        console2.log("FeeHook:           ", address(d.feeHook));
        console2.log("  salt:            ", vm.toString(d.hookSalt));
        console2.log("LPLocker:          ", address(d.lpLocker));
        console2.log("RoyaltySplitter:   ", address(d.royaltySplitter));
        console2.log("  royalty bps set:  300 (WordBank ERC-2981 receiver = RoyaltySplitter)");
        console2.log("  verified WETH9:   ", address(d.royaltySplitter.weth()));
        console2.log("NEXT: agent-2 renderer content upload, sale config, then 02_SeedPoolAndLaunch");
    }
}
