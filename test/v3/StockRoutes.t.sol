// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StockSystemBase} from "./ReserveVault.t.sol";
import {HubSettlement} from "../../src/v3/stock/HubSettlement.sol";
import {RelayFundingRoute} from "../../src/v3/stock/RelayFundingRoute.sol";
import {SolonStockSellRoute} from "../../src/v3/stock/SolonStockSellRoute.sol";
import {IFundingReturnSink} from "../../src/v3/stock/interfaces/IFundingRoute.sol";
import {MockUSDG} from "./helpers/StockMocks.sol";
import {ArcUsdcViewStub} from "./helpers/ArcUsdcViewStub.sol";

/// @notice Behaviour of the live Relay depository v2 deposit entry points (relayprotocol/relay-depository
///         packages/ethereum-vm/src/RelayDepository.sol, commit 1f3bc34): `depositNative` / `depositErc20` emit the deposit event
///         with `depositor` (0 = msg.sender); there is no receive/fallback, so a raw value transfer reverts.
///         r14: Solon's routes only use `depositErc20` (Arc native USDC through its 0x3600 ERC-20 view).
contract RelayDepositoryV2Stub {
    using SafeERC20 for IERC20;

    event RelayNativeDeposit(address from, uint256 amount, bytes32 id);
    event RelayErc20Deposit(address from, address token, uint256 amount, bytes32 id);

    function depositNative(address depositor, bytes32 id) external payable {
        emit RelayNativeDeposit(depositor == address(0) ? msg.sender : depositor, msg.value, id);
    }

    function depositErc20(address depositor, address token, uint256 amount, bytes32 id) public {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit RelayErc20Deposit(depositor == address(0) ? msg.sender : depositor, token, amount, id);
    }
}

contract ReturnSinkRecorder is IFundingReturnSink {
    bytes32 public lastRef;
    uint256 public lastValue;

    function receiveReturn(bytes32 ref) external payable {
        lastRef = ref;
        lastValue = msg.value;
    }

    /// @dev Like the hub: plain native transfers are accepted (r14 sub-6-dp remainder of a native send comes back here).
    receive() external payable {}
}

