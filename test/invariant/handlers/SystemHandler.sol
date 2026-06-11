// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {BountyEngine} from "../../../src/BountyEngine.sol";
import {BurnEngine} from "../../../src/BurnEngine.sol";
import {FeeHook} from "../../../src/FeeHook.sol";
import {RewardsDistributor} from "../../../src/RewardsDistributor.sol";
import {RoyaltySplitter} from "../../../src/RoyaltySplitter.sol";
import {WordBank} from "../../../src/WordBank.sol";
import {WordToken} from "../../../src/WordToken.sol";

/// @dev Minimal WETH surface the handler needs to mint+move WETH-denominated royalties.
interface IWeth {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title  SystemHandler — full-stack invariant driver: pool, fees, game, burn (agent 6)
/// @notice Drives the COMPLETE protocol economy against a real local V4 pool: swaps in both
///         directions (paying the real 1% skim), permissionless flushes (asserting the
///         split sums to 100% on every single flush), the commit→reveal→claim→sweep game
///         cycle with lapses, buy-and-burn buybacks through the real pool, plus unbinds,
///         reward claims, and NFT transfers. Time and blocks advance via dedicated actions.
///
///         Same discipline as CoreHandler: every action is revert-free by construction so
///         the suite runs with fail-on-revert = true.
contract SystemHandler is CommonBase, StdCheats, StdUtils {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant BOND = 0.01 ether;

    WordBank public immutable bank;
    WordToken public immutable token;
    RewardsDistributor public immutable distributor;
    BountyEngine public immutable bounty;
    BurnEngine public immutable burnEngine;
    FeeHook public immutable hook;
    RoyaltySplitter public immutable royaltySplitter;
    PoolSwapTest public immutable swapRouter;

    PoolKey internal poolKey;
    address internal royaltyAdmin; // the splitter's immutable admin (an EOA in this fixture)
    address[] internal _actors;

    // ───────────────────────────────── ghost state ─────────────────────────────────────

    /// @notice Every successfully revealed eventId (for the lockedFunds == Σ remaining check).
    uint256[] public revealedEvents;
    /// @notice ETH the BurnEngine received via flush on a no-burnable-excess flush — must
    ///         stay zero forever (system invariant 8: the burn slice is never routed when
    ///         `burnableExcess() == 0`; it folds into rewards/bounty).
    uint256 public ghostBurnSliceWhileNoExcess;
    /// @notice Tokens unbound, for "stays dead" sampling.
    uint256[] internal _unboundIds;
    /// @dev actor → owned tokenIds, with 1-based index map (mirrors ERC-721 exactly).
    mapping(address => uint256[]) internal _owned;
    mapping(uint256 => uint256) internal _ownedIndex;

    mapping(string => uint256) public calls;

    constructor(
        WordBank bank_,
        RewardsDistributor distributor_,
        BountyEngine bounty_,
        BurnEngine burnEngine_,
        FeeHook hook_,
        RoyaltySplitter royaltySplitter_,
        PoolSwapTest swapRouter_,
        PoolKey memory poolKey_,
        address[] memory actors_
    ) {
        bank = bank_;
        token = bank_.wordToken();
        distributor = distributor_;
        bounty = bounty_;
        burnEngine = burnEngine_;
        hook = hook_;
        royaltySplitter = royaltySplitter_;
        royaltyAdmin = royaltySplitter_.admin();
        swapRouter = swapRouter_;
        poolKey = poolKey_;
        for (uint256 i = 0; i < actors_.length; ++i) {
            _actors.push(actors_[i]);
            vm.deal(actors_[i], 100_000 ether);
        }
        // Build the ownership ghost from chain truth (one-time scan).
        uint256 minted = bank_.totalMinted();
        for (uint256 id = 1; id <= minted; ++id) {
            address owner_ = bank_.ownerOf(id);
            _owned[owner_].push(id);
            _ownedIndex[id] = _owned[owner_].length;
        }
    }

    // ─────────────────────────────── time and blocks ───────────────────────────────────

    /// @notice Advances time 1–36h (cycle gates, claim deadlines) and blocks accordingly.
    function actWarp(uint256 seed) external {
        calls["warp"]++;
        uint256 dt = _bound(seed, 1 hours, 36 hours);
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + dt / 12);
    }

