// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EligibilityController} from "../../../../src/v3/EligibilityController.sol";
import {RewardDistributor} from "../../../../src/v3/RewardDistributor.sol";
import {RewardPayoutVault} from "../../../../src/v3/RewardPayoutVault.sol";
import {CovBTaxToken, CovBStatus} from "./CovBHelpers.sol";

/// @notice Configurable IRewardPayoutSource: fixed per-account debt, optional gas burn, optional short transfer.
contract CovBPayoutSource {
    CovBTaxToken public token;
    address public payout;
    address[] public people;
    mapping(address => uint256) public owed;
    uint256 public burn;
    uint256 public shortBy;
    uint256 public revision = 1;

    constructor(CovBTaxToken t) {
        token = t;
    }

    function configurePayout(address p) external {
        payout = p;
    }

    function add(address a) external {
        people.push(a);
    }

    function fund(address a, uint256 n) external {
        owed[a] += n;
        token.mint(address(this), n);
        revision++;
    }

    function setBurn(uint256 g) external {
        burn = g;
    }

    function setShort(uint256 n) external {
        shortBy = n;
    }

    function participantAt(uint256 i) external view returns (address) {
        return people[i];
    }

    function queueSnapshot(uint256) external view returns (uint256, uint256) {
        return (people.length, revision);
    }

    function queueAsset(uint256) external view returns (address) {
        return address(token);
    }

    function poolId() external view returns (bytes32) {
        return bytes32(uint256(uint160(address(this))));
    }

    function settlementKind() external pure returns (uint8) {
        return 1;
    }

    function deliveryAllowed(address, address) external pure returns (bool) {
        return true;
    }

    function stageCredit(address a, uint256[] calldata, address) external returns (uint256 amount) {
        require(msg.sender == payout, "payout");
        if (burn != 0) {
            uint256 g = gasleft();
            while (g - gasleft() < burn) {}
        }
        amount = owed[a];
        owed[a] = 0;
        if (amount > shortBy) token.transfer(payout, amount - shortBy);
    }
}

/// @notice Price oracle stand-in for RewardDistributor.attempt.
contract CovBPrice {
    uint256 public price = 1 ether;

    function priceUSD18(address) external view returns (uint256, uint256) {
        return (price, block.timestamp);
    }
}

