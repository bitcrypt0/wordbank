// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";

import {RewardsDistributor} from "../../src/RewardsDistributor.sol";
import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";
import {MockFeeSource} from "../mocks/MockFeeSource.sol";
import {MockWordBank} from "../mocks/MockWordBank.sol";

// ─────────────────────────────────── test helpers ───────────────────────────────────────

/// @dev Minimal BountyEngine stand-in: just the payable deposit() the dust sweep calls.
contract BountySink {
    uint256 public depositCount;

    function deposit() external payable {
        depositCount += 1;
    }
}

/// @dev Token owner with no payable path — any ETH payout to it must revert the operation.
contract RejectingReceiver {
    function doClaim(RewardsDistributor dist, uint256[] calldata ids) external {
        dist.claimRewards(ids);
    }
}

/// @dev Token owner that re-enters claimRewards from its receive() and records whether the
///      inner call got past the reentrancy guard.
contract ReentrantClaimer {
    RewardsDistributor public immutable dist;
    uint256 public tokenId;
    bool public armed;
    bool public innerSucceeded;

    constructor(RewardsDistributor dist_) {
        dist = dist_;
    }

    function doClaim(uint256 tokenId_) external {
        tokenId = tokenId_;
        armed = true;
        dist.claimRewards(_ids());
        armed = false;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            (bool ok,) = address(dist).call(abi.encodeCall(dist.claimRewards, (_ids())));
            innerSucceeded = ok;
        }
    }

    function _ids() internal view returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }
}

