// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {WordBank} from "../../../src/WordBank.sol";
import {WordToken} from "../../../src/WordToken.sol";
import {RewardsDistributor} from "../../../src/RewardsDistributor.sol";

/// @title  CoreHandler — invariant-fuzzing driver for WordToken / WordBank / RewardsDistributor
/// @notice Agent 6 (integration). Drives randomized sequences of every externally reachable
///         action on the core trio. Every action is revert-free by construction — each one
///         checks its own preconditions and no-ops when the action is impossible — so the
///         suites run with `fail-on-revert = true`: any revert that slips through is a real
///         bug in the contracts, never handler noise.
/// @dev    Roles played:
///         - six actor EOAs mint, transfer, claim, unbind, and deposit;
///         - the admin key (pranked) drives sale config, phase transitions, the reserve, and
///           the liquidity allotment;
///         - the handler contract itself is wired as WordToken's set-once `burner`. This
///           stands in for the BurnEngine's burn AUTHORITY only — WordToken's floor /
///           monotonicity / dynamic-floor logic is identical whoever the burner is. The real
///           BurnEngine's buyback mechanics (sizing, slippage, keeper tip) are exercised in
///           the pool-backed full-system and fork suites, not here.
///
///         Ghost state (authoritative because only this handler moves tokens):
///         - per-actor owned tokenId sets (swap-and-pop mirrors of ERC-721 ownership);
///         - the list of unbound (burned) ids, for "stays dead" sampling;
///         - cumulative ETH into / out of the RewardsDistributor, for exact conservation.
contract CoreHandler is CommonBase, StdCheats, StdUtils {
    // ─────────────────────────────────── constants ─────────────────────────────────────

    uint256 internal constant PUBLIC_SUPPLY = 9_800;
    uint256 internal constant ADMIN_RESERVE = 200;
    uint256 internal constant BACKING = 1_000e18;
    uint256 internal constant LIQUIDITY_CAP = 1_000_000e18;
    uint256 internal constant EB_PRICE = 0.05 ether;
    uint256 internal constant PUB_PRICE = 0.08 ether;

    // ──────────────────────────────── system under test ────────────────────────────────

    WordBank public immutable bank;
    WordToken public immutable token;
    RewardsDistributor public immutable distributor;
    address public immutable admin;

    // ──────────────────────────────────── actors ───────────────────────────────────────

    address[] internal _actors;

    // ───────────────────────────────── ghost state ─────────────────────────────────────

    /// @notice Cumulative ETH sent into RewardsDistributor.deposit by this handler.
    uint256 public ghostDistIn;
    /// @notice Cumulative ETH paid out of the distributor (claims, settles, dust sweeps).
    uint256 public ghostDistOut;

    /// @dev Every tokenId ever unbound, in order.
    uint256[] internal _unboundIds;

    /// @dev actor → owned tokenIds (dense), with a 1-based index map for O(1) removal.
    mapping(address => uint256[]) internal _owned;
    mapping(uint256 => uint256) internal _ownedIndex; // tokenId → index+1 in owner's array
    mapping(uint256 => address) internal _ownerOfGhost;

    /// @notice Per-action hit counters, for coverage logging in afterInvariant().
    mapping(string => uint256) public calls;

    // ──────────────────────────────── construction ─────────────────────────────────────

    constructor(WordBank bank_, RewardsDistributor distributor_, address admin_) {
        bank = bank_;
        token = bank_.wordToken();
        distributor = distributor_;
        admin = admin_;
        for (uint256 i = 0; i < 6; ++i) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            _actors.push(actor);
            vm.deal(actor, 1_000_000 ether);
        }
    }

    // ─────────────────────────── steady-state seeding (setUp) ──────────────────────────

    /// @notice Fast-forwards the system to the post-launch steady state: all 10,000 NFTs
    ///         minted across the actors, offset revealed, registry fully built, liquidity
    ///         minted to this handler, minting sealed. Called once from the steady-state
    ///         suite's setUp — never a fuzz target.
    function seedSteadyState() external {
        vm.startPrank(admin);
        bank.setSaleConfig(0, PUBLIC_SUPPLY, EB_PRICE, PUB_PRICE, 1);
        bank.openEarlyBird();
        bank.closeEarlyBird();
        bank.openPublicSale();
        vm.stopPrank();

        uint256 n = _actors.length;
        uint256 minted;
        for (uint256 i = 0; i < n; ++i) {
            uint256 count = (i == n - 1) ? PUBLIC_SUPPLY - minted : PUBLIC_SUPPLY / n;
            vm.prank(_actors[i]);
            bank.publicMint{value: count * PUB_PRICE}(count);
            _recordMint(_actors[i], count);
            minted += count;
        }

        uint256 mintedReserve;
        for (uint256 i = 0; i < n; ++i) {
            uint256 count = (i == n - 1) ? ADMIN_RESERVE - mintedReserve : ADMIN_RESERVE / n;
            vm.prank(admin);
            bank.adminMint(count, _actors[i]);
            _recordMint(_actors[i], count);
            mintedReserve += count;
        }

        vm.roll(bank.offsetTargetBlock() + 1);
        bank.revealOffset();
        while (!bank.registrySynced()) {
            bank.buildRegistry(2_500);
        }

        vm.prank(admin);
        token.mintLiquidity(address(this), LIQUIDITY_CAP);
        token.sealMinting();
    }

    // ────────────────────────────── sale / phase actions ───────────────────────────────

    /// @notice From Setup: configure the sale (random early-bird/public split) and open it.
    function actOpenSale(uint256 ebAlloc, uint256 walletCap) external {
        if (bank.phase() != WordBank.SalePhase.Setup) return;
        calls["openSale"]++;
        ebAlloc = _bound(ebAlloc, 0, PUBLIC_SUPPLY);
        walletCap = _bound(walletCap, 1, 2_000);
        vm.startPrank(admin);
        bank.setSaleConfig(ebAlloc, PUBLIC_SUPPLY - ebAlloc, EB_PRICE, PUB_PRICE, walletCap);
        bank.openEarlyBird();
        vm.stopPrank();
    }

    /// @notice From Between: reconfigure allocations within the contract's own floors
    ///         (never below what each phase already minted), keeping the 10,000 invariant.
    function actReconfigure(uint256 ebAlloc, uint256 walletCap) external {
        if (bank.phase() != WordBank.SalePhase.Between) return;
        calls["reconfigure"]++;
        uint256 ebFloor = bank.earlyBirdMinted();
        uint256 ebCeil = PUBLIC_SUPPLY - bank.publicMinted();
        ebAlloc = _bound(ebAlloc, ebFloor, ebCeil);
        walletCap = _bound(walletCap, 1, 2_000);
        vm.prank(admin);
        bank.setSaleConfig(ebAlloc, PUBLIC_SUPPLY - ebAlloc, EB_PRICE, PUB_PRICE, walletCap);
    }

    /// @notice Walks the phase state machine: EarlyBird→Between, Between→PublicSale, and
    ///         occasionally PublicSale→Between (pause) to exercise the reconfigure window.
    function actAdvancePhase(uint256 seed) external {
        WordBank.SalePhase phase = bank.phase();
        if (phase == WordBank.SalePhase.EarlyBird) {
            calls["closeEarlyBird"]++;
            vm.prank(admin);
            bank.closeEarlyBird();
        } else if (phase == WordBank.SalePhase.Between) {
            calls["openPublicSale"]++;
            vm.prank(admin);
            bank.openPublicSale();
        } else if (phase == WordBank.SalePhase.PublicSale && seed % 4 == 0) {
            calls["pausePublicSale"]++;
            vm.prank(admin);
            bank.pausePublicSale();
        }
    }

    // ───────────────────────────────── mint actions ────────────────────────────────────

    function actEarlyBirdMint(uint256 actorSeed, uint256 count, uint256 seed) external {
        if (bank.phase() != WordBank.SalePhase.EarlyBird) return;
        address actor = _pickActor(actorSeed);
        uint256 remaining = bank.earlyBirdAllocation() - bank.earlyBirdMinted();
        uint256 cap = bank.earlyBirdWalletCap();
        uint256 already = bank.earlyBirdMintedBy(actor);
        uint256 capLeft = cap > already ? cap - already : 0;
        uint256 max = remaining < capLeft ? remaining : capLeft;
        if (max == 0) return;
        calls["earlyBirdMint"]++;
        count = (seed % 3 == 0) ? max : _bound(count, 1, max);
        vm.prank(actor);
        bank.earlyBirdMint{value: count * EB_PRICE}(count);
        _recordMint(actor, count);
    }

    function actPublicMint(uint256 actorSeed, uint256 count, uint256 seed) external {
        if (bank.phase() != WordBank.SalePhase.PublicSale) return;
        uint256 remaining = bank.publicAllocation() - bank.publicMinted();
        if (remaining == 0) return;
        calls["publicMint"]++;
        address actor = _pickActor(actorSeed);
        // Bias toward selling out so the post-reveal regime is reachable within one run.
        count = (seed % 3 == 0) ? remaining : _bound(count, 1, remaining);
        vm.prank(actor);
        bank.publicMint{value: count * PUB_PRICE}(count);
        _recordMint(actor, count);
    }

    function actAdminMint(uint256 actorSeed, uint256 count, uint256 seed) external {
        uint256 remaining = ADMIN_RESERVE - bank.adminMinted();
        if (remaining == 0) return;
        calls["adminMint"]++;
        address actor = _pickActor(actorSeed);
        count = (seed % 3 == 0) ? remaining : _bound(count, 1, remaining);
        vm.prank(admin);
        bank.adminMint(count, actor);
        _recordMint(actor, count);
    }

    // ─────────────────────────── provenance / registry actions ─────────────────────────

    /// @notice Reveals the offset once armed (rolling to the target block if needed); if the
    ///         256-block window has already lapsed, re-arms instead — both real paths.
    function actRevealOffset() external {
        if (bank.offsetSet()) return;
        uint256 target = bank.offsetTargetBlock();
        if (target == 0) return;
        if (block.number <= target) vm.roll(target + 1);
        if (blockhash(target) == bytes32(0)) {
            calls["rearmOffset"]++;
            bank.rearmOffset();
            return;
        }
        calls["revealOffset"]++;
        bank.revealOffset();
    }

    /// @notice Deliberately lets the reveal window lapse, then re-arms (permissionless).
    function actLapseAndRearm() external {
        if (bank.offsetSet()) return;
        uint256 target = bank.offsetTargetBlock();
        if (target == 0) return;
        if (block.number <= target + 256) vm.roll(target + 257);
        calls["lapseAndRearm"]++;
        bank.rearmOffset();
    }

    function actBuildRegistry(uint256 chunk, uint256 seed) external {
        if (!bank.offsetSet()) return;
        uint256 cursor = bank.registryCursor();
        uint256 target = bank.preRevealMinted();
        if (cursor >= target) return;
        calls["buildRegistry"]++;
        chunk = (seed % 2 == 0) ? target - cursor : _bound(chunk, 1, target - cursor);
        bank.buildRegistry(chunk);
    }

    // ─────────────────────────────── rewards actions ───────────────────────────────────

    /// @notice Deposits fee ETH (any amount, any caller — the FeeHook is just one possible
    ///         depositor). A zero-value call is only made as the permissionless kick that
    ///         distributes a previously deferred zero-alive buffer.
    function actDeposit(uint256 actorSeed, uint256 amount) external {
        amount = _bound(amount, 0, 100 ether);
        if (amount == 0 && distributor.pendingUndistributed() == 0) return;
        calls["deposit"]++;
        address actor = _pickActor(actorSeed);
        vm.prank(actor);
        distributor.deposit{value: amount}();
        ghostDistIn += amount;
    }

    function actClaim(uint256 actorSeed, uint256 seed) external {
        address actor = _pickActor(actorSeed);
        uint256 n = _owned[actor].length;
        if (n == 0) return;
        calls["claim"]++;
        uint256 take = _bound(seed, 1, n > 20 ? 20 : n);
        uint256 start = seed % n;
        uint256[] memory ids = new uint256[](take);
        for (uint256 i = 0; i < take; ++i) {
            ids[i] = _owned[actor][(start + i) % n];
        }
        uint256 before = address(distributor).balance;
        vm.prank(actor);
        distributor.claimRewards(ids);
        ghostDistOut += before - address(distributor).balance;
    }

    function actSweepDust() external {
        uint256 reserved = distributor.pendingUndistributed() + (distributor.owedScaled() + 1e18 - 1) / 1e18;
        uint256 balance = address(distributor).balance;
        if (balance <= reserved) return;
        calls["sweepDust"]++;
        distributor.sweepDust();
        ghostDistOut += balance - address(distributor).balance;
    }

    // ─────────────────────────────── transfer / unbind ─────────────────────────────────

    function actTransfer(uint256 fromSeed, uint256 toSeed, uint256 idSeed) external {
        address from = _pickActor(fromSeed);
        uint256 n = _owned[from].length;
        if (n == 0) return;
        calls["transfer"]++;
        address to = _pickActor(toSeed);
        uint256 tokenId = _owned[from][idSeed % n];
        vm.prank(from);
        bank.transferFrom(from, to, tokenId);
        _removeOwned(from, tokenId);
        _addOwned(to, tokenId);
    }

    function actUnbind(uint256 actorSeed, uint256 idSeed) external {
        address actor = _pickActor(actorSeed);
        uint256 tokenId = _findRegisteredOwned(actor, idSeed);
        if (tokenId == 0) return;
        calls["unbind"]++;
        uint256 before = address(distributor).balance;
        vm.prank(actor);
        bank.unbind(tokenId);
        ghostDistOut += before - address(distributor).balance;
        _recordUnbind(actor, tokenId);
    }

    function actUnbindMany(uint256 actorSeed, uint256 seed) external {
        address actor = _pickActor(actorSeed);
        uint256 n = _owned[actor].length;
        if (n == 0) return;
        uint256 maxTake = _bound(seed, 1, 5);
        uint256[] memory ids = new uint256[](maxTake);
        uint256 k;
        uint256 start = seed % n;
        for (uint256 i = 0; i < n && k < maxTake; ++i) {
            uint256 tokenId = _owned[actor][(start + i) % n];
            if (bank.indexInCategory(tokenId) != 0) ids[k++] = tokenId;
        }
        if (k == 0) return;
        calls["unbindMany"]++;
        assembly {
            mstore(ids, k) // trim to the ids actually collected
        }
        uint256 before = address(distributor).balance;
        vm.prank(actor);
        bank.unbindMany(ids);
        ghostDistOut += before - address(distributor).balance;
        for (uint256 i = 0; i < k; ++i) {
            _recordUnbind(actor, ids[i]);
        }
    }

    // ─────────────────────────── liquidity / seal / burn ───────────────────────────────

    function actMintLiquidity(uint256 amount, uint256 seed) external {
        if (token.mintingSealed()) return;
        uint256 left = LIQUIDITY_CAP - token.liquidityMinted();
        if (left == 0) return;
        calls["mintLiquidity"]++;
        amount = (seed % 3 == 0) ? left : _bound(amount, 1, left);
        vm.prank(admin);
        token.mintLiquidity(address(this), amount);
    }

    function actSealMinting() external {
        if (token.mintingSealed()) return;
        if (token.backingMinted() != 10_000_000e18 || token.liquidityMinted() != LIQUIDITY_CAP) return;
        calls["sealMinting"]++;
        token.sealMinting(); // permissionless by design
    }

    /// @notice Burns WORD from the handler's own (liquidity-allotment) balance as the wired
    ///         burner; occasionally burns the entire current burnable excess to land supply
    ///         exactly on the live (dynamic) floor. There is no permanent completion — once
    ///         supply meets the floor, burning simply pauses until a later unbind lowers it.
    function actBurn(uint256 amount, uint256 seed) external {
        if (!token.mintingSealed()) return;
        uint256 headroom = token.burnableExcess(); // totalSupply - totalAlive*1000e18
        uint256 balance = token.balanceOf(address(this));
        uint256 max = headroom < balance ? headroom : balance;
        if (max == 0) return;
        calls["burn"]++;
        amount = (seed % 5 == 0) ? max : _bound(amount, 1, max);
        token.burn(amount);
    }

    // ──────────────────────────────── ghost views ──────────────────────────────────────

    function actorCount() external view returns (uint256) {
        return _actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return _actors[i];
    }

    function unboundCount() external view returns (uint256) {
        return _unboundIds.length;
    }

    function unboundAt(uint256 i) external view returns (uint256) {
        return _unboundIds[i];
    }

    function ownedCount(address actor) external view returns (uint256) {
        return _owned[actor].length;
    }

    // ─────────────────────────────────── internals ─────────────────────────────────────

    function _pickActor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    /// @dev Records `count` freshly minted sequential ids (ending at totalMinted) for `to`.
    function _recordMint(address to, uint256 count) internal {
        uint256 lastId = bank.totalMinted();
        for (uint256 id = lastId - count + 1; id <= lastId; ++id) {
            _addOwned(to, id);
        }
    }

    function _recordUnbind(address actor, uint256 tokenId) internal {
        _removeOwned(actor, tokenId);
        _unboundIds.push(tokenId);
    }

    /// @dev Scans the actor's owned set from a random start for a registered (unbindable)
    ///      id; returns 0 when none exists. Bounded by the owned-set size.
    function _findRegisteredOwned(address actor, uint256 seed) internal view returns (uint256) {
        uint256 n = _owned[actor].length;
        if (n == 0) return 0;
        uint256 start = seed % n;
        for (uint256 i = 0; i < n; ++i) {
            uint256 tokenId = _owned[actor][(start + i) % n];
            if (bank.indexInCategory(tokenId) != 0) return tokenId;
        }
        return 0;
    }

    function _addOwned(address to, uint256 tokenId) internal {
        _owned[to].push(tokenId);
        _ownedIndex[tokenId] = _owned[to].length;
        _ownerOfGhost[tokenId] = to;
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
        delete _ownerOfGhost[tokenId];
    }
}
