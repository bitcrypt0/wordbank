// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IntegrationBase} from "./IntegrationBase.sol";
import {RoyaltySplitter} from "../../src/RoyaltySplitter.sol";

/// @dev A contract admin that reverts on ETH receipt until toggled — for the griefing path.
contract RevertingAdmin {
    bool public accept;
    uint256 public received;

    function setAccept(bool a) external {
        accept = a;
    }

    receive() external payable {
        if (!accept) revert("admin rejects ETH");
        received += msg.value;
    }
}

/// @title  RoyaltySplitter — cross-contract integration (agent 6)
/// @notice The unit suite (test/unit/RoyaltySplitter.t.sol) proves the splitter in isolation
///         against mock sinks; this suite proves it WIRED to the real protocol: WordBank's
///         ERC-2981 receiver, the real BurnEngine / BountyEngine `deposit()` surfaces, the
///         real RewardsDistributor (which must get NOTHING), and the downstream effect on
///         buy-and-burn and the bounty treasury. Real contracts throughout; a mock ERC-20 and
///         a reverting-admin harness are the only stand-ins (per charter).
contract RoyaltyIntegrationTest is IntegrationBase {
    function setUp() public {
        _deployProtocol(); // splitter + WETH wired; no pool needed for the split mechanics
    }

    function _fundSplitterEth(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(royaltySplitter).call{value: amount}("");
        assertTrue(ok, "fund splitter");
    }

    function _fundSplitterWeth(uint256 amount) internal {
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.transfer(address(royaltySplitter), amount);
    }

    /// @dev Asserts an equal-thirds split of exactly `total` reached the real sinks + admin,
    ///      summing to exactly `total`, with the RewardsDistributor untouched.
    function _assertEqualThirds(uint256 total) internal {
        uint256 burnBefore = burnEngine.pendingEth();
        uint256 bountyBefore = bounty.freeTreasury();
        uint256 adminBefore = admin.balance;
        uint256 distBefore = address(distributor).balance;

        royaltySplitter.distribute();

        uint256 toBurn = burnEngine.pendingEth() - burnBefore;
        uint256 toBounty = bounty.freeTreasury() - bountyBefore;
        uint256 toAdmin = admin.balance - adminBefore;

        assertEq(toBurn, total / 3, "burn third");
        assertEq(toBounty, total / 3, "bounty third");
        assertEq(toAdmin, total - toBurn - toBounty, "admin third (remainder)");
        assertEq(toBurn + toBounty + toAdmin, total, "slices sum to exactly the distributed balance");
        assertLe(toAdmin - toBurn, 2, "remainder <= 2 wei on admin");
        assertEq(address(distributor).balance, distBefore, "RewardsDistributor gets NO royalty cut");
        assertEq(address(royaltySplitter).balance, 0, "nothing left in the splitter (EOA admin accepts)");
    }

    // ───────────────────────────────── ERC-2981 wiring ─────────────────────────────────

    /// @dev After the deploy path, WordBank's royalty receiver is the splitter at 3%.
    function test_erc2981_wiringToSplitterAt3pct() public {
        uint256 salePrice = 10 ether;
        (address receiver, uint256 amount) = bank.royaltyInfo(1, salePrice);
        assertEq(receiver, address(royaltySplitter), "ERC-2981 receiver == RoyaltySplitter");
        assertEq(amount, salePrice * 300 / 10_000, "3% royalty");
        assertEq(amount, 0.3 ether);
    }

    // ─────────────────────────────── equal-thirds end to end ───────────────────────────

    function test_equalThirds_ethOnly() public {
        _fundSplitterEth(9 ether);
        _assertEqualThirds(9 ether);
    }

    function test_equalThirds_wethOnly_unwrapPath() public {
        _fundSplitterWeth(9 ether);
        assertEq(weth.balanceOf(address(royaltySplitter)), 9 ether);
        _assertEqualThirds(9 ether);
        assertEq(weth.balanceOf(address(royaltySplitter)), 0, "WETH unwrapped during distribute");
    }

    function test_equalThirds_mixedEthAndWeth() public {
        _fundSplitterEth(3 ether);
        _fundSplitterWeth(6 ether);
        _assertEqualThirds(9 ether); // unwrap folds the 6 WETH into the 3 ETH → 9 total
    }

    /// @dev Non-divisible amount: the remainder lands on admin and slices still sum exactly.
    function test_equalThirds_remainderToAdmin() public {
        _fundSplitterEth(1 ether);
        _assertEqualThirds(1 ether);
    }

    /// @dev Wei-dust: 3 wei → 1/1/1 (the smallest balance both protocol sinks accept, since
    ///      BountyEngine.deposit rejects a zero value — see test_weiDust_belowThreeReverts).
    function test_equalThirds_weiDust() public {
        _fundSplitterEth(3);
        _assertEqualThirds(3);
    }

    /// @dev OBSERVATION (OBS-RS1, INFO — reported to overseer, not a fix request): a 1–2 wei
    ///      distributable balance makes `distribute()` revert, because the burn/bounty thirds
    ///      round to 0 and `BountyEngine.deposit{value:0}()` reverts `ZeroDeposit`. Harmless
    ///      (1–2 wei, self-clears the moment any further royalty tops the balance to ≥3 wei),
    ///      but it is a `ZeroDeposit` revert rather than a clean splitter-level signal. Pinned
    ///      here so the behaviour is known and tracked.
    function test_weiDust_belowThreeReverts() public {
        _fundSplitterEth(2);
        vm.expectRevert(); // BountyEngine.ZeroDeposit (burn/bounty thirds == 0)
        royaltySplitter.distribute();
        // Self-clears: once topped to >= 3 wei it distributes 1/1/1 cleanly.
        _fundSplitterEth(1);
        _assertEqualThirds(3);
    }

    // ──────────────────────────────────── rescue ───────────────────────────────────────

    function test_rescue_strayErc20_adminOnly() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(address(royaltySplitter), 1_000e6);

        // Non-admin reverts.
        vm.prank(bob);
        vm.expectRevert(RoyaltySplitter.NotAdmin.selector);
        royaltySplitter.rescueToken(IERC20(address(usdc)));

        // Admin sweeps to admin.
        vm.prank(admin);
        royaltySplitter.rescueToken(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(admin), 1_000e6, "rescued to admin");
        assertEq(usdc.balanceOf(address(royaltySplitter)), 0);
    }

    /// @dev WETH may never be rescued (would bypass the trustless WETH split); it still
    ///      auto-splits via distribute().
    function test_rescue_cannotRescueWeth() public {
        _fundSplitterWeth(3 ether);
        vm.prank(admin);
        vm.expectRevert(RoyaltySplitter.CannotRescueWeth.selector);
        royaltySplitter.rescueToken(IERC20(address(weth)));

        royaltySplitter.distribute(); // still splits trustlessly
        assertEq(weth.balanceOf(address(royaltySplitter)), 0);
        assertGt(burnEngine.pendingEth(), 0);
    }
}