/// @dev Forces ETH onto a target with no receive() via constructor-selfdestruct.
contract ForceSend {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

// ──────────────────────────────────── unit + fuzz ───────────────────────────────────────

contract RewardsDistributorTest is Test {
    uint256 internal constant ACC = 1e18;

    MockWordBank internal bank;
    BountySink internal bounty;
    RewardsDistributor internal dist;
    MockFeeSource internal feeSource;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    // fuzz reference model (storage so it resets per run via setUp snapshotting)
    uint256 internal modelAcc;
    uint256 internal modelBuffer;
    mapping(uint256 => uint256) internal modelDebt;
    mapping(uint256 => uint256) internal expectedPaid;
    mapping(uint256 => bool) internal modelClosed;
    uint256[] internal aliveIds;
    uint256 internal nextId = 1;

    function setUp() public {
        bank = new MockWordBank();
        bounty = new BountySink();
        dist = new RewardsDistributor(address(bank), address(bounty));
        bank.setDistributor(address(dist));
        feeSource = new MockFeeSource(dist);
    }

    // ───────────────────────────────── constructor ──────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(address(dist.wordBank()), address(bank));
        assertEq(dist.bountyTreasury(), address(bounty));
    }

    function test_constructor_zeroAddressReverts() public {
        vm.expectRevert(RewardsDistributor.ZeroAddress.selector);
        new RewardsDistributor(address(0), address(bounty));
        vm.expectRevert(RewardsDistributor.ZeroAddress.selector);
        new RewardsDistributor(address(bank), address(0));
    }

    // ─────────────────────────────────── deposit ────────────────────────────────────────

    function test_deposit_accruesEquallyAcrossAlive() public {
        bank.mint(1, alice);
        bank.mint(2, bob);

        vm.expectEmit(address(dist));
        emit IRewardsDistributor.Deposited(address(this), 1 ether, (1 ether * ACC) / 2);
        dist.deposit{value: 1 ether}();

        assertEq(dist.accRewardPerNFT(), (1 ether * ACC) / 2);
        assertEq(dist.pendingRewards(1), 0.5 ether);
        assertEq(dist.pendingRewards(2), 0.5 ether);
        assertEq(dist.owedScaled(), 1 ether * ACC);
    }

    function test_deposit_multipleAccumulate() public {
        bank.mint(1, alice);
        dist.deposit{value: 1 ether}();
        dist.deposit{value: 3 ether}();
        assertEq(dist.pendingRewards(1), 4 ether);
    }

    function test_deposit_zeroValueNoBufferReverts() public {
        bank.mint(1, alice);
        vm.expectRevert(RewardsDistributor.ZeroDeposit.selector);
        dist.deposit{value: 0}();
    }

    function test_deposit_isPermissionless() public {
        bank.mint(1, alice);
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        dist.deposit{value: 1 ether}(); // donation
        assertEq(dist.pendingRewards(1), 1 ether);
    }

    function test_deposit_viaFeeSourceFlush() public {
        bank.mint(1, alice);
        vm.deal(address(feeSource), 2 ether);
        feeSource.flush();
        assertEq(dist.pendingRewards(1), 2 ether);
    }

    // ───────────────────────── deposit: totalAlive == 0 (deferral) ──────────────────────

    function test_deposit_zeroAlive_defersInsteadOfReverting() public {
        vm.expectEmit(address(dist));
        emit RewardsDistributor.DepositDeferred(address(this), 1 ether, 1 ether);
        dist.deposit{value: 1 ether}();

        assertEq(dist.accRewardPerNFT(), 0);
        assertEq(dist.pendingUndistributed(), 1 ether);
        assertEq(address(dist).balance, 1 ether);
    }

    function test_deposit_deferredBufferAccumulates() public {
        dist.deposit{value: 1 ether}();
        dist.deposit{value: 2 ether}();
        assertEq(dist.pendingUndistributed(), 3 ether);
    }

    function test_deposit_bufferFoldsIntoNextLiveDeposit() public {
        dist.deposit{value: 1 ether}();
        bank.mint(1, alice);
        dist.deposit{value: 2 ether}();
        assertEq(dist.pendingUndistributed(), 0);
        assertEq(dist.pendingRewards(1), 3 ether);
    }

    function test_deposit_zeroValueKickDistributesBuffer() public {
        dist.deposit{value: 5 ether}();
        bank.mint(1, alice);
        bank.mint(2, bob);

        dist.deposit{value: 0}(); // permissionless kick
        assertEq(dist.pendingUndistributed(), 0);
        assertEq(dist.pendingRewards(1), 2.5 ether);
        assertEq(dist.pendingRewards(2), 2.5 ether);
    }

    function test_deposit_deferredFundsOnlyAccrueToTokensAliveAtFold() public {
        // protocol-lifetime edge: last word unbinds, fees keep arriving, a new... no — ids
        // never remint; instead a later REGISTERED token absorbs the deferred pot.
        bank.mint(1, alice);
        dist.deposit{value: 1 ether}();
        bank.unbind(1); // alice settled 1 ether; alive == 0 now
        dist.deposit{value: 2 ether}(); // deferred
        bank.mint(2, bob);
        dist.deposit{value: 0}(); // fold

        assertEq(dist.pendingRewards(2), 2 ether);
        assertEq(dist.pendingRewards(1), 0); // closed forever
        assertEq(alice.balance, 1 ether);
    }

    function test_deposit_bufferIsNotSweepableAsDust() public {
        dist.deposit{value: 1 ether}();
        vm.expectRevert(RewardsDistributor.NoDust.selector);
        dist.sweepDust();
    }

    // ─────────────────────────────────── register ───────────────────────────────────────

    function test_register_onlyWordBank() public {
        vm.expectRevert(RewardsDistributor.NotWordBank.selector);
        dist.register(1);
    }

    function test_register_checkpointsDebt_midStreamMintClaimsNothing() public {
        bank.mint(1, alice);
        dist.deposit{value: 7 ether}();

        bank.mint(2, bob); // mid-stream mint
        assertEq(dist.rewardDebt(2), dist.accRewardPerNFT());
        assertEq(dist.pendingRewards(2), 0);

        dist.deposit{value: 4 ether}();
        assertEq(dist.pendingRewards(1), 9 ether);
        assertEq(dist.pendingRewards(2), 2 ether);
    }

    function test_register_emitsEvent() public {
        vm.expectEmit(address(dist));
        emit IRewardsDistributor.Registered(42);
        vm.prank(address(bank));
        dist.register(42);
    }

    function test_register_reRegistrationReverts() public {
        bank.mint(1, alice);
        vm.expectRevert(abi.encodeWithSelector(RewardsDistributor.AlreadyRegistered.selector, 1));
        vm.prank(address(bank));
        dist.register(1);
    }

    function test_register_closedIdReverts() public {
        bank.mint(1, alice);
        bank.unbind(1);
        vm.expectRevert(abi.encodeWithSelector(RewardsDistributor.TokenClosed.selector, 1));
        vm.prank(address(bank));
        dist.register(1);
    }

    // ───────────────────────────────── pendingRewards ───────────────────────────────────

    function test_pendingRewards_zeroForUnregistered() public view {
        assertEq(dist.pendingRewards(999), 0);
    }

    function test_pendingRewards_zeroForClosed() public {
        bank.mint(1, alice);
        dist.deposit{value: 1 ether}();
        bank.unbind(1);
        assertEq(dist.pendingRewards(1), 0);
        bank.mint(2, bob);
        dist.deposit{value: 1 ether}(); // accrues to the survivor only
        assertEq(dist.pendingRewards(1), 0); // closed ids never accrue again
        assertEq(dist.pendingRewards(2), 1 ether);
    }

    // ──────────────────────────────────── claim ─────────────────────────────────────────

    function test_claim_paysExactPendingAndAdvancesDebt() public {
        bank.mint(1, alice);
        bank.mint(2, bob);
        dist.deposit{value: 3 ether}();

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectEmit(address(dist));
        emit IRewardsDistributor.Claimed(1, alice, 1.5 ether);
        vm.prank(alice);
        dist.claimRewards(ids);

        assertEq(alice.balance, 1.5 ether);
        assertEq(dist.pendingRewards(1), 0);
        assertEq(dist.rewardDebt(1), dist.accRewardPerNFT());
        // bob untouched
        assertEq(dist.pendingRewards(2), 1.5 ether);
    }

    function test_claim_batchPaysSumInOneTransfer() public {
        bank.mint(1, alice);
        bank.mint(2, alice);
        bank.mint(3, alice);
        dist.deposit{value: 9 ether}();

        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        vm.prank(alice);
        dist.claimRewards(ids);
        assertEq(alice.balance, 9 ether);
    }

    function test_claim_zeroPendingIsANoOpNotARevert() public {
        bank.mint(1, alice);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(alice);
        dist.claimRewards(ids);
        assertEq(alice.balance, 0);
    }

    function test_claim_duplicateIdInBatchPaysOnce() public {
        bank.mint(1, alice);
        bank.mint(2, bob);
        dist.deposit{value: 2 ether}();

        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 1;
        ids[2] = 1;
        vm.prank(alice);
        dist.claimRewards(ids);
        assertEq(alice.balance, 1 ether); // not 3
    }

    function test_claim_doubleClaimPaysZeroSecondTime() public {
        bank.mint(1, alice);
        dist.deposit{value: 1 ether}();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.startPrank(alice);
        dist.claimRewards(ids);
        dist.claimRewards(ids);
        vm.stopPrank();
        assertEq(alice.balance, 1 ether);
    }

    function test_claim_nonOwnerRevertsWholeBatch() public {
        bank.mint(1, alice);
        bank.mint(2, bob);
        dist.deposit{value: 2 ether}();

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2; // bob's — must poison the whole batch
        vm.expectRevert(abi.encodeWithSelector(RewardsDistributor.NotTokenOwner.selector, 2));
        vm.prank(alice);
        dist.claimRewards(ids);
        assertEq(dist.pendingRewards(1), 1 ether); // nothing paid
    }

    function test_claim_closedIdRevertsWholeBatch() public {
        bank.mint(1, alice);
        bank.mint(2, alice);
        dist.deposit{value: 2 ether}();
        bank.unbind(2);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        vm.expectRevert(abi.encodeWithSelector(RewardsDistributor.TokenClosed.selector, 2));
        vm.prank(alice);
        dist.claimRewards(ids);
    }

    function test_claim_unregisteredIdReverts() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 777;
        vm.expectRevert(abi.encodeWithSelector(RewardsDistributor.NotRegistered.selector, 777));
        dist.claimRewards(ids);
    }

    function test_claim_emptyBatchReverts() public {
        vm.expectRevert(RewardsDistributor.EmptyClaim.selector);
        dist.claimRewards(new uint256[](0));
    }

    function test_claim_rejectingReceiverRevertsBatch() public {
        RejectingReceiver rejector = new RejectingReceiver();
        bank.mint(1, address(rejector));
        dist.deposit{value: 1 ether}();

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(RewardsDistributor.EthTransferFailed.selector, address(rejector), 1 ether)
        );
        rejector.doClaim(dist, ids);
    }

    function test_claim_reentrancyBlockedAndNoDoublePay() public {
        ReentrantClaimer attacker = new ReentrantClaimer(dist);
        bank.mint(1, address(attacker));
        dist.deposit{value: 1 ether}();

        attacker.doClaim(1);

        assertFalse(attacker.innerSucceeded(), "reentrant claim must be blocked");
        assertEq(address(attacker).balance, 1 ether, "paid exactly once");
        assertEq(dist.pendingRewards(1), 0);
    }

    // ─────────────────────────── rewards travel with the NFT ────────────────────────────

    function test_transfer_pendingTravelsWithToken() public {
        bank.mint(1, alice);
        dist.deposit{value: 2 ether}();

        bank.transfer(1, bob);
        assertEq(dist.pendingRewards(1), 2 ether, "transfer must not touch reward state");

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        // old owner gets nothing post-transfer
        vm.expectRevert(abi.encodeWithSelector(RewardsDistributor.NotTokenOwner.selector, 1));
        vm.prank(alice);
        dist.claimRewards(ids);
        // new owner claims the full pending
        vm.prank(bob);
        dist.claimRewards(ids);
        assertEq(bob.balance, 2 ether);
        assertEq(alice.balance, 0);
    }

    // ──────────────────────────────── settleAndClose ────────────────────────────────────

    function test_settleAndClose_onlyWordBank() public {
        bank.mint(1, alice);
        vm.expectRevert(RewardsDistributor.NotWordBank.selector);
        dist.settleAndClose(1, alice);
    }

    function test_settleAndClose_zeroRecipientReverts() public {
        bank.mint(1, alice);
        vm.expectRevert(RewardsDistributor.ZeroAddress.selector);
        vm.prank(address(bank));
        dist.settleAndClose(1, address(0));
    }

    function test_settleAndClose_paysExactPendingToBurner() public {
        bank.mint(1, alice);
        bank.mint(2, bob);
        dist.deposit{value: 4 ether}();

        vm.expectEmit(address(dist));
        emit IRewardsDistributor.SettledAndClosed(1, alice, 2 ether);
        bank.unbind(1);

        assertEq(alice.balance, 2 ether);
        assertEq(dist.pendingRewards(1), 0);
        assertEq(uint8(dist.statusOf(1)), uint8(RewardsDistributor.TokenStatus.Closed));
    }

    function test_settleAndClose_zeroPendingStillCloses() public {
        bank.mint(1, alice);
        bank.unbind(1);
        assertEq(uint8(dist.statusOf(1)), uint8(RewardsDistributor.TokenStatus.Closed));
        assertEq(alice.balance, 0);
    }

    function test_settleAndClose_zeroPendingWorksForContractWithoutReceive() public {
        // a holder that cannot receive ETH can still unbind while pending == 0
        RejectingReceiver rejector = new RejectingReceiver();
        bank.mint(1, address(rejector));
        bank.unbind(1);
        assertEq(uint8(dist.statusOf(1)), uint8(RewardsDistributor.TokenStatus.Closed));
    }

    function test_settleAndClose_rejectingReceiverRevertsUnbind() public {
        RejectingReceiver rejector = new RejectingReceiver();
        bank.mint(1, address(rejector));
        dist.deposit{value: 1 ether}();
        vm.expectRevert(
            abi.encodeWithSelector(RewardsDistributor.EthTransferFailed.selector, address(rejector), 1 ether)
        );
        bank.unbind(1);
    }

    function test_settleAndClose_secondSettleReverts() public {
        bank.mint(1, alice);
        bank.unbind(1);
        vm.expectRevert(abi.encodeWithSelector(RewardsDistributor.TokenClosed.selector, 1));
        vm.prank(address(bank));
        dist.settleAndClose(1, alice);
    }

    function test_settleAndClose_unregisteredReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RewardsDistributor.NotRegistered.selector, 1));
        vm.prank(address(bank));
        dist.settleAndClose(1, alice);
    }

    /// @dev The settle-before-decrement ordering test from the charter: the burned token
    ///      collects its full share of everything deposited up to the burn; deposits after
    ///      the burn accrue only to survivors.
    function test_settleOrdering_depositAfterSettleAccruesOnlyToSurvivors() public {
        bank.mint(1, alice);
        bank.mint(2, bob);
        bank.mint(3, carol);
        bank.mint(4, dave);
        dist.deposit{value: 4 ether}(); // 1 ether each

        bank.unbind(1); // alice force-settled with her full 1 ether share
        assertEq(alice.balance, 1 ether);

        dist.deposit{value: 3 ether}(); // 3 survivors → +1 ether each

        assertEq(dist.pendingRewards(1), 0);
        assertEq(dist.pendingRewards(2), 2 ether);
        assertEq(dist.pendingRewards(3), 2 ether);
        assertEq(dist.pendingRewards(4), 2 ether);

        // and the books still cover everything
        assertEq(address(dist).balance, 6 ether);
        assertEq(dist.owedScaled() / ACC, 6 ether);
    }

    // ─────────────────────────────────── dust sweep ─────────────────────────────────────

    function test_sweepDust_revertsWhenNothingProvable() public {
        bank.mint(1, alice);
        dist.deposit{value: 1 ether}();
        vm.expectRevert(RewardsDistributor.NoDust.selector);
        dist.sweepDust();
    }

    function test_sweepDust_sweepsForcedEthWithoutTouchingEntitlements() public {
        bank.mint(1, alice);
        bank.mint(2, bob);
        dist.deposit{value: 2 ether}();

        new ForceSend{value: 0.3 ether}(payable(address(dist))); // un-accounted ETH

        vm.expectEmit(address(dist));
        emit IRewardsDistributor.DustSwept(address(bounty), 0.3 ether);
        dist.sweepDust();

        assertEq(address(bounty).balance, 0.3 ether);
        assertEq(bounty.depositCount(), 1);

        // entitlements remain fully claimable
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(alice);
        dist.claimRewards(ids);
        ids[0] = 2;
        vm.prank(bob);
        dist.claimRewards(ids);
        assertEq(alice.balance, 1 ether);
        assertEq(bob.balance, 1 ether);
    }

    /// @dev Charter checklist: dust at 10,000 shares over many uneven deposits is bounded
    ///      and sweepable without touching entitlements.
    function test_sweepDust_tenThousandShares_unevenDeposits() public {
        address whale = makeAddr("whale");
        uint256 n = 10_000;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            ids[i] = i + 1;
            bank.mint(i + 1, whale);
        }

        uint256 deposited;
        uint256 nDeposits = 12;
        for (uint256 k = 0; k < nDeposits; ++k) {
            // deliberately ragged amounts: huge primes of wei, never multiples of 10,000
            uint256 amount = (uint256(keccak256(abi.encode("dust", k))) % 50 ether) + 1;
            vm.deal(address(this), amount);
            dist.deposit{value: amount}();
            deposited += amount;
        }

        uint256 sumPending = n * dist.pendingRewards(1); // all shares identical here
        vm.prank(whale);
        dist.claimRewards(ids);
        assertEq(whale.balance, sumPending, "claims pay exactly the advertised pending");

        // every entitlement is now released; what remains is pure dust
        assertEq(dist.owedScaled(), 0);
        uint256 dust = address(dist).balance;
        assertLe(dust, n + nDeposits, "dust bounded by ~1 wei per share + per deposit");
        assertEq(deposited, sumPending + dust, "conservation: paid + dust == deposited");

        if (dust > 0) {
            dist.sweepDust();
            assertEq(address(dist).balance, 0);
            assertEq(address(bounty).balance, dust);
        }
    }

    // ───────────────────────────────────── fuzz ─────────────────────────────────────────

    /// @dev Charter exactness fuzz: random interleavings of deposit / register (mint) /
    ///      claim / settleAndClose (unbind), checked move-for-move against an independent
    ///      reference model. Every token's lifetime payout must equal the model's sum of
    ///      its per-deposit shares to the wei, and the balance must cover all entitlements
    ///      after every operation.
    function testFuzz_accumulatorExactness(uint256 seed) public {
        uint256 ops = 32;
        for (uint256 i = 0; i < ops; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 100;
            if (op < 35) {
                _modelDeposit(((r >> 16) % 30 ether) + 1);
            } else if (op < 60 && nextId <= 12) {
                _modelMint();
            } else if (op < 80 && aliveIds.length > 0) {
                _modelClaim(aliveIds[(r >> 16) % aliveIds.length]);
            } else if (aliveIds.length > 0) {
                _modelUnbind((r >> 16) % aliveIds.length);
            } else {
                _modelMint();
            }
            _assertModelMatches();
        }

        // drain: claim everything still alive, then verify every token's lifetime payout
        while (aliveIds.length > 0) {
            _modelClaim(aliveIds[aliveIds.length - 1]);
            _modelUnbind(aliveIds.length - 1);
        }
        for (uint256 id = 1; id < nextId; ++id) {
            assertEq(_ownerOfId(id).balance, expectedPaid[id], "lifetime payout exact");
        }
        assertEq(dist.owedScaled(), 0, "all entitlements released");
        // remaining balance is buffer + dust only; dust is bounded by 1 wei per release
        assertLe(address(dist).balance - dist.pendingUndistributed(), 2 * nextId + ops);
    }

    function testFuzz_midStreamMintClaimsNothingFromPriorDeposits(uint96 a1, uint96 a2) public {
        uint256 d1 = bound(uint256(a1), 1, 1000 ether);
        uint256 d2 = bound(uint256(a2), 1, 1000 ether);
        vm.deal(address(this), d1 + d2);

        bank.mint(1, alice);
        dist.deposit{value: d1}();
        bank.mint(2, bob);
        assertEq(dist.pendingRewards(2), 0);

        dist.deposit{value: d2}();
        uint256 per1 = (d1 * ACC) / 1;
        uint256 per2 = (d2 * ACC) / 2;
        assertEq(dist.pendingRewards(1), (per1 + per2) / ACC);
        assertEq(dist.pendingRewards(2), per2 / ACC);
    }

    function testFuzz_singleTokenReceivesEverything(uint96 amount) public {
        uint256 d = bound(uint256(amount), 1, 5000 ether);
        vm.deal(address(this), d);
        bank.mint(1, alice);
        dist.deposit{value: d}();
        assertEq(dist.pendingRewards(1), d); // alive == 1 → zero rounding loss
    }

    function testFuzz_transferWithPending_newOwnerGetsAll(uint96 amount) public {
        uint256 d = bound(uint256(amount), 1, 1000 ether);
        vm.deal(address(this), d);
        bank.mint(1, alice);
        dist.deposit{value: d}();
        uint256 pendingBefore = dist.pendingRewards(1);

        bank.transfer(1, bob);
        assertEq(dist.pendingRewards(1), pendingBefore);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(bob);
        dist.claimRewards(ids);
        assertEq(bob.balance, pendingBefore);
        assertEq(alice.balance, 0);
    }

    function testFuzz_dustBounded(uint256 seed, uint8 tokensRaw, uint8 depositsRaw) public {
        uint256 n = bound(uint256(tokensRaw), 1, 40);
        uint256 k = bound(uint256(depositsRaw), 1, 16);

        address whale = makeAddr("dustWhale");
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            ids[i] = i + 1;
            bank.mint(i + 1, whale);
        }
        for (uint256 j = 0; j < k; ++j) {
            uint256 amount = (uint256(keccak256(abi.encode(seed, j))) % 100 ether) + 1;
            vm.deal(address(this), amount);
            dist.deposit{value: amount}();
        }

        vm.prank(whale);
        dist.claimRewards(ids);

        assertEq(dist.owedScaled(), 0);
        assertLe(address(dist).balance, n + k, "dust bound: <1 wei per share + per deposit");
    }

    // ───────────────────────────── fuzz model internals ─────────────────────────────────

    function _ownerOfId(uint256 id) internal pure returns (address) {
        return address(uint160(0xA11CE0000 + id));
    }

    function _modelDeposit(uint256 amount) internal {
        vm.deal(address(this), amount);
        dist.deposit{value: amount}();

        uint256 total = amount + modelBuffer;
        uint256 alive = aliveIds.length;
        if (alive == 0) {
            modelBuffer = total;
        } else {
            modelBuffer = 0;
            modelAcc += (total * ACC) / alive;
        }
    }

    function _modelMint() internal {
        uint256 id = nextId++;
        bank.mint(id, _ownerOfId(id));
        modelDebt[id] = modelAcc;
        aliveIds.push(id);
    }

    function _modelClaim(uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(_ownerOfId(id));
        dist.claimRewards(ids);

        expectedPaid[id] += (modelAcc - modelDebt[id]) / ACC;
        modelDebt[id] = modelAcc;
    }

    function _modelUnbind(uint256 index) internal {
        uint256 id = aliveIds[index];
        bank.unbind(id);

        expectedPaid[id] += (modelAcc - modelDebt[id]) / ACC;
        modelDebt[id] = modelAcc;
        modelClosed[id] = true;
        aliveIds[index] = aliveIds[aliveIds.length - 1];
        aliveIds.pop();
    }

    function _assertModelMatches() internal view {
        assertEq(dist.accRewardPerNFT(), modelAcc, "accumulator drift");
        assertEq(dist.pendingUndistributed(), modelBuffer, "buffer drift");

        uint256 sumPending;
        for (uint256 i = 0; i < aliveIds.length; ++i) {
            uint256 id = aliveIds[i];
            uint256 expectedPending = (modelAcc - modelDebt[id]) / ACC;
            assertEq(dist.pendingRewards(id), expectedPending, "pending drift");
            sumPending += expectedPending;
        }
        assertGe(address(dist).balance, sumPending + modelBuffer, "balance must cover entitlements");
    }

    receive() external payable {}
}

