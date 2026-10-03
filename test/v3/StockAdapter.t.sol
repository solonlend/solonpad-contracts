// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FloorOracleStub, FLOOR_ORACLE} from "./helpers/OracleMocks.sol";
import {Test} from "forge-std/Test.sol";
import {StockAdapterRegistry} from "../../src/v3/StockAdapterRegistry.sol";

contract AdapterDependency {}

contract RejectingOps {
    bool public reject = true;

    function acceptPayments() external {
        reject = false;
    }

    receive() external payable {
        require(!reject, "ops rejected");
    }
}

contract StockAdapterTest is Test {
    StockAdapterRegistry registry;
    bytes32 constant NVDA = keccak256("NVDA");

    function setUp() public {
        vm.etch(FLOOR_ORACLE, type(FloorOracleStub).runtimeCode);
        registry = new StockAdapterRegistry(address(this));
    }

    function testRouteVersionIsImmutableAndMoreThanFourAssets() public {
        address dependency = address(new AdapterDependency());
        StockAdapterRegistry.Route memory r = StockAdapterRegistry.Route(
            dependency, address(22), dependency, dependency, keccak256("RELAY"), 4663, true, 0.55 ether
        );
        for (uint256 i; i < 6; ++i) {
            registry.register(bytes32(i + 1), 1, r);
        }
        registry.register(NVDA, 1, r);
        assertEq(registry.resolve(NVDA, 1).asset, dependency);
        vm.expectRevert();
        registry.register(NVDA, 1, r);
        vm.prank(address(12));
        vm.expectRevert();
        registry.register(NVDA, 2, r);
    }
}

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SolonStockAdapter, ISolonFundingHub} from "../../src/v3/adapters/SolonStockAdapter.sol";

contract AdapterStock is ERC20 {
    constructor() ERC20("Stock", "STK") {}

    function mint(address to, uint256 n) external {
        _mint(to, n);
    }
}

contract FundingHubFixture is ISolonFundingHub {
    AdapterStock public stock;
    mapping(bytes32 => address) public receiver;
    mapping(bytes32 => uint256) public received;
    mapping(bytes32 => bool) public submitted;
    mapping(bytes32 => bool) public consumed;
    mapping(bytes32 => bool) public refundMode;

    function setRefund(bytes32 id, bool value) external {
        refundMode[id] = value;
        consumed[id] = false;
    }

    constructor(AdapterStock s) {
        stock = s;
    }

    function beginFunding(bytes32 id, address, uint256, uint256, address to, bytes32) external payable {
        receiver[id] = to;
    }
    mapping(bytes32 => bool) public cancelRequested;

    function requestCancel(bytes32 id) external {
        cancelRequested[id] = true;
    }

    function receiveFunds(bytes32 id, uint256 n) external {
        received[id] = n;
    }

    function fundingReceived(bytes32 id) external view returns (uint256) {
        return received[id];
    }

    function submitFundedBuy(bytes32 id) external {
        submitted[id] = true;
    }

    /// @dev SolonStockHub.fees(): 25 bps buy fee (r12: excluded from the adapter's external-cost cap).
    function fees() external pure returns (uint16, uint16, uint16) {
        return (25, 25, 0);
    }

    function claimResult(bytes32 id, bytes calldata) external returns (uint8, uint256, uint256) {
        require(submitted[id] && !consumed[id]);
        consumed[id] = true;
        if (refundMode[id]) {
            (bool ok,) = payable(receiver[id]).call{value: 100 ether}("");
            require(ok);
            return (2, 0, 100 ether);
        }
        stock.mint(receiver[id], 7 ether);
        return (1, 7 ether, 0);
    }
}

