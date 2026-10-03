// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SolonStockAdapter} from "../../../../src/v3/adapters/SolonStockAdapter.sol";
import {ArcStocksV2Adapter, ArcStocksV2Order} from "../../../../src/v3/adapters/ArcStocksV2Adapter.sol";
import {FloorOracleStub, FLOOR_ORACLE} from "../../helpers/OracleMocks.sol";
import {AdapterStock, ArcV2HubFixture} from "../../StockAdapter.t.sol";
import {CovBTaxToken, CovBEthRejecter} from "./CovBHelpers.sol";

/// @notice Funding hub whose claimResult reports AND performs configurable (possibly inconsistent) effects.
contract CovBFundingHub {
    CovBTaxToken public token;
    mapping(bytes32 => address) public receiver;
    mapping(bytes32 => uint256) public received;
    uint8 public st;
    uint256 public raw;
    uint256 public refund;
    uint256 public mintAmt;
    uint256 public sendAmt;

    constructor(CovBTaxToken t) {
        token = t;
    }

    /// @dev r12 (F4): the adapter reads the hub's buy fee; 1% here keeps the fixtures' fees18 (1) <= fixedCost18 (0.5)
    ///      + the internal hub fee (1% of 100).
    function fees() external pure returns (uint16, uint16, uint16) {
        return (100, 0, 0);
    }

    function setResult(uint8 s, uint256 r, uint256 f, uint256 m, uint256 e) external {
        (st, raw, refund, mintAmt, sendAmt) = (s, r, f, m, e);
    }

    function beginFunding(bytes32 id, address, uint256, uint256, address to, bytes32) external payable {
        receiver[id] = to;
    }

    function receiveFunds(bytes32 id, uint256 n) external {
        received[id] = n;
    }

    function fundingReceived(bytes32 id) external view returns (uint256) {
        return received[id];
    }

    function submitFundedBuy(bytes32) external {}

    function requestCancel(bytes32) external {}

    function claimResult(bytes32 id, bytes calldata) external returns (uint8, uint256, uint256) {
        if (mintAmt != 0) token.mint(receiver[id], mintAmt);
        if (sendAmt != 0) {
            (bool ok,) = receiver[id].call{value: sendAmt}("");
            require(ok, "hub send");
        }
        return (st, raw, refund);
    }

    receive() external payable {}
}