contract RelayFundingRouteTest is Test {
    uint256 constant SIGNER = 0x5161;
    RelayDepositoryV2Stub depository;
    ReturnSinkRecorder sink;
    RelayFundingRoute nativeRoute;
    RelayFundingRoute tokenRoute;
    MockUSDG usdg;
    ArcUsdcViewStub arcUsdc;
    address hub = address(0x4B);
    address vault = address(0x7A);
    address executor = address(0xE8EC);

    function setUp() public {
        depository = new RelayDepositoryV2Stub();
        sink = new ReturnSinkRecorder();
        usdg = new MockUSDG();
        arcUsdc = new ArcUsdcViewStub();
        nativeRoute = new RelayFundingRoute(
            RelayFundingRoute.Config(
                address(sink), address(0), vault, 4663, address(depository), vm.addr(SIGNER), executor, address(arcUsdc)
            )
        );
        tokenRoute = new RelayFundingRoute(
            RelayFundingRoute.Config(
                vault, address(usdg), hub, 5042, address(depository), vm.addr(SIGNER), address(0), address(0)
            )
        );
        vm.deal(address(sink), 10_000 ether);
    }

    function _quote(RelayFundingRoute r, bytes32 ref, uint256 amountIn, uint256 fee, uint256 minOut, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        RelayFundingRoute.Quote memory q =
            RelayFundingRoute.Quote(keccak256(abi.encode("relay", nonce)), block.timestamp + 60, nonce);
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(SIGNER, r.quoteDigest(ref, amountIn, fee, minOut, q));
        return abi.encode(q, abi.encodePacked(rr, s, v));
    }

    event RelayNativeDeposit(address from, uint256 amount, bytes32 id);
    event RelayErc20Deposit(address from, address token, uint256 amount, bytes32 id);

    event DustReturned(bytes32 indexed ref, uint256 amount);

    /// @notice r14 (live probe: depositNative -> ORIGIN_CURRENCY_MISMATCH): native money goes through
    ///         `depositErc20(caller, 0x3600 view, (amountIn + fee) / 1e12, requestId)`, never `depositNative`.
    function testNativeSendDepositsTheErc20ViewWithSixDecimalAmount() public {
        bytes memory q = _quote(nativeRoute, bytes32(uint256(7)), 100 ether, 0.5 ether, 100e6, 1);
        vm.expectEmit(address(depository));
        emit RelayErc20Deposit(address(sink), address(arcUsdc), 100.5e6, keccak256(abi.encode("relay", uint256(1))));
        vm.recordLogs();
        vm.prank(address(sink));
        nativeRoute.send{value: 100.5 ether}(bytes32(uint256(7)), 100 ether, 0.5 ether, 100e6, q);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != RelayNativeDeposit.selector, "no native deposit");
            assertTrue(logs[i].topics[0] != DustReturned.selector, "aligned: no dust");
        }
        assertEq(address(depository).balance, 100.5 ether);
        assertEq(address(nativeRoute).balance, 0);
        assertEq(arcUsdc.allowance(address(nativeRoute), address(depository)), 0, "no allowance left");
    }

    /// @notice r14: the sub-6-dp remainder (< 1e12 wei) is neither deposited, kept, nor blocking: it goes back to the
    ///         caller in the same call.
    function testNativeSendReturnsTheSubSixDecimalRemainderToTheCaller() public {
        uint256 amountIn = 100 ether + 123_456_789; // 1.23e-10 USDC under 6 dp
        uint256 fee = 0.5 ether + 1e12 - 1; // fee adds 0.999999e-6 USDC
        uint256 total = amountIn + fee; // = 100.500001 USDC + 123_456_788 wei
        bytes memory q = _quote(nativeRoute, bytes32(uint256(7)), amountIn, fee, 100e6, 1);
        uint256 sinkBefore = address(sink).balance;
        vm.expectEmit(address(depository));
        emit RelayErc20Deposit(address(sink), address(arcUsdc), 100_500_001, keccak256(abi.encode("relay", uint256(1))));
        vm.expectEmit(address(nativeRoute));
        emit DustReturned(bytes32(uint256(7)), 123_456_788);
        vm.prank(address(sink));
        nativeRoute.send{value: total}(bytes32(uint256(7)), amountIn, fee, 100e6, q);
        assertEq(address(depository).balance, 100_500_001e12, "whole 6-dp units deposited");
        assertEq(address(sink).balance, sinkBefore - 100_500_001e12, "caller paid only the deposited part");
        assertEq(address(nativeRoute).balance, 0, "route keeps nothing");
    }

    /// @notice Any value >= 1e12: deposit = floor(value / 1e12) view units, the rest back to the caller, route empty.
    function testFuzzNativeSendConservesValue(uint256 amountIn, uint256 fee) public {
        amountIn = bound(amountIn, 1e12, 5_000 ether);
        fee = bound(fee, 0, 10 ether);
        uint256 total = amountIn + fee;
        bytes memory q = _quote(nativeRoute, bytes32(uint256(7)), amountIn, fee, 1, 1);
        uint256 sinkBefore = address(sink).balance;
        vm.prank(address(sink));
        nativeRoute.send{value: total}(bytes32(uint256(7)), amountIn, fee, 1, q);
        assertEq(address(depository).balance, (total / 1e12) * 1e12);
        assertEq(sinkBefore - address(sink).balance, (total / 1e12) * 1e12);
        assertEq(address(nativeRoute).balance, 0);
    }

    /// @notice Less than one 6-dp unit cannot be deposited: the send reverts instead of emitting a zero deposit.
    function testNativeSendBelowOneSixDecimalUnitReverts() public {
        bytes memory q = _quote(nativeRoute, bytes32(uint256(7)), 1e12 - 1, 0, 1, 1);
        vm.prank(address(sink));
        vm.expectRevert(RelayFundingRoute.BadValue.selector);
        nativeRoute.send{value: 1e12 - 1}(bytes32(uint256(7)), 1e12 - 1, 0, 1, q);
    }

    /// @notice A caller that refuses the remainder fails the whole send (nothing deposited, nonce not used).
    function testNativeSendRevertsWhenTheCallerRefusesTheRemainder() public {
        address noReceive = address(new RelayDepositoryV2Stub()); // no receive/fallback
        RelayFundingRoute r = new RelayFundingRoute(
            RelayFundingRoute.Config(
                noReceive, address(0), vault, 4663, address(depository), vm.addr(SIGNER), executor, address(arcUsdc)
            )
        );
        vm.deal(noReceive, 2 ether);
        bytes memory q = _quote(r, bytes32(uint256(7)), 1 ether + 1, 0, 1e6, 1);
        uint256 snap = vm.snapshotState(); // the view stub's vm.deal survives a revert (the real precompile's would not)
        vm.prank(noReceive);
        vm.expectRevert(RelayFundingRoute.DepositFailed.selector);
        r.send{value: 1 ether + 1}(bytes32(uint256(7)), 1 ether + 1, 0, 1e6, q);
        assertFalse(r.nonceUsed(1));
        vm.revertToState(snap);
        // aligned values never need the caller to accept anything
        q = _quote(r, bytes32(uint256(7)), 1 ether, 0, 1e6, 2);
        uint256 before = address(depository).balance;
        vm.prank(noReceive);
        r.send{value: 1 ether}(bytes32(uint256(7)), 1 ether, 0, 1e6, q);
        assertEq(address(depository).balance - before, 1 ether);
        assertTrue(r.nonceUsed(2));
    }

    /// @notice Native routes must name the ERC-20 view; token routes must not.
    function testConfigRequiresTheNativeViewExactlyForNativeRoutes() public {
        vm.expectRevert();
        new RelayFundingRoute(
            RelayFundingRoute.Config(hub, address(0), vault, 4663, address(depository), vm.addr(SIGNER), executor, address(0))
        );
        vm.expectRevert();
        new RelayFundingRoute(
            RelayFundingRoute.Config(
                vault, address(usdg), hub, 5042, address(depository), vm.addr(SIGNER), address(0), address(arcUsdc)
            )
        );
    }

    /// @notice A depository without the v2 entry point (or one that reverts) fails the send instead of losing money.
    function testSendRevertsWhenTheDepositoryRejects() public {
        RelayFundingRoute bad = new RelayFundingRoute(
            RelayFundingRoute.Config(
                address(sink), address(0), vault, 4663, address(usdg), vm.addr(SIGNER), executor, address(arcUsdc)
            )
        );
        bytes memory q = _quote(bad, bytes32(uint256(7)), 1 ether, 0, 1e6, 1);
        vm.prank(address(sink));
        vm.expectRevert(RelayFundingRoute.DepositFailed.selector);
        bad.send{value: 1 ether}(bytes32(uint256(7)), 1 ether, 0, 1e6, q);
    }

    function testQuoteBindsRefAmountsMinOutNonceAndDeadline() public {
        bytes memory q = _quote(nativeRoute, bytes32(uint256(7)), 100 ether, 0.5 ether, 100e6, 1);
        vm.startPrank(address(sink));
        vm.expectRevert(RelayFundingRoute.BadQuote.selector);
        nativeRoute.send{value: 100.5 ether}(bytes32(uint256(8)), 100 ether, 0.5 ether, 100e6, q);
        vm.expectRevert(RelayFundingRoute.BadQuote.selector);
        nativeRoute.send{value: 100.5 ether}(bytes32(uint256(7)), 100 ether, 0.5 ether, 99e6, q);
        vm.expectRevert(RelayFundingRoute.BadQuote.selector);
        nativeRoute.send{value: 100.6 ether}(bytes32(uint256(7)), 100 ether, 0.6 ether, 100e6, q);
        vm.expectRevert(RelayFundingRoute.BadValue.selector);
        nativeRoute.send{value: 100 ether}(bytes32(uint256(7)), 100 ether, 0.5 ether, 100e6, q);
        nativeRoute.send{value: 100.5 ether}(bytes32(uint256(7)), 100 ether, 0.5 ether, 100e6, q);
        vm.expectRevert(RelayFundingRoute.BadQuote.selector);
        nativeRoute.send{value: 100.5 ether}(bytes32(uint256(7)), 100 ether, 0.5 ether, 100e6, q);
        vm.stopPrank();
        bytes memory late = _quote(nativeRoute, bytes32(uint256(9)), 1 ether, 0, 1e6, 2);
        vm.warp(block.timestamp + 61);
        vm.prank(address(sink));
        vm.expectRevert(RelayFundingRoute.BadQuote.selector);
        nativeRoute.send{value: 1 ether}(bytes32(uint256(9)), 1 ether, 0, 1e6, late);
    }

    function testOnlyTheFixedCallerSendsAndOnlyTheExecutorCreditsReturns() public {
        bytes memory q = _quote(nativeRoute, bytes32(uint256(7)), 1 ether, 0, 1e6, 1);
        vm.deal(address(this), 2 ether);
        vm.expectRevert(RelayFundingRoute.NotCaller.selector);
        nativeRoute.send{value: 1 ether}(bytes32(uint256(7)), 1 ether, 0, 1e6, q);
        vm.expectRevert(RelayFundingRoute.NotExecutor.selector);
        nativeRoute.receiveReturnFor{value: 1 ether}(bytes32(uint256(7)));
        vm.deal(executor, 1 ether);
        vm.prank(executor);
        nativeRoute.receiveReturnFor{value: 1 ether}(bytes32(uint256(7)));
        assertEq(sink.lastRef(), bytes32(uint256(7)));
        assertEq(sink.lastValue(), 1 ether);
    }

    /// @notice r12 (F1): token money goes through `depositErc20(caller, token, amount, requestId)`; no allowance is left.
    function testTokenSendCallsDepositErc20WithTheSignedRequestId() public {
        usdg.mint(vault, 500e6);
        vm.prank(vault);
        usdg.approve(address(tokenRoute), 500e6);
        bytes memory q = _quote(tokenRoute, bytes32(uint256(3)), 500e6, 0, 499e18, 1);
        vm.expectEmit(address(depository));
        emit RelayErc20Deposit(vault, address(usdg), 500e6, keccak256(abi.encode("relay", uint256(1))));
        vm.prank(vault);
        tokenRoute.send(bytes32(uint256(3)), 500e6, 0, 499e18, q);
        assertEq(usdg.balanceOf(address(depository)), 500e6);
        assertEq(usdg.balanceOf(vault), 0);
        assertEq(usdg.balanceOf(address(tokenRoute)), 0);
        assertEq(usdg.allowance(address(tokenRoute), address(depository)), 0);
        bytes memory q2 = _quote(tokenRoute, bytes32(uint256(4)), 1, 0, 1, 2);
        vm.deal(vault, 1);
        vm.prank(vault);
        vm.expectRevert(RelayFundingRoute.BadValue.selector);
        tokenRoute.send{value: 1}(bytes32(uint256(4)), 1, 0, 1, q2);
    }
}