contract SolonAdapterTest is Test {
    AdapterStock stock;
    FundingHubFixture hub;
    SolonStockAdapter adapter;
    address vault = address(0xCAFE);
    uint256 key = 77;
    bytes32 id = keccak256("order1");

    function setUp() public {
        vm.etch(FLOOR_ORACLE, type(FloorOracleStub).runtimeCode);
        stock = new AdapterStock();
        hub = new FundingHubFixture(stock);
        adapter = new SolonStockAdapter(
            SolonStockAdapter.Config(
                address(this),
                vault,
                address(stock),
                address(12),
                address(hub),
                vm.addr(key),
                keccak256("RELAY"),
                4663,
                address(0xBEEF),
                FLOOR_ORACLE
            )
        );
        vm.deal(address(this), 1000 ether);
    }

    function quoteData(bytes32 oid, uint256 nonce) internal view returns (bytes memory) {
        SolonStockAdapter.SignedQuote memory q =
            SolonStockAdapter.SignedQuote(oid, 100 ether, 6 ether, block.timestamp + 60, nonce, 0.75 ether, 0.5 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, adapter.quoteDigest(q));
        return abi.encode(q, abi.encodePacked(r, s, v));
    }

    /// @dev r7: minRawOut >= budget / execPrice * 99%; a non-Live oracle stops new reward purchases.
    function testR7OracleFloorOnSignedMinimum() public {
        adapter.depositFees{value: 3 ether}(id);
        bytes memory data = quoteData(id, 1); // $100 budget, min 6 raw
        FloorOracleStub(FLOOR_ORACLE).setPrice(address(stock), 16 ether); // 6.25 raw * 99% = 6.1875 > 6
        vm.expectRevert(SolonStockAdapter.InvalidQuote.selector);
        adapter.startFunding{value: 100 ether}(id, 100 ether, 6 ether, block.timestamp + 60, vault, data);
        FloorOracleStub(FLOOR_ORACLE).setDown(true);
        vm.expectRevert(bytes("PriceNotLive"));
        adapter.startFunding{value: 100 ether}(id, 100 ether, 6 ether, block.timestamp + 60, vault, data);
        FloorOracleStub(FLOOR_ORACLE).setDown(false);
        FloorOracleStub(FLOOR_ORACLE).setPrice(address(stock), 16.5 ether); // 6.06 raw * 99% = 5.9994 <= 6
        adapter.startFunding{value: 100 ether}(id, 100 ether, 6 ether, block.timestamp + 60, vault, data);
        assertEq(address(hub).balance, 100.75 ether);
    }

    function testRejectedOpsFeeRefundIsRetryableAndCannotTouchPrincipal() public {
        RejectingOps ops = new RejectingOps();
        adapter = new SolonStockAdapter(
            SolonStockAdapter.Config(
                address(this),
                vault,
                address(stock),
                address(12),
                address(hub),
                vm.addr(key),
                keccak256("RELAY"),
                4663,
                address(ops),
                FLOOR_ORACLE
            )
        );
        adapter.depositFees{value: 3 ether}(id);
        vm.prank(address(123));
        vm.expectRevert();
        adapter.refundUnusedFees(id);
        adapter.startFunding{value: 100 ether}(id, 100 ether, 6 ether, block.timestamp + 60, vault, quoteData(id, 1));
        assertFalse(adapter.refundUnusedFees(id));
        assertEq(adapter.feeBalance(id), 2.25 ether);
        assertEq(address(hub).balance, 100.75 ether);
        ops.acceptPayments();
        assertTrue(adapter.refundUnusedFees(id));
        assertEq(address(ops).balance, 2.25 ether);
        assertEq(adapter.feeBalance(id), 0);
        assertTrue(adapter.refundUnusedFees(id));
        assertEq(address(ops).balance, 2.25 ether);
    }

    function testUnusedFeeDepositRefundsOnlyFixedOpsAfterFunding() public {
        adapter.depositFees{value: 3 ether}(id);
        adapter.startFunding{value: 100 ether}(id, 100 ether, 6 ether, block.timestamp + 60, vault, quoteData(id, 1));
        (bool ok,) = address(adapter).call(abi.encodeWithSignature("refundUnusedFees(bytes32)", id));
        assertTrue(ok);
        assertEq(address(0xBEEF).balance, 2.25 ether);
        assertEq(address(hub).balance, 100.75 ether);
        assertEq(adapter.feeBalance(id), 0);
    }

    function testSignedActualFixedCostRaisesMinimumBeyondRegistryEstimate() public {
        SolonStockAdapter.SignedQuote memory q =
            SolonStockAdapter.SignedQuote(id, 100 ether, 6 ether, block.timestamp + 60, 1, 0.85 ether, 0.6 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, adapter.quoteDigest(q));
        adapter.depositFees{value: 1 ether}(id);
        vm.expectRevert();
        adapter.startFunding{value: 100 ether}(
            id, 100 ether, 6 ether, q.deadline, vault, abi.encode(q, abi.encodePacked(r, s, v))
        );
    }

    function _start(bytes32 oid, uint256 fees18, uint256 fixedCost18) internal {
        SolonStockAdapter.SignedQuote memory q =
            SolonStockAdapter.SignedQuote(oid, 100 ether, 6 ether, block.timestamp + 60, uint256(oid), fees18, fixedCost18);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, adapter.quoteDigest(q));
        adapter.depositFees{value: fees18}(oid);
        adapter.startFunding{value: 100 ether}(
            oid, 100 ether, 6 ether, q.deadline, vault, abi.encode(q, abi.encodePacked(r, s, v))
        );
    }

    /// @notice r12 (fork F4, design §5.1): a $100 round with $0.45 external cost (Relay + LZ) starts — the cap is
    ///         budget/200 = $0.50 on fixedCost18 = external cost only; the hub's 25 bps ($0.25) is not counted. Signing
    ///         the all-in $0.70 as fixedCost18 (what the fork keeper did) is over the cap.
    function testR12CostCapCountsOnlyExternalCostNotTheHubFee() public {
        vm.expectRevert(SolonStockAdapter.InvalidQuote.selector);
        this.startExternal(keccak256("allin"), 0.7 ether, 0.7 ether);
        _start(keccak256("ext"), 0.7 ether, 0.45 ether);
        assertEq(address(hub).balance, 100.7 ether, "budget + fees (25 bps hub fee + external) reach the hub");
        _start(keccak256("edge"), 0.75 ether, 0.5 ether); // exactly budget/200 external
    }

    /// @notice r12: every fee the order pays beyond the hub fee is external and must be inside fixedCost18.
    function testR12FeesBeyondTheHubFeeMustBeCountedAsExternalCost() public {
        vm.expectRevert(SolonStockAdapter.InvalidQuote.selector);
        this.startExternal(keccak256("under"), 0.8 ether, 0.45 ether); // 0.80 > 0.45 + 0.25
        _start(keccak256("ok"), 0.7 ether, 0.45 ether);
    }

    function startExternal(bytes32 oid, uint256 fees18, uint256 fixedCost18) external {
        require(msg.sender == address(this));
        _start(oid, fees18, fixedCost18);
    }

    function testCancelRequestsDoNotPretendFundsAreRefunded() public {
        adapter.depositFees{value: 1 ether}(id);
        adapter.startFunding{value: 100 ether}(id, 100 ether, 6 ether, block.timestamp + 60, vault, quoteData(id, 1));
        hub.receiveFunds(id, 100 ether);
        adapter.submit(id);
        (bool ok,) = address(adapter).call(abi.encodeWithSignature("requestCancel(bytes32)", id));
        assertTrue(ok, "cancel seam missing");
        assertTrue(hub.cancelRequested(id));
        assertEq(vault.balance, 0);
    }

    function testRefundAndLateBoughtRemainDistinctReceipts() public {
        adapter.depositFees{value: 1 ether}(id);
        adapter.startFunding{value: 100 ether}(id, 100 ether, 6 ether, block.timestamp + 60, vault, quoteData(id, 1));
        hub.receiveFunds(id, 100 ether);
        adapter.submit(id);
        hub.setRefund(id, true);
        (uint8 status,, uint256 refund) = adapter.consumeResult(id, "");
        assertEq(status, 2);
        assertEq(refund, 100 ether);
        hub.setRefund(id, false);
        (status,,) = adapter.consumeResult(id, "");
        assertEq(status, 1);
        assertEq(stock.balanceOf(vault), 7 ether);
        vm.expectRevert();
        adapter.consumeResult(id, "");
    }

    function testQuoteBindsRecipientBudgetNonceChainAndCannotReplay() public {
        bytes memory signed = quoteData(id, 1);
        adapter.depositFees{value: 1 ether}(id);
        vm.expectRevert();
        adapter.startFunding{value: 100 ether}(id, 100 ether, 6 ether, block.timestamp + 60, address(22), signed);
        vm.chainId(block.chainid + 1);
        vm.expectRevert();
        adapter.startFunding{value: 100 ether}(id, 100 ether, 6 ether, block.timestamp + 60, vault, signed);
        vm.chainId(block.chainid - 1);
        adapter.startFunding{value: 100 ether}(id, 100 ether, 6 ether, block.timestamp + 60, vault, signed);
        vm.expectRevert();
        adapter.startFunding{value: 100 ether}(id, 100 ether, 6 ether, block.timestamp + 60, vault, signed);
    }

    function testZeroFloatRequiresFullFundingAndPaysOnlyVerifiedResult() public {
        adapter.depositFees{value: 1 ether}(id);
        adapter.startFunding{value: 100 ether}(id, 100 ether, 6 ether, block.timestamp + 60, vault, quoteData(id, 1));
        assertEq(address(hub).balance, 100.75 ether);
        vm.expectRevert();
        adapter.submit(id);
        hub.receiveFunds(id, 99 ether);
        assertFalse(adapter.funded(id));
        hub.receiveFunds(id, 100 ether);
        assertTrue(adapter.funded(id));
        adapter.submit(id);
        (uint8 status, uint256 raw,) = adapter.consumeResult(id, "");
        assertEq(status, 1);
        assertEq(raw, 7 ether);
        assertEq(stock.balanceOf(vault), 7 ether);
        vm.expectRevert();
        adapter.consumeResult(id, "");
    }
}