// ─────────────────────────────────── invariant suite ────────────────────────────────────

/// @dev Random-walk handler. The handler itself owns every minted token so claims need no
///      pranking; it mirrors nothing — the invariants are checked purely against the
///      distributor's own books.
contract DistributorHandler is CommonBase, StdUtils {
    RewardsDistributor public immutable dist;
    MockWordBank public immutable bank;

    uint256[] public allIds;
    uint256[] internal aliveList;
    uint256 internal nextId = 1;

    constructor(RewardsDistributor dist_, MockWordBank bank_) {
        dist = dist_;
        bank = bank_;
    }

    receive() external payable {}

    function allIdsLength() external view returns (uint256) {
        return allIds.length;
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 50 ether);
        vm.deal(address(this), amount);
        dist.deposit{value: amount}();
    }

    function kick() external {
        if (dist.pendingUndistributed() == 0) return;
        dist.deposit{value: 0}();
    }

    function mint() external {
        if (nextId > 100) return;
        uint256 id = nextId++;
        bank.mint(id, address(this));
        allIds.push(id);
        aliveList.push(id);
    }

    function claim(uint256 pick) external {
        if (aliveList.length == 0) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = aliveList[bound(pick, 0, aliveList.length - 1)];
        dist.claimRewards(ids);
    }

    function unbind(uint256 pick) external {
        if (aliveList.length == 0) return;
        uint256 index = bound(pick, 0, aliveList.length - 1);
        bank.unbind(aliveList[index]);
        aliveList[index] = aliveList[aliveList.length - 1];
        aliveList.pop();
    }

    function forceEth(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        vm.deal(address(this), amount);
        new ForceSend{value: amount}(payable(address(dist)));
    }

    function sweep() external {
        uint256 reserved = dist.pendingUndistributed() + (dist.owedScaled() + 1e18 - 1) / 1e18;
        if (address(dist).balance <= reserved) return;
        dist.sweepDust();
    }
}

