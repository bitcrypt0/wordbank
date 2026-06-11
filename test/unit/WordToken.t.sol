// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {WordToken} from "../../src/WordToken.sol";
import {IWordToken} from "../../src/interfaces/IWordToken.sol";

/// @notice Minimal stand-in for WordBank in the WordToken floor tests. It is the token's
///         deployer (so the `wordBank` immutable points here) and exposes a settable
///         `totalAlive` that drives `currentBurnFloor()`. Simulating an unbind is simply
///         lowering `totalAlive` — exactly the live read the dynamic floor depends on.
contract MockFloorBank {
    uint256 public totalAlive;

    function setTotalAlive(uint256 n) external {
        totalAlive = n;
    }
}

/// @notice Unit + fuzz tests for WordToken. All calls are driven through the frozen
///         IWordToken interface wherever it defines the surface, which doubles as a
///         compile-and-runtime check that the implementation conforms to the frozen ABI.
contract WordTokenTest is Test {
    uint256 internal constant BACKING_CAP = 10_000_000e18;
    uint256 internal constant LIQUIDITY_CAP = 1_000_000e18;
    uint256 internal constant TOTAL_CAP = 11_000_000e18;
    uint256 internal constant BURN_FLOOR = 10_000_000e18;
    uint256 internal constant BACKING_PER_NFT = 1_000e18;

    WordToken internal token;
    IWordToken internal itoken; // frozen-interface view of the same contract

    address internal admin = makeAddr("admin");
    address internal rando = makeAddr("rando");
    address internal burnEngine = makeAddr("burnEngine"); // plays the BurnEngine

    MockFloorBank internal bankMock; // plays the WordBank: deployer + live-floor oracle
    address internal bank; // == address(bankMock), the wordBank immutable / sole backing minter

    function setUp() public {
        bankMock = new MockFloorBank();
        bank = address(bankMock);
        vm.prank(bank);
        token = new WordToken(admin);
        itoken = IWordToken(address(token));
    }

    // ─────────────────────────────── metadata & wiring ─────────────────────────────────

    function test_metadata() public view {
        assertEq(itoken.name(), "WordBank WORD");
        assertEq(itoken.symbol(), "WORD");
        assertEq(itoken.decimals(), 18);
        assertEq(itoken.totalSupply(), 0);
    }

    function test_wordBankIsDeployer_adminIsOwner() public view {
        assertEq(token.wordBank(), bank);
        assertEq(token.owner(), admin);
    }

    function test_maxSupply_isElevenMillion() public view {
        assertEq(token.MAX_SUPPLY(), 11_000_000e18);
        assertEq(token.MAX_SUPPLY(), token.BACKING_CAP() + token.LIQUIDITY_CAP());
    }

    // ────────────────────────────────── backing mint ───────────────────────────────────

    function test_mint_onlyWordBank() public {
        vm.prank(bank);
        itoken.mint(bank, BACKING_PER_NFT);
        assertEq(itoken.balanceOf(bank), BACKING_PER_NFT);
        assertEq(token.backingMinted(), BACKING_PER_NFT);

        vm.prank(admin);
        vm.expectRevert(WordToken.NotWordBank.selector);
        itoken.mint(admin, BACKING_PER_NFT);

        vm.prank(rando);
        vm.expectRevert(WordToken.NotWordBank.selector);
        itoken.mint(rando, BACKING_PER_NFT);
    }

    function test_mint_capExactlyTenMillion() public {
        vm.prank(bank);
        itoken.mint(bank, BACKING_CAP);
        assertEq(token.backingMinted(), BACKING_CAP);
        assertEq(itoken.totalSupply(), BACKING_CAP);
    }

    function test_mint_revertsOneWeiOverCap() public {
        vm.startPrank(bank);
        itoken.mint(bank, BACKING_CAP);
        vm.expectRevert(WordToken.BackingCapExceeded.selector);
        itoken.mint(bank, 1);
        vm.stopPrank();
    }

    function test_mint_backingSumsToTenMillion_overTenThousandNFTs() public {
        vm.startPrank(bank);
        for (uint256 i = 0; i < 10_000; ++i) {
            itoken.mint(bank, BACKING_PER_NFT);
        }
        vm.stopPrank();
        assertEq(token.backingMinted(), BACKING_CAP);
        assertEq(itoken.totalSupply(), BACKING_CAP);
        // the 10,001st NFT's backing cannot exist
        vm.prank(bank);
        vm.expectRevert(WordToken.BackingCapExceeded.selector);
        itoken.mint(bank, BACKING_PER_NFT);
    }

    function testFuzz_mint_neverExceedsCap(uint256 a, uint256 b) public {
        a = bound(a, 0, BACKING_CAP);
        b = bound(b, 0, BACKING_CAP);
        vm.startPrank(bank);
        itoken.mint(bank, a);
        if (a + b > BACKING_CAP) {
            vm.expectRevert(WordToken.BackingCapExceeded.selector);
            itoken.mint(bank, b);
        } else {
            itoken.mint(bank, b);
            assertEq(token.backingMinted(), a + b);
        }
        vm.stopPrank();
        assertLe(token.backingMinted(), BACKING_CAP);
    }

    // ───────────────────────────────── liquidity mint ──────────────────────────────────

    function test_mintLiquidity_onlyAdmin() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        itoken.mintLiquidity(rando, 1e18);

        vm.prank(bank);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bank));
        itoken.mintLiquidity(bank, 1e18);

        vm.prank(admin);
        itoken.mintLiquidity(admin, 1e18);
        assertEq(itoken.balanceOf(admin), 1e18);
        assertEq(itoken.liquidityMinted(), 1e18);
    }

    function test_mintLiquidity_capExactlyOneMillion_andEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(token));
        emit WordToken.LiquidityMinted(admin, LIQUIDITY_CAP, LIQUIDITY_CAP);
        itoken.mintLiquidity(admin, LIQUIDITY_CAP);
        assertEq(itoken.liquidityMinted(), LIQUIDITY_CAP);
    }

    function test_mintLiquidity_revertsOneWeiOverCap() public {
        vm.startPrank(admin);
        itoken.mintLiquidity(admin, LIQUIDITY_CAP);
        vm.expectRevert(WordToken.LiquidityCapExceeded.selector);
        itoken.mintLiquidity(admin, 1);
        vm.stopPrank();
    }

    function test_mintLiquidity_cumulativeAcrossCalls() public {
        vm.startPrank(admin);
        itoken.mintLiquidity(admin, 400_000e18);
        itoken.mintLiquidity(rando, 600_000e18);
        vm.expectRevert(WordToken.LiquidityCapExceeded.selector);
        itoken.mintLiquidity(admin, 1);
        vm.stopPrank();
        assertEq(itoken.liquidityMinted(), LIQUIDITY_CAP);
        assertEq(itoken.balanceOf(rando), 600_000e18);
    }

    function testFuzz_mintLiquidity_neverExceedsCap(uint256 a, uint256 b) public {
        a = bound(a, 0, LIQUIDITY_CAP);
        b = bound(b, 0, LIQUIDITY_CAP);
        vm.startPrank(admin);
        itoken.mintLiquidity(admin, a);
        if (a + b > LIQUIDITY_CAP) {
            vm.expectRevert(WordToken.LiquidityCapExceeded.selector);
            itoken.mintLiquidity(admin, b);
        } else {
            itoken.mintLiquidity(admin, b);
        }
        vm.stopPrank();
        assertLe(itoken.liquidityMinted(), LIQUIDITY_CAP);
    }

    // ──────────────────────────────────── sealing ──────────────────────────────────────

    function _fillBothAllotments() internal {
        vm.prank(bank);
        itoken.mint(bank, BACKING_CAP);
        vm.prank(admin);
        itoken.mintLiquidity(admin, LIQUIDITY_CAP);
    }

    function test_seal_revertsWhileBackingIncomplete() public {
        vm.prank(admin);
        itoken.mintLiquidity(admin, LIQUIDITY_CAP);
        vm.expectRevert(WordToken.SealPreconditionsNotMet.selector);
        itoken.sealMinting();
    }

    function test_seal_revertsWhileLiquidityIncomplete() public {
        vm.prank(bank);
        itoken.mint(bank, BACKING_CAP);
        vm.prank(admin);
        itoken.mintLiquidity(admin, LIQUIDITY_CAP - 1);
        vm.expectRevert(WordToken.SealPreconditionsNotMet.selector);
        itoken.sealMinting();
    }

    function test_seal_permissionless_whenBothAllotmentsFull() public {
        _fillBothAllotments();
        assertFalse(itoken.mintingSealed());

        vm.prank(rando); // anyone may seal
        vm.expectEmit(false, false, false, true, address(token));
        emit WordToken.MintingSealed(TOTAL_CAP);
        itoken.sealMinting();

        assertTrue(itoken.mintingSealed());
        assertEq(itoken.totalSupply(), TOTAL_CAP);
    }

    function test_seal_isPermanent() public {
        _fillBothAllotments();
        itoken.sealMinting();

        vm.expectRevert(WordToken.MintingIsSealed.selector);
        itoken.sealMinting();

        vm.prank(bank);
        vm.expectRevert(WordToken.MintingIsSealed.selector);
        itoken.mint(bank, 1);

        vm.prank(admin);
        vm.expectRevert(WordToken.MintingIsSealed.selector);
        itoken.mintLiquidity(admin, 1);

        assertEq(itoken.totalSupply(), TOTAL_CAP);
    }

    // ─────────────────────────────── vanilla ERC-20 paths ──────────────────────────────

    function test_transferAndApprove_areVanilla() public {
        vm.prank(bank);
        itoken.mint(bank, 5_000e18);

        vm.prank(bank);
        assertTrue(itoken.transfer(alicePlaceholder(), 2_000e18));
        assertEq(itoken.balanceOf(alicePlaceholder()), 2_000e18);

        vm.prank(alicePlaceholder());
        assertTrue(itoken.approve(rando, 500e18));
        assertEq(itoken.allowance(alicePlaceholder(), rando), 500e18);

        vm.prank(rando);
        assertTrue(itoken.transferFrom(alicePlaceholder(), rando, 500e18));
        assertEq(itoken.balanceOf(rando), 500e18);
        // supply never changed by transfers
        assertEq(itoken.totalSupply(), 5_000e18);
    }

    function alicePlaceholder() internal returns (address) {
        return makeAddr("alice");
    }

    // ─────────────────────────────── ownership handover ────────────────────────────────

    function test_ownership_isTwoStep() public {
        vm.prank(admin);
        token.transferOwnership(rando);
        assertEq(token.owner(), admin); // not yet effective

        vm.prank(rando);
        token.acceptOwnership();
        assertEq(token.owner(), rando);
    }

    // ──────────────────────────── buy-and-burn (v3, dynamic floor) ─────────────────────

    /// @dev Brings the token to the launch-ready state with a FULL collection alive:
    ///      10M backing minted into the bank, totalAlive = 10,000 (so currentBurnFloor() ==
    ///      BURN_FLOOR == 10M), the 1M liquidity allotment held by the BurnEngine, burner
    ///      wired, minting sealed. Total supply == 11M, burnableExcess == 1M.
    function _launchReady() internal {
        vm.prank(bank);
        itoken.mint(bank, BACKING_CAP); // 10,000 NFTs' worth of backing held by the bank
        bankMock.setTotalAlive(10_000); // every NFT alive → floor 10,000 * 1000e18 == 10M
        vm.prank(admin);
        itoken.mintLiquidity(burnEngine, LIQUIDITY_CAP); // BurnEngine holds the WORD it buys
        vm.prank(admin);
        token.setBurner(burnEngine);
        itoken.sealMinting();
    }

    function test_setBurner_onlyOnceNeverZeroOnlyAdmin() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        token.setBurner(burnEngine);

        vm.prank(admin);
        vm.expectRevert(WordToken.ZeroAddress.selector);
        token.setBurner(address(0));

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(token));
        emit WordToken.BurnerSet(burnEngine);
        token.setBurner(burnEngine);
        assertEq(itoken.burner(), burnEngine);

        vm.prank(admin);
        vm.expectRevert(WordToken.BurnerAlreadySet.selector);
        token.setBurner(rando);
    }

    function test_burn_onlyBurner() public {
        _launchReady();
        vm.prank(rando);
        vm.expectRevert(WordToken.NotBurner.selector);
        itoken.burn(1e18);

        vm.prank(admin);
        vm.expectRevert(WordToken.NotBurner.selector);
        itoken.burn(1e18);
    }

    function test_burn_gatedOnSeal() public {
        // burner set + balance present + collection alive, but NOT sealed → burn must revert
        vm.prank(bank);
        itoken.mint(bank, BACKING_CAP);
        bankMock.setTotalAlive(10_000);
        vm.prank(admin);
        itoken.mintLiquidity(burnEngine, LIQUIDITY_CAP);
        vm.prank(admin);
        token.setBurner(burnEngine);

        vm.prank(burnEngine);
        vm.expectRevert(WordToken.MintingNotSealed.selector);
        itoken.burn(1e18);

        // after seal it works
        itoken.sealMinting();
        vm.prank(burnEngine);
        itoken.burn(1e18);
        assertEq(itoken.totalSupply(), TOTAL_CAP - 1e18);
    }

    function test_currentBurnFloor_tracksTotalAlive() public {
        _launchReady();
        assertEq(itoken.currentBurnFloor(), BURN_FLOOR); // 10,000 alive
        assertEq(itoken.burnableExcess(), LIQUIDITY_CAP); // 11M - 10M

        bankMock.setTotalAlive(9_000);
        assertEq(itoken.currentBurnFloor(), 9_000 * BACKING_PER_NFT); // 9M
        assertEq(itoken.burnableExcess(), TOTAL_CAP - 9_000 * BACKING_PER_NFT); // 2M

        bankMock.setTotalAlive(0); // whole collection unbound
        assertEq(itoken.currentBurnFloor(), 0);
        assertEq(itoken.burnableExcess(), TOTAL_CAP); // every wei burnable
    }

    function test_burn_tracksTotalAndEmits() public {
        _launchReady();
        vm.prank(burnEngine);
        vm.expectEmit(true, false, false, true, address(token));
        emit WordToken.Burned(burnEngine, 100_000e18, TOTAL_CAP - 100_000e18);
        itoken.burn(100_000e18);
        assertEq(itoken.burnedTotal(), 100_000e18);
        assertEq(itoken.totalSupply(), TOTAL_CAP - 100_000e18);
        assertEq(itoken.balanceOf(burnEngine), LIQUIDITY_CAP - 100_000e18);
        assertEq(itoken.burnableExcess(), LIQUIDITY_CAP - 100_000e18);

        vm.prank(burnEngine);
        itoken.burn(50_000e18);
        assertEq(itoken.burnedTotal(), 150_000e18);
    }

    function test_burn_toExactlyFloorSucceeds_noLatch() public {
        _launchReady();
        vm.prank(burnEngine);
        vm.expectEmit(true, false, false, true, address(token));
        emit WordToken.Burned(burnEngine, LIQUIDITY_CAP, BURN_FLOOR);
        itoken.burn(LIQUIDITY_CAP); // burn the entire 1M excess → exactly the floor

        assertEq(itoken.totalSupply(), BURN_FLOOR);
        assertEq(itoken.burnedTotal(), LIQUIDITY_CAP);
        assertEq(itoken.burnableExcess(), 0);

        // No permanent completion: a further burn simply reverts on the floor (NOT a latch).
        vm.prank(burnEngine);
        vm.expectRevert(WordToken.BurnFloorBreached.selector);
        itoken.burn(1);
    }

    function test_burn_oneWeiPastFloorReverts() public {
        _launchReady();
        // burn down to floor + 1 wei first
        vm.prank(burnEngine);
        itoken.burn(LIQUIDITY_CAP - 1);
        assertEq(itoken.totalSupply(), BURN_FLOOR + 1);
        assertEq(itoken.burnableExcess(), 1);

        // two wei would breach the floor
        vm.prank(burnEngine);
        vm.expectRevert(WordToken.BurnFloorBreached.selector);
        itoken.burn(2);

        // exactly one wei lands on the floor
        vm.prank(burnEngine);
        itoken.burn(1);
        assertEq(itoken.totalSupply(), BURN_FLOOR);
        assertEq(itoken.burnableExcess(), 0);
    }

    /// @notice The heart of the dynamic-floor change: at the floor burning pauses, but a later
    ///         unbind lowers totalAlive (freeing that NFT's 1,000 WORD into circulation), which
    ///         lowers the floor and makes the freed WORD burnable again. No permanent latch.
    function test_burn_pausesAtFloor_resumesAfterUnbind() public {
        _launchReady();
        vm.prank(burnEngine);
        itoken.burn(LIQUIDITY_CAP); // down to the 10M floor
        assertEq(itoken.burnableExcess(), 0);

        vm.prank(burnEngine);
        vm.expectRevert(WordToken.BurnFloorBreached.selector);
        itoken.burn(1e18);

        // Simulate 3 unbinds: totalAlive 10,000 → 9,997. Floor drops by 3 * 1,000e18; the
        // freed 3,000 WORD (now circulating) becomes burnable.
        bankMock.setTotalAlive(9_997);
        assertEq(itoken.currentBurnFloor(), 9_997 * BACKING_PER_NFT);
        assertEq(itoken.burnableExcess(), 3_000e18);

        // The freed WORD reaches the BurnEngine (it bought it off the pool); model that as a
        // transfer from the bank's backing pool, then the engine burns it.
        vm.prank(bank);
        itoken.transfer(burnEngine, 3_000e18);
        vm.prank(burnEngine);
        itoken.burn(3_000e18);

        assertEq(itoken.totalSupply(), 9_997 * BACKING_PER_NFT);
        assertEq(itoken.burnableExcess(), 0);
        assertEq(itoken.burnedTotal(), LIQUIDITY_CAP + 3_000e18); // ledger spans both phases
    }

    function test_burn_revertsIfBurnerBalanceInsufficient() public {
        // burner is wired but holds only part of the burnable excess; the rest is elsewhere.
        vm.prank(bank);
        itoken.mint(bank, BACKING_CAP);
        bankMock.setTotalAlive(10_000);
        vm.prank(admin);
        itoken.mintLiquidity(burnEngine, 100_000e18); // burner holds 100k
        vm.prank(admin);
        itoken.mintLiquidity(rando, LIQUIDITY_CAP - 100_000e18); // rest parked elsewhere
        vm.prank(admin);
        token.setBurner(burnEngine);
        itoken.sealMinting();

        // floor allows burning up to 1M, but the burner only has 100k of its own
        vm.prank(burnEngine);
        vm.expectRevert(); // OZ ERC20InsufficientBalance
        itoken.burn(200_000e18);
    }

    function testFuzz_burn_neverBreachesFloor(uint256 amount) public {
        _launchReady();
        uint256 excess = itoken.burnableExcess(); // 1M at full collection
        amount = bound(amount, 0, excess * 2);
        vm.prank(burnEngine);
        if (amount > excess) {
            vm.expectRevert(WordToken.BurnFloorBreached.selector);
            itoken.burn(amount);
        } else {
            itoken.burn(amount);
        }
        assertGe(itoken.totalSupply(), itoken.currentBurnFloor());
    }

    /// @notice Floor + burnableExcess stay correct for any alive count (fuzzed) at full supply.
    function testFuzz_floorAndExcess_forAnyTotalAlive(uint256 alive) public {
        _launchReady(); // supply == 11M
        alive = bound(alive, 0, 10_000);
        bankMock.setTotalAlive(alive);
        uint256 floor = alive * BACKING_PER_NFT;
        assertEq(itoken.currentBurnFloor(), floor);
        assertEq(itoken.burnableExcess(), TOTAL_CAP - floor); // supply (11M) >= floor (<=10M)
    }

    // ───────────────────────── renounceability (scanner hygiene) ───────────────────────

    /// @notice The full launch sequence: set burner → mint out → seal → renounce ownership.
    ///         Afterward owner == 0x0 (scanners read it clean), the burner still works, and
    ///         every owner-gated path is permanently dead.
    function test_renounce_sequence_burnerStillWorks_ownerPathsDead() public {
        _launchReady();

        vm.prank(admin);
        token.renounceOwnership();
        assertEq(token.owner(), address(0));

        // owner-gated paths are now permanently unreachable
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        token.setBurner(rando);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        itoken.mintLiquidity(admin, 1);

        // burner (owner-independent) keeps working all the way to the floor
        vm.prank(burnEngine);
        itoken.burn(LIQUIDITY_CAP);
        assertEq(itoken.totalSupply(), BURN_FLOOR);
        assertEq(itoken.burnableExcess(), 0);
    }
}