    // ──────────────────────────────────── swaps ────────────────────────────────────────

    function actBuy(uint256 actorSeed, uint256 ethSeed) external {
        calls["buy"]++;
        address actor = _pickActor(actorSeed);
        uint256 ethIn = _bound(ethSeed, 0.05 ether, 5 ether);
        vm.prank(actor);
        swapRouter.swap{value: ethIn}(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function actSell(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _pickActor(actorSeed);
        uint256 balance = token.balanceOf(actor);
        if (balance < 1e18) return;
        calls["sell"]++;
        uint256 wordIn = _bound(amountSeed, 1e18, balance > 20_000e18 ? 20_000e18 : balance);
        vm.startPrank(actor);
        token.approve(address(swapRouter), wordIn);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -int256(wordIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    // ─────────────────────────────────── routing ───────────────────────────────────────

    /// @notice Permissionless flush. Asserts system invariant 8 ON EVERY FLUSH: the slices
    ///         sum to exactly 100% of the routed balance, the routing mode is chosen PER FLUSH
    ///         by live burnable excess (3-way when excess > 0, else 2-way), and the burn slice
    ///         is NEVER routed when there is no burnable excess.
    function actFlush(uint256 actorSeed) external {
        calls["flush"]++;
        uint256 hookBalance = address(hook).balance;
        uint256 excessBefore = token.burnableExcess(); // the mode selector the hook reads
        uint256 rBefore = address(distributor).balance;
        uint256 bBefore = address(bounty).balance;
        uint256 eBefore = address(burnEngine).balance;

        vm.prank(_pickActor(actorSeed));
        hook.flush();

        uint256 dR = address(distributor).balance - rBefore;
        uint256 dB = address(bounty).balance - bBefore;
        uint256 dE = address(burnEngine).balance - eBefore;

        require(dR + dB + dE == hookBalance, "INV-8: slices do not sum to 100% of the skim");
        require(address(hook).balance == 0, "INV-8: hook kept ETH after flush");
        if (excessBefore == 0) {
            // Two-way mode: the burn slice folds into rewards/bounty; the engine gets nothing.
            ghostBurnSliceWhileNoExcess += dE; // must stay 0 — checked as an invariant
        }
    }

    // ────────────────────────────────── royalties ──────────────────────────────────────

    /// @notice Pays a marketplace-style royalty into the RoyaltySplitter (ETH or WETH) and
    ///         distributes it, asserting the equal-thirds split invariant on the spot against
    ///         the REAL BurnEngine/BountyEngine and the EOA admin: toBurn == toBounty,
    ///         |toAdmin − toBurn| ≤ 2, the three sum to exactly the distributed balance, and
    ///         the RewardsDistributor gets nothing. Amount is kept ≥ 3 wei (below that the
    ///         protocol sinks' zero-value guard would revert — see OBS-RS1).
    function actRoyaltyDistribute(uint256 amount, uint256 seed) external {
        amount = _bound(amount, 3, 5 ether);
        calls["royaltyDistribute"]++;
        vm.deal(address(this), amount);
        if (seed % 2 == 0) {
            // WETH-denominated royalty → exercises the unwrap path.
            IWeth(address(royaltySplitter.weth())).deposit{value: amount}();
            IWeth(address(royaltySplitter.weth())).transfer(address(royaltySplitter), amount);
        } else {
            (bool ok,) = address(royaltySplitter).call{value: amount}("");
            require(ok, "fund splitter");
        }

        // What distribute() will split = native (net pendingAdmin) + WETH it will unwrap.
        uint256 wethBal = IWeth(address(royaltySplitter.weth())).balanceOf(address(royaltySplitter));
        uint256 distributable = royaltySplitter.pendingDistribution() + wethBal;
        uint256 burnBefore = burnEngine.pendingEth();
        uint256 bountyBefore = address(bounty).balance;
        uint256 adminBefore = royaltyAdmin.balance;
        uint256 distBefore = address(distributor).balance;

        royaltySplitter.distribute();

        uint256 toBurn = burnEngine.pendingEth() - burnBefore;
        uint256 toBounty = address(bounty).balance - bountyBefore;
        uint256 toAdmin = royaltyAdmin.balance - adminBefore;

        require(toBurn == toBounty, "RS: burn third != bounty third");
        require(toAdmin >= toBurn && toAdmin - toBurn <= 2, "RS: |admin - burn| > 2");
        require(toBurn + toBounty + toAdmin == distributable, "RS: slices != distributable");
        require(address(distributor).balance == distBefore, "RS: RewardsDistributor got a royalty cut");
    }

    // ──────────────────────────────────── game ─────────────────────────────────────────

    /// @notice Keeps the game treasury funded (a real permissionless path — donations).
    function actDonateTreasury(uint256 actorSeed, uint256 seed) external {
        calls["donateTreasury"]++;
        vm.prank(_pickActor(actorSeed));
        bounty.deposit{value: _bound(seed, 0.05 ether, 1 ether)}();
    }

    function actCommit(uint256 actorSeed) external {
        (address pending,,) = bounty.currentCommit();
        if (pending != address(0)) return;
        uint256 last = bounty.lastEventTimestamp();
        if (last != 0 && block.timestamp < last + 24 hours) return;
        address actor = _pickActor(actorSeed);
        if (bank.balanceOf(actor) == 0) return;
        uint256 minTier = 0.1 ether;
        if (bounty.freeTreasury() < minTier + (minTier * 200) / BPS) return;
        calls["commit"]++;
        vm.prank(actor);
        bounty.commit{value: BOND}();
    }

    /// @notice Reveals the pending commit (rolling to the entropy block), or — if the
    ///         blockhash window lapsed under a big warp — expires it. Both real paths.
    function actReveal(uint256 actorSeed) external {
        (address pending, uint64 targetBlock, uint256 eventId) = bounty.currentCommit();
        if (pending == address(0)) return;
        if (block.number > uint256(targetBlock) + 256) {
            calls["expireCommit"]++;
            bounty.expireCommit();
            return;
        }
        if (block.number <= targetBlock) vm.roll(uint256(targetBlock) + 1);
        calls["reveal"]++;
        vm.prank(_pickActor(actorSeed));
        bounty.reveal();
        (,, uint256 deadline,) = _eventCore(eventId);
        if (deadline != 0) revealedEvents.push(eventId); // not an abort
    }

    /// @notice Deliberately lapses the pending commit past the blockhash window.
    function actLapseCommit() external {
        (address pending, uint64 targetBlock,) = bounty.currentCommit();
        if (pending == address(0)) return;
        calls["lapseCommit"]++;
        if (block.number <= uint256(targetBlock) + 256) vm.roll(uint256(targetBlock) + 257);
        bounty.expireCommit();
    }

    function actClaimBounty(uint256 eventSeed, uint256 slotSeed) external {
        uint256 n = revealedEvents.length;
        if (n == 0) return;
        uint256 eventId = revealedEvents[eventSeed % n];
        (uint256[] memory tokenIds,,,) = bounty.eventInfo(eventId);
        uint256 tokenId = tokenIds[slotSeed % tokenIds.length];
        if (!bounty.isClaimable(eventId, tokenId)) return;
        calls["claimBounty"]++;
        address owner_ = bank.ownerOf(tokenId);
        vm.prank(owner_);
        bounty.claim(eventId, tokenId);
    }

    function actSweepEvent(uint256 eventSeed) external {
        uint256 n = revealedEvents.length;
        if (n == 0) return;
        uint256 eventId = revealedEvents[eventSeed % n];
        (,, uint256 deadline, bool swept) = _eventCore(eventId);
        if (deadline == 0 || swept || block.timestamp <= deadline) return;
        calls["sweepEvent"]++;
        bounty.sweep(eventId);
    }

    // ─────────────────────────────────── buyback ───────────────────────────────────────

    /// @notice Permissionless buy-and-burn through the real pool against the DYNAMIC floor.
    ///         Skips cleanly when there is no burnable excess (supply at the live floor) —
    ///         burning resumes automatically after a later unbind. The keeper is a fuzzed
    ///         actor; the per-block rate limit is satisfied by rolling one block.
    function actBuyback(uint256 actorSeed, uint256 spendSeed) external {
        if (token.burnableExcess() == 0) return; // nothing to burn until the next unbind
        if (address(burnEngine).balance == 0) return;
        calls["buyback"]++;
        if (burnEngine.lastBuybackBlock() == block.number) vm.roll(block.number + 1);
        uint256 maxSpend = _bound(spendSeed, 0.1 ether, 1 ether);
        vm.prank(_pickActor(actorSeed));
        try burnEngine.executeBuyback(maxSpend) {}
        catch (bytes memory err) {
            // Tolerate ONLY the benign "nothing actionable this call" reverts (a wei-dust
            // excess that sizes to a zero target, or excess consumed by a same-block race).
            // Every other revert — SlippageExceeded, BurnFloorBreached, etc. — propagates and
            // fails the suite (fail-on-revert discipline; the contract's INT-1 rounding fix
            // means dust no longer stalls the buyback).
            bytes4 sel = bytes4(err);
            if (sel == BurnEngine.NoBurnableExcess.selector || sel == BurnEngine.NothingToBuy.selector) {
                return;
            }
            assembly ("memory-safe") {
                revert(add(err, 0x20), mload(err))
            }
        }
    }

    // ───────────────────────────── NFT / rewards economy ───────────────────────────────

    function actUnbind(uint256 actorSeed, uint256 seed) external {
        address actor = _pickActor(actorSeed);
        uint256 n = _owned[actor].length;
        if (n == 0) return;
        calls["unbind"]++;
        uint256 tokenId = _owned[actor][seed % n];
        vm.prank(actor);
        bank.unbind(tokenId);
        _removeOwned(actor, tokenId);
        _unboundIds.push(tokenId);
    }

    function actClaimRewards(uint256 actorSeed, uint256 seed) external {
        address actor = _pickActor(actorSeed);
        uint256 n = _owned[actor].length;
        if (n == 0) return;
        calls["claimRewards"]++;
        uint256 take = _bound(seed, 1, n > 10 ? 10 : n);
        uint256 start = seed % n;
        uint256[] memory ids = new uint256[](take);
        for (uint256 i = 0; i < take; ++i) {
            ids[i] = _owned[actor][(start + i) % n];
        }
        vm.prank(actor);
        distributor.claimRewards(ids);
    }

    function actTransferNft(uint256 fromSeed, uint256 toSeed, uint256 seed) external {
        address from = _pickActor(fromSeed);
        uint256 n = _owned[from].length;
        if (n == 0) return;
        calls["transferNft"]++;
        address to = _pickActor(toSeed);
        uint256 tokenId = _owned[from][seed % n];
        vm.prank(from);
        bank.transferFrom(from, to, tokenId);
        _removeOwned(from, tokenId);
        _owned[to].push(tokenId);
        _ownedIndex[tokenId] = _owned[to].length;
    }

    // ──────────────────────────────── ghost views ──────────────────────────────────────

    function revealedCount() external view returns (uint256) {
        return revealedEvents.length;
    }

    function unboundCount() external view returns (uint256) {
        return _unboundIds.length;
    }

    function unboundAt(uint256 i) external view returns (uint256) {
        return _unboundIds[i];
    }

    // ─────────────────────────────────── internals ─────────────────────────────────────

    function _pickActor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    function _eventCore(uint256 eventId) internal view returns (uint256[] memory, uint256, uint256, bool) {
        return bounty.eventInfo(eventId);
    }

    function _removeOwned(address from, uint256 tokenId) internal {
        uint256[] storage arr = _owned[from];
        uint256 idxPlusOne = _ownedIndex[tokenId];
        uint256 lastId = arr[arr.length - 1];
        if (lastId != tokenId) {
            arr[idxPlusOne - 1] = lastId;
            _ownedIndex[lastId] = idxPlusOne;
        }
        arr.pop();
        delete _ownedIndex[tokenId];
    }
}