/// @notice Griefing admin: a contract royalty-admin that reverts on receive. The splitter must
///         still pay the two protocol sinks in full, accrue the admin third to pendingAdmin,
///         never re-split it, and recover it on withdrawAdmin once the admin can receive — with
///         no ETH ever stranded. Uses the REAL BurnEngine/BountyEngine from the fixture, with a
///         dedicated splitter whose admin is the reverting contract.
contract RoyaltyGriefingAdminTest is IntegrationBase {
    RevertingAdmin internal grieferAdmin;
    RoyaltySplitter internal griefSplitter;

    function setUp() public {
        _deployProtocol();
        grieferAdmin = new RevertingAdmin();
        // Same real protocol sinks; admin is the reverting contract (not accepting yet).
        griefSplitter = new RoyaltySplitter(address(burnEngine), address(bounty), address(grieferAdmin), address(weth));
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(griefSplitter).call{value: amount}("");
        assertTrue(ok);
    }

    function test_griefingAdmin_sinksPaid_sliceAccrues_recovered_noStranding() public {
        uint256 burnBefore = burnEngine.pendingEth();
        uint256 bountyBefore = bounty.freeTreasury();

        // 1) Distribute with a reverting admin: burn + bounty paid in full, admin third held.
        _fund(9 ether);
        griefSplitter.distribute();
        assertEq(burnEngine.pendingEth() - burnBefore, 3 ether, "burn paid despite griefing admin");
        assertEq(bounty.freeTreasury() - bountyBefore, 3 ether, "bounty paid despite griefing admin");
        assertEq(griefSplitter.pendingAdmin(), 3 ether, "admin third accrued for later pull");
        assertEq(grieferAdmin.received(), 0);
        // No ETH stranded beyond exactly the pending admin slice.
        assertEq(address(griefSplitter).balance, griefSplitter.pendingAdmin(), "balance == pendingAdmin");

        // 2) A second distribution must NOT re-split the stuck slice (no double-count).
        _fund(9 ether);
        griefSplitter.distribute();
        assertEq(burnEngine.pendingEth() - burnBefore, 6 ether, "second round split only the NEW 9 ETH");
        assertEq(bounty.freeTreasury() - bountyBefore, 6 ether);
        assertEq(griefSplitter.pendingAdmin(), 6 ether, "two admin thirds accrued");
        assertEq(address(griefSplitter).balance, 6 ether, "exactly the two stuck slices remain");

        // 3) Once the admin can receive, withdrawAdmin recovers everything — nothing stranded.
        grieferAdmin.setAccept(true);
        griefSplitter.withdrawAdmin();
        assertEq(grieferAdmin.received(), 6 ether, "admin recovered both held slices");
        assertEq(griefSplitter.pendingAdmin(), 0);
        assertEq(address(griefSplitter).balance, 0, "no ETH stranded after recovery");
    }
}