contract SellRouteTest is StockSystemBase {
    SolonStockSellRoute sellRoute;
    address converter = address(0xC0DE);
    bytes32 constant ORDER = keccak256("sale-1");

    function setUp() public override {
        super.setUp();
        sellRoute = new SolonStockSellRoute(address(hub), converter, ops);
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

    function testUnknownUntilProceedsReturnThenPaysGrossLessServiceFeeToppedUpFromOpsFees() public {
        uint256 hubId = _request(1 ether);
        assertEq(token.balanceOf(converter), 0);
        assertEq(uint8(hub.getOrder(hubId).status), uint8(HubSettlement.Status.Dispatched));
        vm.prank(converter);
        (uint8 st, uint256 paid, uint256 reminted) = sellRoute.claimSell(ORDER, "");
        assertEq(st, 0);
        _deliverLatestOrder();
        _deliverLatestResult();
        vm.prank(converter);
        (st,,) = sellRoute.claimSell(ORDER, "");
        assertEq(st, 0, "sold on RH, proceeds not back yet");
        vault.returnFunds(bytes32(hubId), 997e18, "ok");
        vm.deal(address(this), 1_000 ether);
        returnRoute.complete{value: 997.2e18}(0, payable(address(route)), 997.2e18);
        uint256 before = converter.balance;
        vm.prank(converter);
        (st, paid, reminted) = sellRoute.claimSell(ORDER, "");
        assertEq(st, 1);
        assertEq(paid, 997.5e18 - 2.49375e18, "gross less the 25 bps service fee; Ops covers the route leg");
        assertEq(reminted, 0);
        assertEq(converter.balance, before + paid);
        assertEq(ops.balance, 1 ether - 0.01 ether - 0.3 ether, "unused Ops fees go back to Ops");
        vm.prank(converter);
        vm.expectRevert();
        sellRoute.claimSell(ORDER, "");
    }

    function testSaleFailureReturnsTheExactRawToTheConverter() public {
        venue.setFail(true);
        _request(1 ether);
        _deliverLatestOrder();
        _deliverLatestResult();
        vm.prank(converter);
        (uint8 st, uint256 paid, uint256 reminted) = sellRoute.claimSell(ORDER, "");
        assertEq(st, 2);
        assertEq(paid, 0);
        assertEq(reminted, 9.975e18);
        assertEq(token.balanceOf(converter), 9.975e18);
    }

    function testOnlyTheFixedConverterAndReceiver() public {
        vm.expectRevert(SolonStockSellRoute.NotConverter.selector);
        sellRoute.requestSell(ORDER, address(token), 1, 1, converter, RELAY);
        vm.prank(converter);
        vm.expectRevert(SolonStockSellRoute.NotConverter.selector);
        sellRoute.requestSell{value: 1 ether}(ORDER, address(token), 1, 1, address(0xBAD), RELAY);
        vm.prank(converter);
        vm.expectRevert(SolonStockSellRoute.BadOrder.selector);
        sellRoute.requestSell{value: 1 ether}(ORDER, address(0xBAD), 1, 1, converter, RELAY);
        _request(1 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert(SolonStockSellRoute.NotConverter.selector);
        sellRoute.claimSell(ORDER, "");
    }
}
