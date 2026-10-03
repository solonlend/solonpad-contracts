// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcUsdcViewStub} from "../../helpers/ArcUsdcViewStub.sol";
import {StockSystemBase} from "../../ReserveVault.t.sol";
import {HubSettlement} from "../../../../src/v3/stock/HubSettlement.sol";
import {RelayFundingRoute} from "../../../../src/v3/stock/RelayFundingRoute.sol";
import {SolonStockSellRoute} from "../../../../src/v3/stock/SolonStockSellRoute.sol";
import {RelayDepositoryV2Stub, ReturnSinkRecorder} from "../../StockRoutes.t.sol";
import {MockUSDG, MockRHStock} from "../../helpers/StockMocks.sol";

/// @notice Native receiver that can be told to refuse.
contract CovDToggleReceiver {
    bool public reject;

    function setReject(bool r) external {
        reject = r;
    }

    receive() external payable {
        require(!reject, "reject");
    }
}

/// @notice Relay depository that refuses every deposit.
contract CovDRejectingDepository {
    fallback() external payable {
        revert("closed");
    }
}

/// @notice r12 (F1) Relay depository v2 whose `depositErc20` misbehaves on demand.
///         mode 0: pulls `amount` (normal); 1: reverts; 2: pulls 1 wei short (balance check);
///         3: pulls `amount` through a token that leaves the allowance in place (allowance check).
///         r14: the native route pays through the 0x3600 view stub (`ArcUsdcViewStub`) with the same modes.
contract CovDRelayDepositoryV2 {
    uint8 public mode;

    function setMode(uint8 m) external {
        mode = m;
    }

    function depositErc20(address, address token, uint256 amount, bytes32) external {
        uint8 m = mode;
        if (m == 1) revert("closed");
        CovDStickyToken(token).transferFrom(msg.sender, address(this), m == 2 ? amount - 1 : amount);
    }
}