/// @notice Downstream effect — the point of the feature: royalty income actually FEEDS the
///         protocol. On a full sealed, trading stack: a royalty distribution raises the
///         BurnEngine's pending ETH so a real buyback burns more WORD, and raises the
///         BountyEngine free treasury so a higher prize tier becomes affordable.
contract RoyaltyDownstreamTest is IntegrationBase {
    function setUp() public {
        _deployProtocol();
        _mintOutCollection();
        _syncRegistry();
        _seedPool();
        _seal();
        _enableTrading();
        _expireGuard();
        _addLaunchTemplates();
    }

    function test_royaltyFeedsBuybackAndBountyTier() public {
        // Simulate a marketplace royalty: read royaltyInfo for a 30-ETH sale, pay it in.
        (address receiver, uint256 royalty) = bank.royaltyInfo(1, 30 ether);
        assertEq(receiver, address(royaltySplitter));
        assertEq(royalty, 0.9 ether); // 3%
        vm.deal(address(this), royalty);
        (bool ok,) = address(royaltySplitter).call{value: royalty}("");
        assertTrue(ok);

        // Before distribute: the top 0.5-ETH bounty tier is NOT affordable (no fees flushed).
        uint256 topTierCost = 0.5 ether + (0.5 ether * 200) / 10_000; // tier + 2% reveal reward
        assertLt(bounty.freeTreasury(), topTierCost, "top tier not yet affordable");
        uint256 burnPendingBefore = burnEngine.pendingEth();

        royaltySplitter.distribute();

        // Burn third (0.3 ETH) raised the BurnEngine's spendable ETH.
        assertEq(burnEngine.pendingEth(), burnPendingBefore + 0.3 ether, "burn third fed the BurnEngine");
        // Bounty third (0.3 ETH) — combine with a small top-up proving the tier threshold the
        // royalty helped cross. Here the 0.3 alone already clears the launch min tier; add two
        // more royalty rounds to clear the TOP tier deterministically.
        vm.deal(address(this), 1.8 ether);
        (ok,) = address(royaltySplitter).call{value: 1.8 ether}("");
        assertTrue(ok);
        royaltySplitter.distribute();
        assertGe(bounty.freeTreasury(), topTierCost, "royalties made the top bounty tier affordable");

        // The burn third actually burns more WORD: a real buyback consumes the royalty-fed ETH.
        uint256 burnedBefore = token.burnedTotal();
        uint256 enginePending = burnEngine.pendingEth();
        assertGt(enginePending, 0);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        burnEngine.executeBuyback(1 ether);
        assertGt(token.burnedTotal(), burnedBefore, "royalty-fed buyback burned WORD");
        assertLt(burnEngine.pendingEth(), enginePending, "buyback spent the royalty-fed ETH");
    }
}