contract CovBSolonAdapterTest is Test {
    CovBTaxToken token;
    CovBFundingHub hub;
    SolonStockAdapter adapter;
    address vault = address(0xCAFE);
    uint256 constant KEY = 77;
    bytes32 constant ID = keccak256("covb-order");

    function setUp() public {
        vm.etch(FLOOR_ORACLE, type(FloorOracleStub).runtimeCode);
        token = new CovBTaxToken();
        hub = new CovBFundingHub(token);
        adapter = _adapter(vault);
        vm.deal(address(this), 1000 ether);
    }

    function _adapter(address v) internal returns (SolonStockAdapter) {
        return new SolonStockAdapter(
            SolonStockAdapter.Config(
                address(this),
                v,
                address(token),
                address(12),
                address(hub),
                vm.addr(KEY),
                keccak256("RELAY"),
                4663,
                address(0xBEEF),
                FLOOR_ORACLE
            )
        );
    }

    function _start(SolonStockAdapter a, address v) internal {
        SolonStockAdapter.SignedQuote memory q =
            SolonStockAdapter.SignedQuote(ID, 100 ether, 6 ether, block.timestamp + 60, 1, 1 ether, 0.5 ether);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(KEY, a.quoteDigest(q));
        a.depositFees{value: 1 ether}(ID);
        a.startFunding{value: 100 ether}(ID, 100 ether, 6 ether, q.deadline, v, abi.encode(q, abi.encodePacked(r, s, vv)));
    }

    function _submitted() internal {
        _start(adapter, vault);
        hub.receiveFunds(ID, 100 ether);
        adapter.submit(ID);
    }

    function _state(SolonStockAdapter a) internal view returns (uint8 s) {
        (,,, s) = a.orders(ID);
    }

    /// line 93: coordinator-only entrypoints.
    function testOnlyCoordinator() public {
        vm.deal(address(0xBAD), 200 ether);
        vm.startPrank(address(0xBAD));
        vm.expectRevert(SolonStockAdapter.Unauthorized.selector);
        adapter.startFunding{value: 100 ether}(ID, 100 ether, 6 ether, block.timestamp, vault, "");
        vm.expectRevert(SolonStockAdapter.Unauthorized.selector);
        adapter.submit(ID);
        vm.expectRevert(SolonStockAdapter.Unauthorized.selector);
        adapter.requestCancel(ID);
        vm.expectRevert(SolonStockAdapter.Unauthorized.selector);
        adapter.consumeResult(ID, "");
        vm.stopPrank();
    }

    /// line 98: only the hub may push native into the adapter.
    function testReceiveOnlyFromHub() public {
        (bool ok, bytes memory data) = address(adapter).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(data), SolonStockAdapter.Unauthorized.selector);
        vm.deal(address(hub), 1 ether);
        vm.prank(address(hub));
        (ok,) = address(adapter).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(adapter).balance, 1 ether);
    }

    /// line 143: fee deposits close once the order is funded.
    function testDepositFeesClosedAfterStart() public {
        _start(adapter, vault);
        vm.expectRevert(SolonStockAdapter.InvalidOrder.selector);
        adapter.depositFees{value: 1 ether}(ID);
        assertEq(adapter.feeBalance(ID), 0);
    }

    /// line 214: cancel only a submitted order.
    function testRequestCancelRequiresSubmitted() public {
        vm.expectRevert(SolonStockAdapter.InvalidOrder.selector);
        adapter.requestCancel(ID);
        _start(adapter, vault);
        vm.expectRevert(SolonStockAdapter.InvalidOrder.selector);
        adapter.requestCancel(ID);
        hub.receiveFunds(ID, 100 ether);
        adapter.submit(ID);
        adapter.requestCancel(ID);
    }

    /// lines 233-238: "no result" must be completely empty (no raw/refund value and no balance movement).
    function testStatusZeroMustBeEmpty() public {
        _submitted();
        hub.setResult(0, 5, 0, 0, 0);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, "");
        hub.setResult(0, 0, 1, 0, 0);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, "");
        hub.setResult(0, 0, 0, 5, 0);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, "");
        hub.setResult(0, 0, 0, 0, 1 ether);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, "");
        hub.setResult(0, 0, 0, 0, 0);
        (uint8 s, uint256 r, uint256 f) = adapter.consumeResult(ID, "");
        assertEq(s, 0);
        assertEq(r + f, 0);
        assertEq(_state(adapter), 2);
    }

    /// lines 241-245: a bought result needs a submitted order, raw >= minRaw, no refund and exact balances.
    function testStatusOneMustBeExact() public {
        _start(adapter, vault);
        hub.receiveFunds(ID, 100 ether);
        hub.setResult(1, 7 ether, 0, 7 ether, 0);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, ""); // state 1: never submitted
        adapter.submit(ID);
        hub.setResult(1, 5 ether, 0, 5 ether, 0);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, ""); // below minRaw
        hub.setResult(1, 7 ether, 1, 7 ether, 0);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, ""); // refund alongside stock
        hub.setResult(1, 7 ether, 0, 6 ether, 0);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, ""); // reported more than delivered
        hub.setResult(1, 7 ether, 0, 7 ether, 1 ether);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, ""); // native moved too
        assertEq(token.balanceOf(vault), 0);
        hub.setResult(1, 7 ether, 0, 7 ether, 0);
        adapter.consumeResult(ID, "");
        assertEq(token.balanceOf(vault), 7 ether);
        assertEq(_state(adapter), 3);
        vm.expectRevert(SolonStockAdapter.InvalidOrder.selector);
        adapter.consumeResult(ID, ""); // state 3 is terminal
    }

    /// lines 247-250: a refund must be the exact budget in native, with no stock, and only once.
    function testStatusTwoMustBeExact() public {
        _submitted();
        hub.setResult(2, 0, 99 ether, 0, 99 ether);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, "");
        hub.setResult(2, 1, 100 ether, 1, 100 ether);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, "");
        hub.setResult(2, 0, 100 ether, 0, 0);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, ""); // no native arrived
        hub.setResult(2, 0, 100 ether, 1, 100 ether);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, ""); // stock moved too
        hub.setResult(2, 0, 100 ether, 0, 100 ether);
        adapter.consumeResult(ID, "");
        assertEq(vault.balance, 100 ether);
        assertEq(_state(adapter), 4);
        hub.setResult(2, 0, 100 ether, 0, 0);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, ""); // second refund after state 4
        assertEq(vault.balance, 100 ether);
    }

    /// line 252: any other status is rejected.
    function testUnknownStatusRejected() public {
        _submitted();
        hub.setResult(3, 0, 0, 0, 0);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, "");
        assertEq(_state(adapter), 2);
    }

    /// lines 258-261: forwarding stock to the vault must be exact (lossy token rejected).
    function testDeliveryToVaultMustBeExact() public {
        _submitted();
        token.setTaxTo(vault, true);
        hub.setResult(1, 7 ether, 0, 7 ether, 0);
        vm.expectRevert(SolonStockAdapter.InexactResult.selector);
        adapter.consumeResult(ID, "");
        assertEq(_state(adapter), 2);
        assertEq(token.balanceOf(vault), 0);
    }

    /// line 265: a vault that rejects native makes the refund revert atomically (retryable, nothing lost).
    function testRefundToRejectingVaultReverts() public {
        address rej = address(new CovBEthRejecter());
        SolonStockAdapter a = _adapter(rej);
        _start(a, rej);
        hub.receiveFunds(ID, 100 ether);
        a.submit(ID);
        hub.setResult(2, 0, 100 ether, 0, 100 ether);
        // Empty revert data = `require(ok)` on the vault refund (the vault's "no eth" reason is not bubbled).
        try a.consumeResult(ID, "") {
            fail();
        } catch (bytes memory err) {
            assertEq(err.length, 0);
        }
        assertEq(_state(a), 2);
        assertEq(address(a).balance, 0);
        assertEq(address(hub).balance, 101 ether);
    }
}