import {ArcStocksV2Adapter} from "../../src/v3/adapters/ArcStocksV2Adapter.sol";

contract ArcV2HubFixture {
    struct Order {
        address user;
        address underlying;
        uint8 kind;
        uint8 status;
        uint64 createdAt;
        uint64 settledAt;
        uint256 amountIn;
        uint256 minOut;
        uint256 amountOut;
        uint256 fee;
        uint128 rawOut;
        bool lzSettled;
        bool orphaned;
        uint64 dispatchedAt;
    }
    AdapterStock stock;
    Order[] internal orders;
    uint256 public unusedDispatchRefund;
    mapping(address => uint256) public claimable;

    function setUnusedDispatchRefund(uint256 n) external {
        unusedDispatchRefund = n;
    }
    bool public claimOpen = true;

    function setClaimOpen(bool yes) external {
        claimOpen = yes;
    }

    function cancelPartially(uint256 id, uint256 paid) external {
        Order storage o = orders[id];
        o.status = 3;
        claimable[o.user] = o.amountIn + o.fee - paid;
        (bool ok,) = payable(o.user).call{value: paid}("");
        require(ok);
    }

    function claim() external {
        if (!claimOpen) return;
        uint256 n = claimable[msg.sender];
        claimable[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: n}("");
        require(ok);
    }

    function cancel(uint256 id) external {
        Order storage o = orders[id];
        require(msg.sender == o.user);
        o.status = 3;
        (bool ok,) = payable(o.user).call{value: o.amountIn + o.fee}("");
        require(ok);
    }

    constructor(AdapterStock s) {
        stock = s;
    }

    function fees() external pure returns (uint16, uint16, uint16) {
        return (25, 25, 500);
    }

    function requestBuy(address underlying, uint256 usdcIn, uint256 minOut) external payable returns (uint256 id) {
        require(msg.value >= usdcIn);
        uint256 fee = usdcIn * 25 / 10000;
        id = orders.length;
        orders.push(
            Order(
                msg.sender,
                underlying,
                0,
                1,
                uint64(block.timestamp),
                0,
                usdcIn - fee,
                minOut,
                0,
                fee,
                0,
                false,
                false,
                uint64(block.timestamp)
            )
        );
        if (unusedDispatchRefund != 0) {
            (bool ok,) = payable(msg.sender).call{value: unusedDispatchRefund}("");
            require(ok);
        }
    }

    function getOrder(uint256 id) external view returns (Order memory) {
        return orders[id];
    }

    function fill(uint256 id, uint256 amount) external {
        Order storage o = orders[id];
        o.status = 2;
        o.amountOut = amount;
        o.lzSettled = true;
        stock.mint(o.user, amount);
    }
}