/// @notice Minimal ERC20 whose `transferFrom` can be told to leave the allowance untouched (infinite-allowance style).
contract CovDStickyToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public sticky;

    function setSticky(bool s) external {
        sticky = s;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (!sticky) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract CovDRelayRouteTest is Test {
    uint256 constant SIGNER = 0x5161;
    address vault = address(0x7A);
    address hub = address(0x4B);
    ReturnSinkRecorder sink;

    function setUp() public {
        sink = new ReturnSinkRecorder();
        vm.deal(address(sink), 1_000 ether);
    }

    ArcUsdcViewStub arcUsdc = new ArcUsdcViewStub();

    function _route(address caller, address asset, address depository) internal returns (RelayFundingRoute) {
        return new RelayFundingRoute(
            RelayFundingRoute.Config(
                caller,
                asset,
                asset == address(0) ? vault : hub,
                4663,
                depository,
                vm.addr(SIGNER),
                address(0),
                asset == address(0) ? address(arcUsdc) : address(0)
            )
        );
    }

    function _quote(RelayFundingRoute r, bytes32 ref, uint256 amountIn, uint256 fee, uint256 minOut, uint256 n)
        internal
        view
        returns (bytes memory)
    {
        RelayFundingRoute.Quote memory q =
            RelayFundingRoute.Quote(keccak256(abi.encode("relay", n)), block.timestamp + 60, n);
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(SIGNER, r.quoteDigest(ref, amountIn, fee, minOut, q));
        return abi.encode(q, abi.encodePacked(rr, s, v));
    }

    // L137 native arm + L140 depository refuses native
    function test_nativeSend_depositoryRefuses_revertsDepositFailed() public {
        CovDRejectingDepository dep = new CovDRejectingDepository();
        RelayFundingRoute r = _route(address(sink), address(0), address(dep));
        bytes memory q = _quote(r, bytes32(uint256(7)), 1 ether, 0.1 ether, 1e6, 1);
        uint256 before = address(sink).balance;
        vm.prank(address(sink));
        vm.expectRevert(RelayFundingRoute.DepositFailed.selector);
        r.send{value: 1.1 ether}(bytes32(uint256(7)), 1 ether, 0.1 ether, 1e6, q);
        assertEq(address(sink).balance, before, "value bounced back to the caller");
        assertEq(address(r).balance, 0);
        assertFalse(r.nonceUsed(1), "nonce not consumed");
        assertEq(r.requestRef(keccak256(abi.encode("relay", uint256(1)))), bytes32(0));
    }

    // native arm happy path through depositErc20 on the view, with ref == 0 mapped to the max sentinel
    function test_nativeSend_zeroRefIsRecordedAsSentinel() public {
        RelayDepositoryV2Stub dep = new RelayDepositoryV2Stub();
        RelayFundingRoute r = _route(address(sink), address(0), address(dep));
        bytes memory q = _quote(r, bytes32(0), 1 ether, 0, 1e6, 1);
        vm.prank(address(sink));
        bytes32 tid = r.send{value: 1 ether}(bytes32(0), 1 ether, 0, 1e6, q);
        assertEq(tid, keccak256(abi.encode("relay", uint256(1))));
        assertEq(r.requestRef(tid), bytes32(type(uint256).max));
        assertEq(address(dep).balance, 1 ether);
        assertEq(address(r).balance, 0, "route holds nothing");
    }

    // native arm: depositErc20 reverts / the view moves 1e12 wei short (balance check) / leaves the allowance (allowance check)
    function test_nativeSend_depositFailureModes() public {
        CovDRelayDepositoryV2 dep = new CovDRelayDepositoryV2();
        RelayFundingRoute r = _route(address(sink), address(0), address(dep));
        // mode 1 uses the depository's revert; modes 2/3 go through the real pull with the view misbehaving
        for (uint256 i; i < 3; ++i) {
            dep.setMode(i == 0 ? 1 : 0);
            arcUsdc.setModes(i == 2, i == 1);
            bytes memory q = _quote(r, bytes32(uint256(7)), 1 ether, 0, 1e6, 10 + i);
            // the stub moves native with vm.deal, which a revert does not undo (the EVM/precompile would): isolate
            uint256 snap = vm.snapshotState();
            vm.prank(address(sink));
            vm.expectRevert(RelayFundingRoute.DepositFailed.selector);
            r.send{value: 1 ether}(bytes32(uint256(7)), 1 ether, 0, 1e6, q);
            assertFalse(r.nonceUsed(10 + i));
            assertEq(r.requestRef(keccak256(abi.encode("relay", 10 + i))), bytes32(0));
            vm.revertToState(snap);
        }
    }

    // token arm: every DepositFailed sub-arm (call reverts, balance short, allowance left) and the success arm
    function test_tokenSend_depositFailureModes() public {
        CovDRelayDepositoryV2 dep = new CovDRelayDepositoryV2();
        CovDStickyToken tok = new CovDStickyToken();
        RelayFundingRoute r = _route(vault, address(tok), address(dep));
        tok.mint(vault, 1_000e6);
        vm.prank(vault);
        tok.approve(address(r), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            dep.setMode(uint8(i + 1));
            tok.setSticky(i == 2);
            bytes memory q = _quote(r, bytes32(uint256(3)), 100e6, 1e6, 99e18, 10 + i);
            vm.prank(vault);
            vm.expectRevert(RelayFundingRoute.DepositFailed.selector);
            r.send(bytes32(uint256(3)), 100e6, 1e6, 99e18, q);
            assertEq(tok.balanceOf(vault), 1_000e6, "pull rolled back");
            assertEq(tok.balanceOf(address(r)), 0);
            assertEq(tok.balanceOf(address(dep)), 0);
            assertFalse(r.nonceUsed(10 + i));
        }
        dep.setMode(0);
        tok.setSticky(false);
        bytes memory ok = _quote(r, bytes32(uint256(3)), 100e6, 1e6, 99e18, 20);
        vm.prank(vault);
        r.send(bytes32(uint256(3)), 100e6, 1e6, 99e18, ok);
        assertEq(tok.balanceOf(address(dep)), 101e6);
        assertEq(tok.balanceOf(vault), 899e6);
        assertEq(tok.balanceOf(address(r)), 0);
        assertEq(tok.allowance(address(r), address(dep)), 0, "no allowance left");
    }
}

contract CovDSellRouteTest is StockSystemBase {
    SolonStockSellRoute sellRoute;
    CovDToggleReceiver conv;
    CovDToggleReceiver opsSink;
    address converter;
    bytes32 constant ORDER = keccak256("cov-sale-1");

    function setUp() public override {
        super.setUp();
        conv = new CovDToggleReceiver();
        opsSink = new CovDToggleReceiver();
        converter = address(conv);
        sellRoute = new SolonStockSellRoute(address(hub), converter, address(opsSink));
        _boughtOrder(1_000e18);
        vm.prank(user);
        token.transfer(converter, 9.975e18);
        vm.prank(converter);
        token.approve(address(sellRoute), type(uint256).max);
        vm.deal(converter, 10 ether);
    }

    function _request(uint256 fees) internal returns (uint256 hubId) {
        vm.prank(converter);
        sellRoute.requestSell{value: fees}(ORDER, address(token), 9.975e18, 990e18, converter, RELAY);
        hubId = hub.orderCount() - 1;
    }

    /// Settle the sale on RH and bring the proceeds back to the hub (pushed to the route).
    function _sellAndReturn() internal {
        _deliverLatestOrder();
        _deliverLatestResult();
        vault.returnFunds(bytes32(hub.orderCount() - 1), 997e18, "ok");
        vm.deal(address(this), 1_000 ether);
        returnRoute.complete{value: 997.2e18}(0, payable(address(route)), 997.2e18);
    }

    // L49: only the hub may pay the route
    function test_receive_onlyHub() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(SolonStockSellRoute.NotHub.selector);
        (bool ok,) = payable(address(sellRoute)).call{value: 1}("");
        ok; // expectRevert on a low-level call reports success; the revert itself is asserted above
        assertEq(address(sellRoute).balance, 0);
        vm.deal(address(hub), address(hub).balance + 1);
        vm.prank(address(hub));
        (bool ok2,) = payable(address(sellRoute)).call{value: 1}("");
        assertTrue(ok2);
        assertEq(address(sellRoute).balance, 1);
    }

    // L63: msg.value below the hub's LayerZero fee
    function test_requestSell_belowLzFee_revertsBadOrder() public {
        uint256 lzFee = hub.quoteOrder(address(stock));
        assertGt(lzFee, 0);
        vm.prank(converter);
        vm.expectRevert(SolonStockSellRoute.BadOrder.selector);
        sellRoute.requestSell{value: lzFee - 1}(ORDER, address(token), 9.975e18, 990e18, converter, RELAY);
        assertFalse(sellRoute.used(ORDER));
        assertEq(token.balanceOf(converter), 9.975e18);
        // exactly the fee: accepted with zero Ops fees
        vm.prank(converter);
        sellRoute.requestSell{value: lzFee}(ORDER, address(token), 9.975e18, 990e18, converter, RELAY);
        (,,, uint256 fees,) = sellRoute.sales(ORDER);
        assertEq(fees, 0);
    }

    // L92: the top-up is capped at the Ops fees sent; L111 false arm (nothing left for Ops)
    function test_claimSell_topUpCappedAtFees() public {
        uint256 lzFee = hub.quoteOrder(address(stock));
        uint256 hubId = _request(lzFee + 0.1 ether);
        _sellAndReturn();
        HubSettlement.Order memory o = hub.getOrder(hubId);
        assertEq(o.outcome, 2);
        uint256 gross = uint256(o.rawOut) * 1e12;
        uint256 target = gross - gross * o.feeBps / 10_000;
        assertGt(target - o.amountOut, 0.1 ether, "shortfall larger than the Ops fees");
        uint256 convBefore = converter.balance;
        uint256 opsBefore = address(opsSink).balance;
        vm.prank(converter);
        (uint8 st, uint256 paid, uint256 reminted) = sellRoute.claimSell(ORDER, "");
        assertEq(st, 1);
        assertEq(paid, o.amountOut + 0.1 ether, "topped up by all the fees, no more");
        assertLt(paid, target);
        assertEq(reminted, 0);
        assertEq(converter.balance, convBefore + paid);
        assertEq(address(opsSink).balance, opsBefore, "no Ops refund");
        assertEq(address(sellRoute).balance, 0, "route keeps nothing");
    }

    // L108 both arms: converter refuses native -> claim reverts and stays claimable; then pays
    function test_claimSell_converterRefusesNative_revertsThenSucceeds() public {
        _request(1 ether);
        _sellAndReturn();
        uint256 held = address(sellRoute).balance;
        conv.setReject(true);
        vm.prank(converter);
        vm.expectRevert(); // bare require(ok)
        sellRoute.claimSell(ORDER, "");
        (,,,, bool done) = sellRoute.sales(ORDER);
        assertFalse(done);
        assertEq(address(sellRoute).balance, held);
        conv.setReject(false);
        vm.prank(converter);
        (uint8 st, uint256 paid,) = sellRoute.claimSell(ORDER, "");
        assertEq(st, 1);
        assertEq(paid, 997.5e18 - 2.49375e18);
        assertEq(address(opsSink).balance, 1 ether - 0.01 ether - 0.3 ether);
        assertEq(address(sellRoute).balance, 0);
    }

    // L113 both arms: Ops refuses its refund -> claim reverts; then succeeds
    function test_claimSell_opsRefusesRefund_revertsThenSucceeds() public {
        _request(1 ether);
        _sellAndReturn();
        uint256 convBefore = converter.balance;
        opsSink.setReject(true);
        vm.prank(converter);
        vm.expectRevert(); // bare require(ok2)
        sellRoute.claimSell(ORDER, "");
        assertEq(converter.balance, convBefore, "converter payment rolled back too");
        (,,,, bool done) = sellRoute.sales(ORDER);
        assertFalse(done);
        opsSink.setReject(false);
        vm.prank(converter);
        sellRoute.claimSell(ORDER, "");
        assertEq(address(opsSink).balance, 0.69 ether);
        assertEq(address(sellRoute).balance, 0);
    }

    // L84 true arm: proceeds the hub could not push wait as `owed`; claimSell pulls them first
    function test_claimSell_pullsOwedProceedsFromHub() public {
        uint256 hubId = _request(1 ether);
        // force the hub's push to the route to fail once, so the proceeds wait in `owed`
        vm.mockCallRevert(address(sellRoute), bytes(""), bytes("down"));
        _sellAndReturn();
        vm.clearMockedCalls();
        uint256 owed = hub.getOrder(hubId).owed;
        assertGt(owed, 0, "proceeds owed by the hub");
        assertEq(address(sellRoute).balance, 1 ether - 0.01 ether, "only the Ops fees are held");
        uint256 convBefore = converter.balance;
        vm.prank(converter);
        (uint8 st, uint256 paid,) = sellRoute.claimSell(ORDER, "");
        assertEq(st, 1);
        assertEq(hub.getOrder(hubId).owed, 0, "claimed from the hub");
        assertEq(paid, 997.5e18 - 2.49375e18);
        assertEq(converter.balance, convBefore + paid);
        assertEq(address(opsSink).balance, 0.69 ether);
        assertEq(address(sellRoute).balance, 0);
    }
}