contract RewardsDistributorInvariantTest is Test {
    MockWordBank internal bank;
    BountySink internal bounty;
    RewardsDistributor internal dist;
    DistributorHandler internal handler;

    function setUp() public {
        bank = new MockWordBank();
        bounty = new BountySink();
        dist = new RewardsDistributor(address(bank), address(bounty));
        bank.setDistributor(address(dist));
        handler = new DistributorHandler(dist, bank);
        targetContract(address(handler));
    }

    /// @dev THE invariant: the contract balance always covers every pending entitlement
    ///      plus the deferred zero-alive buffer.
    function invariant_balanceCoversAllEntitlements() public view {
        uint256 sumPending;
        uint256 n = handler.allIdsLength();
        for (uint256 i = 0; i < n; ++i) {
            sumPending += dist.pendingRewards(handler.allIds(i));
        }
        assertGe(address(dist).balance, sumPending + dist.pendingUndistributed());
    }

    /// @dev The aggregate ledger bounds the per-token views: the floored per-token pendings
    ///      can never sum past the scaled outstanding total the sweep reserves for.
    function invariant_owedScaledCoversSumOfPendings() public view {
        uint256 sumPending;
        uint256 n = handler.allIdsLength();
        for (uint256 i = 0; i < n; ++i) {
            sumPending += dist.pendingRewards(handler.allIds(i));
        }
        assertLe(sumPending, dist.owedScaled() / 1e18);
    }
}