contract ArcV2AdapterTest is Test {
    function setUp() public {
        vm.etch(FLOOR_ORACLE, type(FloorOracleStub).runtimeCode);
    }

    function setupV2(address ops)
        internal
        returns (AdapterStock stock, ArcV2HubFixture hub, ArcStocksV2Adapter adapter, bytes32 id)
    {
        stock = new AdapterStock();
        hub = new ArcV2HubFixture(stock);
        // r12: ArcStocks fees are all external, so fees18 <= fixedCost18 <= budget/200 ($0.50 on $100); 0.5 sent,
        // 0.2 of it is the unused dispatch fee the hub returns.
        hub.setUnusedDispatchRefund(0.2 ether);
        adapter = new ArcStocksV2Adapter(
            SolonStockAdapter.Config(
                address(this),
                address(0xCAFE),
                address(stock),
                address(12),
                address(hub),
                vm.addr(77),
                keccak256("ARC_V2"),
                4663,
                ops,
                FLOOR_ORACLE
            )
        );
        vm.deal(address(this), 1000 ether);
        id = keccak256("fees");
        SolonStockAdapter.SignedQuote memory q =
            SolonStockAdapter.SignedQuote(id, 100 ether, 6 ether, block.timestamp + 60, 1, 0.5 ether, 0.5 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(77, adapter.quoteDigest(q));
        adapter.depositFees{value: 1 ether}(id);
        adapter.startFunding{value: 100 ether}(
            id, 100 ether, 6 ether, q.deadline, address(0xCAFE), abi.encode(q, abi.encodePacked(r, s, v))
        );
        adapter.submit(id);
    }

    function testV2RejectedOpsCannotBlockRefundedPrincipalAndCanRetry() public {
        RejectingOps ops = new RejectingOps();
        (, ArcV2HubFixture hub, ArcStocksV2Adapter adapter, bytes32 id) = setupV2(address(ops));
        adapter.requestCancel(id);
        uint256 fee = hub.getOrder(0).fee;
        (uint8 status,, uint256 refund) = adapter.consumeResult(id, "");
        assertEq(status, 2);
        assertEq(refund, 100 ether);
        assertEq(address(0xCAFE).balance, 100 ether);
        address receiver = address(adapter.receivers(id));
        (bool ok, bytes memory data) = receiver.call(abi.encodeWithSignature("recoverOpsFees()"));
        assertTrue(ok);
        assertFalse(abi.decode(data, (bool)));
        assertEq(receiver.balance, fee + 0.2 ether);
        assertEq(address(ops).balance, 0);
        ops.acceptPayments();
        (ok, data) = receiver.call(abi.encodeWithSignature("recoverOpsFees()"));
        assertTrue(ok);
        assertTrue(abi.decode(data, (bool)));
        assertEq(address(ops).balance, fee + 0.2 ether);
        assertEq(receiver.balance, 0);
        assertEq(address(0xCAFE).balance, 100 ether);
    }

    function testV2DispatchSurplusCannotSubstituteForUnpaidPrincipal() public {
        (, ArcV2HubFixture hub, ArcStocksV2Adapter adapter, bytes32 id) = setupV2(address(0xBEEF));
        hub.setClaimOpen(false);
        hub.cancelPartially(0, 99.8 ether);
        (uint8 status,, uint256 refund) = adapter.consumeResult(id, "");
        assertEq(status, 0);
        assertEq(refund, 0);
        assertEq(address(0xCAFE).balance, 0);
        hub.setClaimOpen(true);
        (status,, refund) = adapter.consumeResult(id, "");
        assertEq(status, 2);
        assertEq(refund, 100 ether);
    }

    function testV2DeferredRefundedBuyFeeCanBeRecoveredAfterPrincipal() public {
        (, ArcV2HubFixture hub, ArcStocksV2Adapter adapter, bytes32 id) = setupV2(address(0xBEEF));
        hub.setClaimOpen(false);
        hub.cancelPartially(0, 100 ether);
        (uint8 status,,) = adapter.consumeResult(id, "");
        assertEq(status, 2);
        assertEq(address(0xCAFE).balance, 100 ether);
        address receiver = address(adapter.receivers(id));
        (bool ok,) = receiver.call(abi.encodeWithSignature("recoverOpsFees()"));
        assertTrue(ok);
        assertEq(address(0xBEEF).balance, 0.2 ether);
        uint256 fee = hub.getOrder(0).fee;
        hub.setClaimOpen(true);
        (ok,) = receiver.call(abi.encodeWithSignature("recoverOpsFees()"));
        assertTrue(ok);
        assertEq(address(0xBEEF).balance, 0.2 ether + fee);
        assertEq(hub.claimable(receiver), 0);
    }

    function testV2UnusedDispatchFeesRecoverOnlyAfterPrincipalSettlement() public {
        (AdapterStock stock, ArcV2HubFixture hub, ArcStocksV2Adapter adapter, bytes32 id) = setupV2(address(0xBEEF));
        address receiver = address(adapter.receivers(id));
        (bool ok,) = receiver.call(abi.encodeWithSignature("recoverOpsFees()"));
        assertFalse(ok);
        hub.fill(0, 8 ether);
        adapter.consumeResult(id, "");
        assertEq(stock.balanceOf(address(0xCAFE)), 8 ether);
        (ok,) = receiver.call(abi.encodeWithSignature("recoverOpsFees()"));
        assertTrue(ok);
        assertEq(address(0xBEEF).balance, 0.2 ether);
        assertEq(receiver.balance, 0);
    }

    function testV2UsesOriginalAbiAndSeparateFeesWithIsolatedOrderRecipient() public {
        AdapterStock stock = new AdapterStock();
        ArcV2HubFixture hub = new ArcV2HubFixture(stock);
        ArcStocksV2Adapter adapter = new ArcStocksV2Adapter(
            SolonStockAdapter.Config(
                address(this),
                address(0xCAFE),
                address(stock),
                address(12),
                address(hub),
                vm.addr(77),
                keccak256("ARC_V2"),
                4663,
                address(0xBEEF),
                FLOOR_ORACLE
            )
        );
        vm.deal(address(this), 1000 ether);
        bytes32 id = keccak256("v2");
        SolonStockAdapter.SignedQuote memory q =
            SolonStockAdapter.SignedQuote(id, 100 ether, 6 ether, block.timestamp + 60, 1, 0.5 ether, 0.5 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(77, adapter.quoteDigest(q));
        adapter.depositFees{value: 1 ether}(id);
        adapter.startFunding{value: 100 ether}(
            id, 100 ether, 6 ether, q.deadline, address(0xCAFE), abi.encode(q, abi.encodePacked(r, s, v))
        );
        (uint8 beforeSubmit,,) = adapter.consumeResult(id, "");
        assertEq(beforeSubmit, 0);
        adapter.submit(id);
        ArcV2HubFixture.Order memory order = hub.getOrder(0);
        assertEq(order.amountIn, 100 ether);
        assertTrue(order.user != address(adapter));
        hub.fill(0, 8 ether);
        (uint8 status, uint256 raw,) = adapter.consumeResult(id, "");
        assertEq(status, 1);
        assertEq(raw, 8 ether);
        assertEq(stock.balanceOf(address(0xCAFE)), 8 ether);
    }
}
