// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test, Vm} from "forge-std/Test.sol";
import {RewardRoundManager, IRewardEntrySource} from "../../src/v3/RewardRoundManager.sol";
import {RewardVault} from "../../src/v3/RewardVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RoundStock is ERC20 {
    constructor() ERC20("Stock", "STK") {}

    function mint(address to, uint256 n) external {
        _mint(to, n);
    }
    address public taxedSender;

    function setTax(address who) external {
        taxedSender = who;
    }

    function _update(address from, address to, uint256 n) internal override {
        super._update(from, to, n);
        if (from == taxedSender && from != address(0) && n > 0) super._update(from, address(0xDEAD), 1);
    }
}

contract RoundSource is IRewardEntrySource {
    uint256 public lastFeeAt = block.timestamp;
    mapping(uint256 => bool) public closed;
    mapping(address => uint256) public credits;
    address[] public people;

    function setCredit(address who, uint256 n) external {
        if (credits[who] == 0) people.push(who);
        credits[who] = n;
    }

    function sealReward(uint256 epoch, uint8 cohort) external returns (uint256 budget, uint256 total, uint8 kind) {
        require(!closed[epoch]);
        closed[epoch] = true;
        cohort;
        budget = address(this).balance;
        total = 100;
        kind = 0;
        (bool ok,) = msg.sender.call{value: budget}("");
        require(ok);
    }

    function participantAt(uint256 i) external view returns (address) {
        return people[i];
    }

    function participantCount() external view returns (uint256) {
        return people.length;
    }

    function queueSnapshot(uint256) external view returns (uint256, uint256) {
        return (people.length, 1);
    }

    function rewardPolicy(uint256, uint8) external pure returns (bytes32, uint32, bytes32, uint8) {
        return (bytes32("NVDA"), 1, bytes32("price"), 0);
    }

    function creditOf(address who, uint256, uint8) external view returns (uint256) {
        return credits[who];
    }

    function deliveryAllowed(address, address) external pure returns (bool) {
        return true;
    }
    receive() external payable {}
}

contract RoundRegistry {
    struct Route {
        address asset;
        address underlying;
        address hub;
        address adapter;
        bytes32 path;
        uint256 chainId;
        bool enabled;
        uint256 fixedCost18;
    }
    Route internal route;
    uint256 public cost;

    constructor(address asset, address adapter) {
        route = Route(asset, asset, adapter, adapter, bytes32("Relay"), 4663, true, 0);
    }

    function resolve(bytes32, uint32) external view returns (Route memory) {
        Route memory r = route;
        r.fixedCost18 = cost;
        return r;
    }

    function fixedCost(bytes32, uint32) external view returns (uint256) {
        return cost;
    }

    function clearRoute() external {
        delete route;
    }

    function setCost(uint256 n) external {
        cost = n;
    }
}

contract RoundAdapter {
    RoundStock public stock;
    address public vault;
    uint256 public budget;
    bytes32 public order;
    bool public isFunded;
    bool public submitted;
    uint8 public result;
    uint256 public raw;
    uint256 public refund;
    bool public consumed;
    bool public cancelCalled;

    constructor(RoundStock s) {
        stock = s;
    }

    function startFunding(bytes32 id, uint256 b, uint256, uint256, address v, bytes calldata quoteData)
        external
        payable
    {
        require(msg.value == b && quoteData.length != 1);
        order = id;
        budget = b;
        vault = v;
    }

    function funded(bytes32) external view returns (bool) {
        return isFunded;
    }

    function verifyFunding() external {
        isFunded = true;
    }

    function submit(bytes32) external {
        require(isFunded);
        submitted = true;
    }

    function requestCancel(bytes32) external {
        cancelCalled = true;
    }

    function setResult(uint8 r, uint256 n, uint256 f) external {
        result = r;
        raw = n;
        refund = f;
        consumed = false;
    }

    function consumeResult(bytes32, bytes calldata) external returns (uint8, uint256, uint256) {
        require(!consumed);
        if (result == 0) return (0, 0, 0);
        consumed = true;
        if (raw > 0) stock.mint(vault, raw);
        if (refund > 0) {
            (bool ok,) = vault.call{value: refund}("");
            require(ok);
        }
        return (result, raw, refund);
    }
    receive() external payable {}
}

