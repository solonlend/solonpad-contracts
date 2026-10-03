// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FloorOracleStub, FLOOR_ORACLE} from "./helpers/OracleMocks.sol";

import {StockSystemBase} from "./ReserveVault.t.sol";
import {RoundSource} from "./RewardRounds.t.sol";
import {ConverterDestination} from "./StockFeeConverter.t.sol";
import {LedgerReceiver} from "./V3FeeLedger.t.sol";
import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";
import {StockAdapterRegistry} from "../../src/v3/StockAdapterRegistry.sol";
import {SolonStockAdapter} from "../../src/v3/adapters/SolonStockAdapter.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {StockFeeConverter} from "../../src/v3/StockFeeConverter.sol";
import {HubSettlement} from "../../src/v3/stock/HubSettlement.sol";
import {SolonStockSellRoute} from "../../src/v3/stock/SolonStockSellRoute.sol";
import {CapacityController} from "../../src/v3/stock/CapacityController.sol";

/// @notice Phase-3/4 consumers wired to the real phase-5 stock layer: RewardRoundManager ->
///         SolonStockAdapter -> hub/capacity/scheduler -> reserve vault, and StockFeeConverter ->
///         SolonStockSellRoute -> hub -> vault.
contract StockLayerIntegrationTest is StockSystemBase {
    StockAdapterRegistry registry;
    RewardRoundManager manager;
    SolonStockAdapter adapter;
    RoundSource source;
    uint256 constant QUOTE_KEY = 0xA11;

    /// @dev This test stands in for the RewardBatcher (as `configureExecution(address(this), …)` says);
    ///      the production batcher implements the callback, so the fixture must too.
    function onRoundFinalized(uint256) external {}

    function _rewardManager() internal view override returns (address) {
        return address(manager);
    }

    function setUp() public override {
        vm.etch(FLOOR_ORACLE, type(FloorOracleStub).runtimeCode);
        registry = new StockAdapterRegistry(address(this));
        manager = new RewardRoundManager(address(this), address(registry), address(0xBEEF), treasury);
        super.setUp();
        adapter = new SolonStockAdapter(
            SolonStockAdapter.Config(
                address(manager),
                address(manager.vault()),
                address(token),
                address(stock),
                address(hub),
                vm.addr(QUOTE_KEY),
                RELAY,
                4663,
                ops,
                FLOOR_ORACLE
            )
        );
        registry.register(
            bytes32("NVDA"),
            1,
            StockAdapterRegistry.Route(
                address(token), address(stock), address(hub), address(adapter), RELAY, 4663, true, 0.4 ether
            )
        );
        vm.prank(owner);
        hub.setRewardAdapter(address(adapter), true);
        manager.configureExecution(address(this), address(capacity));
        source = new RoundSource();
        manager.registerSource(address(source), bytes32("pool"));
    }

    function _seal(uint256 epoch, uint256 budget) internal returns (uint256 entryId) {
        vm.deal(address(source), budget);
        entryId = manager.seal(address(source), epoch, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
    }

    function _reserve(uint256 entryId, uint256 amount) internal returns (uint256 roundId, bytes32 orderId) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = entryId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        roundId = manager.reserveBatch(ids, amounts, 1e18, block.timestamp + 1 hours);
        orderId = manager.round(roundId).orderId;
    }

    function _quote(bytes32 orderId, uint256 budget, uint256 nonce) internal view returns (bytes memory) {
        SolonStockAdapter.SignedQuote memory q =
            SolonStockAdapter.SignedQuote(
                orderId, budget, 1e18, block.timestamp + 1 hours, nonce, (budget * 25) / 10_000 + 0.4 ether, 0.4 ether
            ); // r12: fees18 = hub 25 bps + external cost
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(QUOTE_KEY, adapter.quoteDigest(q));
        return abi.encode(q, abi.encodePacked(r, s, v));
    }

    function testRewardRoundBuysRealStockThroughTheLayerAndSettlesExactly() public {
        uint256 entryId = _seal(7, 400 ether);
        (uint256 roundId, bytes32 orderId) = _reserve(entryId, 400 ether);
        CapacityController.Ticket memory t = capacity.ticket(orderId);
        assertEq(t.lane, 1, "RoundManager reserves in the reward lane");
        assertEq(t.usd, 400 ether);
        adapter.depositFees{value: 2 ether}(orderId);
        manager.start(roundId, _quote(orderId, 400 ether, 1));
        uint256 hubId = hub.orderCount() - 1;
        vm.expectRevert(); // not funded on the reserve chain yet
        manager.poke(roundId);
        scheduler.launchNext(hubId, abi.encode(uint256(0.3 ether), bytes("ok")));
        manager.poke(roundId);
        manager.submit(roundId);
        route.fill(route.sentCount() - 1, 400e6);
        _deliverLatestOrder();
        _deliverLatestResult();
        manager.finalize(roundId, "");
        RewardRoundManager.Round memory r = manager.round(roundId);
        assertEq(uint8(r.status), uint8(RewardRoundManager.Status.Settled));
        assertEq(r.delivered, 4e18, "400 USDG of RH stock at $100, raw 1:1");
        assertEq(token.balanceOf(address(manager.vault())), 4e18);
        assertEq(vault.entitledOf(address(stock)), 4e18);
        assertEq(capacity.issuedRaw(address(stock)), 4e18);
        assertEq(hub.accruedFees(), 1 ether, "25 bps on 400, paid by Ops, not by the reward budget");
    }

    /// Owner decision 2026-09-30: the per-order limit is the controller's `lRun` ($10,000), not a
    /// hard-coded $1,000 in the reward consumers; a governance change of `lRun` applies to all of them.
    function testRewardRoundsFollowTheControllersRunLimit() public {
        uint256 entryId = _seal(7, 12_000 ether);
        uint256[] memory ids = new uint256[](1);
        ids[0] = entryId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10_000 ether + 1e12;
        vm.expectRevert(bytes("cost or run limit"));
        manager.reserveBatch(ids, amounts, 1e18, block.timestamp + 1 hours);
        (uint256 roundId, bytes32 orderId) = _reserve(entryId, 5_000 ether);
        adapter.depositFees{value: 20 ether}(orderId);
        SolonStockAdapter.SignedQuote memory q = SolonStockAdapter.SignedQuote(
            orderId, 5_000 ether, 1e18, block.timestamp + 1 hours, 1, 12.9 ether, 0.4 ether // r12: 12.5 hub + 0.4
        );
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(QUOTE_KEY, adapter.quoteDigest(q));
        manager.start(roundId, abi.encode(q, abi.encodePacked(r, ss, v)));
        assertEq(hub.getOrder(hub.orderCount() - 1).amountIn, 5_000 ether);
        // Guardian tightens: the reward consumers follow at once.
        (uint256 u, uint256 total) = (capacity.uRun(), capacity.totalCap());
        vm.prank(guardian);
        capacity.lowerLimits(1_000e18, u, total);
        uint256 other = _seal(8, 2_000 ether);
        ids[0] = other;
        amounts[0] = 1_000 ether + 1e12;
        vm.expectRevert(bytes("cost or run limit"));
        manager.reserveBatch(ids, amounts, 1e18, block.timestamp + 1 hours);
    }

    function testUnsentRewardReservationIsReleasedInTheRealController() public {
        uint256 entryId = _seal(7, 400 ether);
        (uint256 roundId, bytes32 orderId) = _reserve(entryId, 400 ether);
        assertEq(capacity.inflightUsd(), 400 ether);
        manager.cancelUnsent(roundId);
        assertEq(capacity.inflightUsd(), 0);
        assertEq(uint8(capacity.ticket(orderId).state), uint8(CapacityController.State.None));
    }

    function testFeeLotsSellThroughTheHubWithoutTouchingIssuanceUntilRedeemed() public {
        _boughtOrder(1_000e18); // user holds 9.975 NVDA.sol
        vm.prank(user);
        token.transfer(address(this), 9.975e18);
        uint256 exposure = capacity.exposureUsd();
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        ConverterDestination buyback = new ConverterDestination();
        ConverterDestination protocol = new ConverterDestination();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        SolonStockSellRoute sellRoute = new SolonStockSellRoute(address(hub), predicted, ops);
        StockFeeConverter c = new StockFeeConverter(
            ledger,
            vm.addr(QUOTE_KEY),
            address(sellRoute),
            address(buyback),
            address(protocol),
            ops,
            25,
            1,
            RELAY,
            address(this),
            FLOOR_ORACLE
        );
        assertEq(address(c), predicted);
        bytes32 pool = keccak256("NVDA-quote pool");
        address[6] memory bs;
        address holderSide = address(new LedgerReceiver());
        for (uint256 j; j < 6; j++) {
            bs[j] = holderSide;
        }
        bs[4] = address(c);
        bs[5] = address(c);
        ledger.registerPool(pool, address(token), 1, address(this), bs);
        c.enablePool(pool, 4);
        c.enablePool(pool, 5);
        token.approve(address(ledger), type(uint256).max);
        ledger.creditStock(pool, 9.975e18);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = c.reserve(pool, 1, 4);
        ids[1] = c.reserve(pool, 1, 5);
        if (ids[0] > ids[1]) (ids[0], ids[1]) = (ids[1], ids[0]);
        assertEq(capacity.exposureUsd(), exposure, "fee transfers of issued stock never touch capacity");
        uint256 raw = 0.9975e18 + 0.748125e18;
        StockFeeConverter.Quote memory q = StockFeeConverter.Quote(
            keccak256("sale"),
            address(token),
            keccak256(abi.encode(ids)),
            raw,
            172.4e18,
            174.5625e18,
            block.timestamp,
            block.timestamp + 60,
            1,
            1 ether
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(QUOTE_KEY, c.quoteDigest(q));
        c.depositFees{value: 1 ether}(q.orderId);
        c.submit(q, ids, abi.encodePacked(rr, ss, v));
        uint256 hubId = hub.orderCount() - 1;
        assertEq(sellRoute.runLimit(), capacity.lRun(), "fee-lot sales follow the controller's single-order limit");
        _deliverLatestOrder();
        _deliverLatestResult();
        c.applyResult(q.orderId, ""); // proceeds not back yet: unknown, nothing re-sold
        vault.returnFunds(bytes32(hubId), 174e18, "ok");
        vm.deal(address(this), 1_000 ether);
        returnRoute.complete{value: 174.3e18}(0, payable(address(route)), 174.3e18);
        c.applyResult(q.orderId, "");
        c.route(q.orderId);
        uint256 net = 174.5625e18 - 0.43640625e18;
        assertEq(address(buyback).balance + address(protocol).balance, net, "gross less the service fee");
        assertEq(capacity.exposureUsd(), exposure - raw * 100, "only the final redemption releases");
        assertEq(uint8(hub.getOrder(hubId).status), uint8(HubSettlement.Status.Filled));
    }
}