contract CovBBadFeeHub {
    function fees() external pure returns (uint16, uint16, uint16) {
        return (10000, 0, 0);
    }
}

/// @notice Deploys an ArcStocksV2Order as its `adapter` but rejects every native transfer.
contract CovBOrderHost {
    ArcStocksV2Order public order;

    function open(address hub, address stock) external payable {
        order = new ArcStocksV2Order{value: msg.value}(hub, stock, address(12), 100 ether, 6 ether, address(0xBEEF));
    }

    function cancel() external {
        order.cancel();
    }

    function collect() external returns (uint8, uint256, uint256) {
        return order.collect();
    }

    receive() external payable {
        revert("host rejects");
    }
}

contract CovBArcV2Test is Test {
    AdapterStock stock;
    ArcV2HubFixture hub;

    function setUp() public {
        vm.etch(FLOOR_ORACLE, type(FloorOracleStub).runtimeCode);
        stock = new AdapterStock();
        hub = new ArcV2HubFixture(stock);
        vm.deal(address(this), 1000 ether);
    }

    function _order(address ops) internal returns (ArcStocksV2Order) {
        return new ArcStocksV2Order{value: 101 ether}(address(hub), address(stock), address(12), 100 ether, 6 ether, ops);
    }

    /// line 51: zero Ops vault rejected (both arms).
    function testOrderRequiresOpsVault() public {
        vm.expectRevert();
        _order(address(0));
        ArcStocksV2Order o = _order(address(0xBEEF));
        assertEq(o.opsVault(), address(0xBEEF));
        assertEq(o.adapter(), address(this));
    }

    /// line 60: a hub reporting a >= 100% buy fee is rejected.
    function testOrderRejectsFullFeeHub() public {
        CovBBadFeeHub bad = new CovBBadFeeHub();
        // Empty revert data = the bare `require(bps < 10000)`, not the mulDiv division-by-zero panic after it.
        CovBOrderHost host = new CovBOrderHost();
        try host.open{value: 101 ether}(address(bad), address(stock)) {
            fail();
        } catch (bytes memory err) {
            assertEq(err.length, 0);
        }
    }

    /// line 62: the order must carry a message fee above the gross principal.
    function testOrderRequiresMessageFee() public {
        uint256 gross = Math.mulDiv(100 ether - 1, 10000, 10000 - 25) + 1;
        vm.expectRevert(bytes("message fee missing"));
        new ArcStocksV2Order{value: gross}(address(hub), address(stock), address(12), 100 ether, 6 ether, address(1));
        ArcStocksV2Order o = new ArcStocksV2Order{value: gross + 1}(
            address(hub), address(stock), address(12), 100 ether, 6 ether, address(1)
        );
        assertEq(hub.getOrder(o.orderId()).amountIn, 100 ether);
    }

    /// line 73: only the hub may pay the order recipient.
    function testOrderReceiveOnlyFromHub() public {
        ArcStocksV2Order o = _order(address(0xBEEF));
        (bool ok,) = address(o).call{value: 1}("");
        assertFalse(ok);
        vm.deal(address(hub), 1);
        vm.prank(address(hub));
        (ok,) = address(o).call{value: 1}("");
        assertTrue(ok);
    }

    /// lines 79, 82: Ops recovery waits for principal; with nothing left it returns true without a transfer.
    function testRecoverOpsFeesLifecycle() public {
        ArcStocksV2Order o = _order(address(0xBEEF));
        vm.expectRevert(bytes("principal pending"));
        o.recoverOpsFees();
        hub.fill(o.orderId(), 8 ether);
        (uint8 s, uint256 raw,) = o.collect();
        assertEq(s, 1);
        assertEq(raw, 8 ether);
        assertEq(stock.balanceOf(address(this)), 8 ether);
        assertEq(address(o).balance, 0);
        assertTrue(o.recoverOpsFees());
        assertEq(address(0xBEEF).balance, 0);
    }

    /// line 88: only the adapter may cancel its hub order.
    function testOrderCancelOnlyAdapter() public {
        ArcStocksV2Order o = _order(address(0xBEEF));
        vm.prank(address(0xBAD));
        vm.expectRevert();
        o.cancel();
        assertEq(hub.getOrder(o.orderId()).status, 1);
        o.cancel();
        assertEq(hub.getOrder(o.orderId()).status, 3);
    }

    /// line 111: if the adapter rejects the principal refund, collect reverts and nothing is consumed.
    function testOrderRefundToRejectingAdapterReverts() public {
        CovBOrderHost host = new CovBOrderHost();
        host.open{value: 101 ether}(address(hub), address(stock));
        ArcStocksV2Order o = host.order();
        host.cancel();
        uint256 held = address(o).balance;
        assertGe(held, 100 ether);
        // Empty revert data = `require(ok)` in collect (the host's own "host rejects" reason is not bubbled).
        try host.collect() {
            fail();
        } catch (bytes memory err) {
            assertEq(err.length, 0);
        }
        assertFalse(o.consumed());
        assertEq(address(o).balance, held);
    }

    function _adapter() internal returns (ArcStocksV2Adapter adapter, bytes32 id) {
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
                address(0xBEEF),
                FLOOR_ORACLE
            )
        );
        id = keccak256("covb-v2");
        // r12 (F4): the ArcStocks hub fee is external (_internalFee = 0), so fees18 <= fixedCost18 (<= budget/200).
        SolonStockAdapter.SignedQuote memory q =
            SolonStockAdapter.SignedQuote(id, 100 ether, 6 ether, block.timestamp + 60, 1, 0.5 ether, 0.5 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(77, adapter.quoteDigest(q));
        adapter.depositFees{value: 0.5 ether}(id);
        adapter.startFunding{value: 100 ether}(
            id, 100 ether, 6 ether, q.deadline, address(0xCAFE), abi.encode(q, abi.encodePacked(r, s, v))
        );
    }

    /// line 149 + collect line 114: cancel only once submitted; a still-pending hub order yields an empty result.
    function testV2CancelRequiresSubmittedAndPendingIsEmpty() public {
        (ArcStocksV2Adapter adapter, bytes32 id) = _adapter();
        vm.expectRevert();
        adapter.requestCancel(id);
        assertEq(address(adapter.receivers(id)), address(0));
        adapter.submit(id);
        (uint8 s, uint256 raw, uint256 refund) = adapter.consumeResult(id, "");
        assertEq(s, 0);
        assertEq(raw + refund, 0);
        adapter.requestCancel(id);
        assertEq(hub.getOrder(0).status, 3);
    }
}