contract RoundCapacity {
    mapping(bytes32 => uint256) public reserved;

    mapping(bytes32 => address) public reservedAsset;

    function reserveFor(bytes32 order, address asset, uint256 budget) external {
        require(reserved[order] == 0);
        reserved[order] = budget;
        reservedAsset[order] = asset;
    }

    mapping(bytes32 => uint256) public finalReleaseCount;

    function releaseFinalized(bytes32 order) external {
        require(reserved[order] != 0, "not reserved");
        reserved[order] = 0;
        ++finalReleaseCount[order];
    }

    function releaseUnsent(bytes32 order) external {
        reserved[order] = 0;
    }

    /// @dev The pre-2026-09-30 $1,000 single-order limit these unit tests were written against.
    function lRun() external pure returns (uint256) {
        return 1000 ether;
    }
}

contract RewardRoundsTest is Test {
    function onRoundFinalized(uint256) external {}

    RewardRoundManager manager;
    RoundSource source;
    RoundStock stock;
    RoundRegistry registry;
    RoundAdapter adapter;
    RoundCapacity capacity;

    function setUp() public {
        stock = new RoundStock();
        adapter = new RoundAdapter(stock);
        registry = new RoundRegistry(address(stock), address(adapter));
        manager = new RewardRoundManager(address(this), address(registry), address(0xBEEF), address(0xFEE));
        capacity = new RoundCapacity();
        manager.configureExecution(address(this), address(capacity));
        source = new RoundSource();
        manager.registerSource(address(source), bytes32("pool"));
        vm.deal(address(source), 200 ether);
    }

    function _reserve() internal returns (uint256 roundId, uint256 entryId) {
        entryId = manager.seal(address(source), 7, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = entryId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200 ether;
        roundId = manager.reserveBatch(ids, amounts, 5, block.timestamp + 1 hours);
    }

    /// @dev r7 (design §12.3): the round is linked to its stock-layer order for the public reports, and the
    ///      capacity reservation carries the route's underlying for the per-asset cap.
    function testRoundLinkedAndAssetReservation() public {
        uint256 entryId = manager.seal(address(source), 7, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = entryId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200 ether;
        vm.recordLogs();
        uint256 r = manager.reserveBatch(ids, amounts, 5, block.timestamp + 1 hours);
        bytes32 order = manager.round(r).orderId;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == RewardRoundManager.RoundLinked.selector) {
                found = true;
                assertEq(uint256(logs[i].topics[1]), r);
                assertEq(logs[i].topics[2], order);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), address(adapter));
                (address asset, address underlying, uint256 budget, uint256 minRaw, uint256 count) =
                    abi.decode(logs[i].data, (address, address, uint256, uint256, uint256));
                assertEq(asset, address(stock));
                assertEq(underlying, address(stock));
                assertEq(budget, 200 ether);
                assertEq(minRaw, 5);
                assertEq(count, 1);
            }
        }
        assertTrue(found, "RoundLinked missing");
        assertEq(capacity.reservedAsset(order), address(stock));
    }

    function testSettlementReleasesCapacityExactlyOnce() public {
        (uint256 r,) = _reserve();
        bytes32 order = manager.round(r).orderId;
        manager.start(r, "");
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        manager.finalize(r, "");
        assertEq(capacity.reserved(order), 200 ether);
        adapter.setResult(1, 11, 0);
        manager.finalize(r, "");
        assertEq(capacity.reserved(order), 0, "settled capacity leaked");
        assertEq(capacity.finalReleaseCount(order), 1);
        vm.expectRevert();
        manager.finalize(r, "");
        assertEq(capacity.finalReleaseCount(order), 1);
    }

    function testZeroFloatFundingBeforeSubmitAndVerifiedReceipt() public {
        (uint256 r, uint256 e) = _reserve();
        manager.start(r, "");
        assertEq(address(manager).balance, 0);
        assertEq(address(adapter).balance, 200 ether);
        assertEq(manager.available(e), 0);
        vm.expectRevert();
        manager.submit(r);
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        adapter.setResult(1, 11, 0);
        manager.finalize(r, "");
        assertEq(manager.delivered(e), 11);
        assertEq(stock.balanceOf(address(manager.vault())), 11);
        vm.expectRevert();
        manager.finalize(r, "");
    }

    function testUntrustedEmptyProofPreservesFundingFundedAndSubmitted() public {
        (uint256 r, uint256 e) = _reserve();
        manager.start(r, "");
        vm.prank(address(0xBAD));
        manager.finalize(r, "");
        assertEq(uint8(manager.round(r).status), uint8(RewardRoundManager.Status.Funding));
        adapter.verifyFunding();
        manager.poke(r);
        vm.prank(address(0xBAD));
        manager.finalize(r, "");
        assertEq(uint8(manager.round(r).status), uint8(RewardRoundManager.Status.Funded));
        manager.submit(r);
        vm.prank(address(0xBAD));
        manager.finalize(r, "");
        assertEq(uint8(manager.round(r).status), uint8(RewardRoundManager.Status.Submitted));
        assertEq(manager.pending(e), 200 ether);
        assertEq(capacity.reserved(manager.round(r).orderId), 200 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        manager.requestCancel(r);
    }

    function testPendingResultPreservesSubmittedAndLateBoughtBelongsToOriginalEntry() public {
        (uint256 r, uint256 e) = _reserve();
        manager.start(r, "");
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        manager.finalize(r, "");
        assertEq(uint8(manager.round(r).status), uint8(RewardRoundManager.Status.Submitted));
        assertEq(manager.available(e), 0);
        vm.expectRevert();
        manager.start(r, "");
        adapter.setResult(1, 9, 0);
        manager.finalize(r, "");
        assertEq(manager.delivered(e), 9);
    }

    function testRefundRestoresSameCreditAndLateStockIsTreasuryOrphan() public {
        (uint256 r, uint256 e) = _reserve();
        manager.start(r, "");
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        adapter.setResult(2, 0, 200 ether);
        manager.finalize(r, "");
        assertEq(manager.available(e), 200 ether);
        assertEq(address(manager).balance, 200 ether);
        assertEq(manager.entry(e).creditTotal, 100);
        bytes32 order = manager.round(r).orderId;
        assertEq(capacity.reserved(order), 0, "refunded capacity leaked");
        assertEq(capacity.finalReleaseCount(order), 1);
        vm.expectRevert();
        manager.finalize(r, "");
        adapter.setResult(1, 7, 0);
        manager.finalize(r, "");
        assertEq(stock.balanceOf(address(0xFEE)), 7);
        assertEq(manager.delivered(e), 0);
        assertEq(capacity.finalReleaseCount(order), 1, "orphan released twice");
        vm.expectRevert();
        manager.finalize(r, "");
    }

    function testCallerCannotOverrideSourceAssetPolicy() public {
        vm.expectRevert();
        manager.seal(address(source), 7, 0, bytes32("EVIL"), 1, bytes32("price"), 0);
        assertEq(address(source).balance, 200 ether);
    }

    function testDeliveredStockStagesOnlyOriginalCreditAndCannotDoubleStage() public {
        source.setCredit(address(0xA11CE), 75);
        source.setCredit(address(0xB0B), 25);
        (uint256 r, uint256 e) = _reserve();
        manager.start(r, "");
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        adapter.setResult(1, 12, 0);
        manager.finalize(r, "");
        uint256[] memory ids = new uint256[](1);
        ids[0] = e;
        vm.startPrank(address(0xBEEF));
        uint256 n = manager.vault().stageCredit(address(0xA11CE), ids, address(stock));
        assertEq(n, 9);
        assertEq(stock.balanceOf(address(0xBEEF)), 9);
        assertEq(manager.vault().stageCredit(address(0xA11CE), ids, address(stock)), 0);
        assertEq(stock.balanceOf(address(manager.vault())), 3);
        vm.stopPrank();
    }

    function testFundingUnknownRecoversAfterQuoteDeadlineWithoutRepricing() public {
        (uint256 r,) = _reserve();
        manager.start(r, "");
        manager.finalize(r, "");
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        assertTrue(adapter.submitted());
        assertEq(manager.round(r).minRawOut, 5);
    }

    function testVaultQueueRequiresBoundedSourceEnumerationAndPinsAsset() public {
        source.setCredit(address(0xA11CE), 75);
        source.setCredit(address(0xB0B), 25);
        (uint256 r, uint256 e) = _reserve();
        r;
        manager.vault().registerParticipants(address(source), 64);
        manager.vault().sealParticipantIndex(e);
        (uint256 count,) = manager.vault().queueSnapshot(e);
        assertEq(count, 2);
        assertEq(manager.vault().participantAt(e, 0), address(0xA11CE));
        assertEq(manager.vault().queueAsset(e), address(stock));
        RewardVault v = manager.vault();
        vm.expectRevert();
        v.registerParticipants(address(source), 65);
    }

    function testCancelAfterThirtyMinutesRequestsWithoutPretendingRefund() public {
        (uint256 r, uint256 e) = _reserve();
        manager.start(r, "");
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        vm.expectRevert();
        manager.requestCancel(r);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        manager.requestCancel(r);
        assertTrue(adapter.cancelCalled());
        assertTrue(manager.round(r).cancelRequested);
        assertEq(manager.available(e), 0);
        assertEq(address(manager).balance, 0);
        assertEq(capacity.reserved(manager.round(r).orderId), 200 ether);
    }

    function testUnsentReservationCanBeCancelledButSentUnknownCannot() public {
        (uint256 r, uint256 e) = _reserve();
        manager.cancelUnsent(r);
        assertEq(manager.available(e), 200 ether);
        assertEq(manager.pending(e), 0);
        assertEq(capacity.reserved(manager.round(r).orderId), 0);
        vm.expectRevert();
        manager.start(r, "");
        uint256[] memory ids = new uint256[](1);
        ids[0] = e;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200 ether;
        uint256 next = manager.reserveBatch(ids, amounts, 5, block.timestamp + 1 hours);
        manager.start(next, "");
        manager.finalize(next, "");
        vm.expectRevert();
        manager.cancelUnsent(next);
        assertEq(manager.available(e), 0);
        assertEq(capacity.reserved(manager.round(next).orderId), 200 ether);
    }

    function testApplyResultUsesFixedOrderIdAndRejectsUnknownOrder() public {
        (uint256 r,) = _reserve();
        manager.start(r, "");
        manager.applyResult(manager.round(r).orderId, "");
        assertEq(uint8(manager.round(r).status), uint8(RewardRoundManager.Status.Funding));
        vm.expectRevert();
        manager.applyResult(bytes32("unknown"), "");
    }

    function testOrphanTransferCannotBurnOtherEntriesStock() public {
        (uint256 r,) = _reserve();
        manager.start(r, "");
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        adapter.setResult(2, 0, 200 ether);
        manager.finalize(r, "");
        stock.mint(address(manager.vault()), 10);
        stock.setTax(address(manager.vault()));
        adapter.setResult(1, 7, 0);
        vm.expectRevert();
        manager.finalize(r, "");
        assertEq(stock.balanceOf(address(manager.vault())), 10);
        assertEq(stock.balanceOf(address(0xFEE)), 0);
    }

    function testEntryStatusShowsAgeDormancyAndCostWithoutChangingCredit() public {
        vm.warp(41 days);
        uint256 e = manager.seal(address(source), 7, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        (uint256 age, bool dormant, uint256 nextCheck, RewardRoundManager.DeferReason reason) = manager.entryStatus(e);
        assertEq(age, 33 days);
        assertTrue(dormant);
        assertEq(nextCheck, 41 days + 10 minutes);
        assertEq(uint8(reason), uint8(RewardRoundManager.DeferReason.Ready));
        registry.setCost(6 ether);
        (,,, reason) = manager.entryStatus(e);
        assertEq(uint8(reason), uint8(RewardRoundManager.DeferReason.CostLimit));
        assertEq(manager.available(e), 200 ether);
    }

    function testCannotSealIntoMissingAssetRouteAndTrapOriginalBudget() public {
        registry.clearRoute();
        vm.expectRevert();
        manager.seal(address(source), 7, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        assertEq(address(source).balance, 200 ether);
        assertEq(manager.nextEntryId(), 0);
    }

    function testUnsentReservationCannotInvalidateOrderQuoteAndFundedRetryUsesNewId() public {
        (uint256 r, uint256 e) = _reserve();
        bytes32 signedOrder = manager.round(r).orderId;
        uint256 deadline = manager.round(r).deadline;
        manager.cancelUnsent(r);
        uint256[] memory ids = new uint256[](1);
        ids[0] = e;
        uint256[] memory budgets = new uint256[](1);
        budgets[0] = 200 ether;
        uint256 second = manager.reserveBatch(ids, budgets, 5, deadline);
        assertEq(manager.round(second).orderId, signedOrder);
        assertEq(manager.orderRound(signedOrder), second);
        manager.start(second, "");
        adapter.setResult(2, 0, 200 ether);
        manager.finalize(second, "");
        uint256 retry = manager.reserveBatch(ids, budgets, 5, deadline);
        assertNotEq(manager.round(retry).orderId, signedOrder);
        assertEq(manager.orderRound(signedOrder), second);
        assertEq(manager.round(second).sourceNonce, 0);
        assertEq(manager.round(retry).sourceNonce, 1);
    }

    function testSealPreservesOriginalBudgetAndCredit() public {
        uint256 id = manager.seal(address(source), 7, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        RewardRoundManager.Entry memory e = manager.entry(id);
        assertEq(e.budget18, 200 ether);
        assertEq(e.creditTotal, 100);
        assertEq(e.epoch, 7);
        assertEq(manager.available(id), 200 ether);
        assertEq(address(manager).balance, 200 ether);
        vm.expectRevert();
        manager.seal(address(source), 7, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
    }
}