abstract contract CovBPayoutBase is Test {
    EligibilityController controller;
    CovBStatus status;
    CovBTaxToken token;
    CovBPayoutSource source;
    RewardPayoutVault payout;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public virtual {
        vm.warp(10 days + 1 hours);
        controller = new EligibilityController(address(this));
        status = new CovBStatus();
        token = new CovBTaxToken();
        source = new CovBPayoutSource(token);
        address[] memory list = new address[](1);
        list[0] = address(source);
        payout = new RewardPayoutVault(list, controller);
        source.configurePayout(address(payout));
        source.add(alice);
        source.add(bob);
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _assets() internal view returns (address[] memory a) {
        a = new address[](1);
        a[0] = address(token);
    }

    /// Switch to A mode with `token` bound as asset 0; nobody is eligible until status.set.
    function _enableA() internal {
        controller.bindAsset(address(token), 0);
        controller.scheduleEnable(address(status), status.POLICY(), 13);
        vm.warp(13 days + 1 hours);
    }
}

contract CovBRewardPayoutVaultTest is CovBPayoutBase {
    /// line 40: constructor requires a controller with code (both arms).
    function testConstructorRequiresControllerCode() public {
        vm.expectRevert(bytes("controller"));
        new RewardPayoutVault(new address[](0), EligibilityController(address(0x1234)));
        RewardPayoutVault p = new RewardPayoutVault(new address[](0), controller);
        assertEq(address(p.controller()), address(controller));
    }

    /// lines 87-88: trusted source, nonzero account, epoch page <= 20.
    function testStageCreditGuards() public {
        vm.expectRevert(bytes("source/account"));
        payout.stageCredit(address(0x1234), alice, _one(1), address(token));
        vm.expectRevert(bytes("source/account"));
        payout.stageCredit(address(source), address(0), _one(1), address(token));
        vm.expectRevert(bytes("epoch page"));
        payout.stageCredit(address(source), alice, new uint256[](21), address(token));
        source.fund(alice, 7);
        assertEq(payout.stageCredit(address(source), alice, new uint256[](20), address(token)), 7);
        assertEq(payout.readyRaw(alice, address(token)), 7);
    }

    /// line 91: a source that reports more than it transfers cannot create unbacked debt.
    function testStageCreditRequiresExactDelta() public {
        source.fund(alice, 10 ether);
        source.setShort(1);
        vm.expectRevert(bytes("stage delta"));
        payout.stageCredit(address(source), alice, _one(1), address(token));
        assertEq(payout.readyRaw(alice, address(token)), 0);
        assertEq(payout.totalLiability(address(token)), 0);
        assertEq(token.balanceOf(address(payout)), 0);
    }

    /// lines 98, 108: claim page <= 4; claimOne is self-call only.
    function testClaimPageAndSelfOnlyClaimOne() public {
        vm.expectRevert(bytes("asset page"));
        payout.claim(new address[](5));
        vm.expectRevert(bytes("self"));
        payout.claimOne(alice, address(token));
        source.fund(alice, 3);
        payout.stageCredit(address(source), alice, _one(1), address(token));
        vm.prank(alice);
        payout.claim(_assets());
        assertEq(token.balanceOf(alice), 3);
    }

    /// line 125: payment requires stock eligibility in A mode; debt is retained until eligible.
    function testPayRequiresEligibility() public {
        source.fund(alice, 5 ether);
        payout.stageCredit(address(source), alice, _one(1), address(token));
        _enableA();
        vm.prank(alice);
        vm.expectRevert(bytes("eligibility"));
        payout.claimFor(alice, address(token));
        assertEq(payout.readyRaw(alice, address(token)), 5 ether);
        assertEq(token.balanceOf(alice), 0);
        status.set(alice, true);
        vm.prank(alice);
        assertEq(payout.claimFor(alice, address(token)), 5 ether);
        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(payout.paidTotal(alice, address(token)), 5 ether);
        assertEq(payout.totalLiability(address(token)), 0);
    }

    /// line 132: a lossy transfer to the recipient reverts; the debt stays intact.
    function testPayoutRequiresExactDelta() public {
        source.fund(alice, 5 ether);
        payout.stageCredit(address(source), alice, _one(1), address(token));
        token.setTaxTo(alice, true);
        vm.prank(alice);
        vm.expectRevert(bytes("payout delta"));
        payout.claimFor(alice, address(token));
        assertEq(payout.readyRaw(alice, address(token)), 5 ether);
        assertEq(token.balanceOf(address(payout)), 5 ether);
    }
}

contract CovBRewardDistributorTest is CovBPayoutBase {
    RewardDistributor distributor;
    CovBPrice price;

    function setUp() public override {
        super.setUp();
        price = new CovBPrice();
        distributor = new RewardDistributor(payout, address(price));
        payout.configureDistributor(address(distributor));
    }

    /// lines 87-88: queue only for a trusted source and its declared nonzero asset.
    function testOpenQueueGuards() public {
        CovBPayoutSource other = new CovBPayoutSource(token);
        vm.expectRevert(bytes("source"));
        distributor.openQueue(address(other), 1, address(token));
        vm.expectRevert(bytes("queue asset"));
        distributor.openQueue(address(source), 1, address(0));
        vm.expectRevert(bytes("queue asset"));
        distributor.openQueue(address(source), 1, address(0x1234));
        assertEq(distributor.openQueue(address(source), 1, address(token)), 0);
    }

    /// lines 142-158: staged accounts are paid (Paid), small ones skipped (SkippedSmall), and a delivery
    /// failure is isolated (DeliveryBlocked) while the cursor still advances and debt is retained.
    function testBatchPaidSkippedAndDeliveryBlocked() public {
        source.fund(alice, 10 ether);
        source.fund(bob, 1); // $1e-18 < $2 minimum
        uint256 q = distributor.openQueue(address(source), 1, address(token));
        distributor.batchDistribute(q, 32, 1, 300000);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(payout.readyRaw(bob, address(token)), 1);
        (RewardDistributor.Queue memory queue,,) = distributor.previewBatch(q);
        assertEq(queue.cursor, 2);

        // New revision, A mode, alice not eligible: claimFor reverts inside attempt -> DeliveryBlocked.
        source.fund(alice, 4 ether);
        _enableA();
        uint256 q2 = distributor.openQueue(address(source), 1, address(token));
        vm.expectEmit(true, true, false, true, address(distributor));
        emit RewardDistributor.AccountProcessed(
            q2, alice, RewardDistributor.Outcome.DeliveryBlocked, abi.encodeWithSignature("Error(string)", "eligibility")
        );
        distributor.batchDistribute(q2, 32, 1, 300000);
        assertEq(payout.readyRaw(alice, address(token)), 4 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        (queue,,) = distributor.previewBatch(q2);
        assertEq(queue.cursor, 2);
    }

    /// line 140: the in-loop gas guard stops the page after an expensive account; progress is kept.
    function testBatchStopsWhenGasRunsLowMidPage() public {
        source.fund(alice, 10 ether);
        source.fund(bob, 10 ether);
        source.setBurn(120000);
        uint256 q = distributor.openQueue(address(source), 1, address(token));
        distributor.batchDistribute{gas: 790000}(q, 32, 1, 300000);
        (RewardDistributor.Queue memory queue, uint256 nextScan,) = distributor.previewBatch(q);
        assertEq(queue.cursor, 1, "must stop after the first account");
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(nextScan, block.timestamp + 15 minutes);
    }

    /// line 195: trusted source and page bounds.
    function testClaimPageAndSource() public {
        vm.expectRevert(bytes("claim page/source"));
        distributor.claim(address(0x1234), new uint256[](0), _assets());
        vm.expectRevert(bytes("claim page/source"));
        distributor.claim(address(source), new uint256[](21), _assets());
        vm.expectRevert(bytes("claim page/source"));
        distributor.claim(address(source), new uint256[](0), new address[](5));
    }

    /// line 198: up-front gas check, sized by whether the first call is a stage (2M) or a payment (500k).
    function testClaimGasPrecheck() public {
        source.fund(alice, 3 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("claim gas"));
        distributor.claim{gas: 2_000_000}(address(source), _one(1), _assets());
        vm.prank(alice);
        vm.expectRevert(bytes("claim gas"));
        distributor.claim{gas: 600_000}(address(source), new uint256[](0), _assets());
        assertEq(payout.readyRaw(alice, address(token)), 0);
        payout.stageCredit(address(source), alice, _one(1), address(token));
        vm.prank(alice);
        distributor.claim{gas: 800_000}(address(source), new uint256[](0), _assets());
        assertEq(token.balanceOf(alice), 3 ether);
    }

    /// line 215: staging that consumes most of the gas stops before payment; staged debt is kept.
    function testClaimStopsBeforePaymentWhenStagingDrainsGas() public {
        source.fund(alice, 3 ether);
        source.setBurn(1_700_000);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit RewardDistributor.ClaimPageStopped(address(source), alice, address(token), 0, 1);
        vm.prank(alice);
        distributor.claim{gas: 2_300_000}(address(source), _one(1), _assets());
        assertEq(payout.readyRaw(alice, address(token)), 3 ether);
        assertEq(token.balanceOf(alice), 0);
    }

    /// line 220: a failing payment emits DeliveryBlocked and keeps the debt.
    function testClaimDeliveryBlockedKeepsDebt() public {
        source.fund(alice, 3 ether);
        _enableA();
        vm.expectEmit(true, true, false, true, address(distributor));
        emit RewardDistributor.AccountProcessed(
            type(uint256).max,
            alice,
            RewardDistributor.Outcome.DeliveryBlocked,
            abi.encodeWithSignature("Error(string)", "eligibility")
        );
        vm.prank(alice);
        distributor.claim(address(source), _one(1), _assets());
        assertEq(payout.readyRaw(alice, address(token)), 3 ether);
        assertEq(token.balanceOf(alice), 0);
    }

    /// line 228: attempt is self-call only (else anyone could force-push below threshold).
    function testAttemptSelfOnly() public {
        vm.expectRevert(bytes("self"));
        distributor.attempt(alice, address(token));
    }
}
