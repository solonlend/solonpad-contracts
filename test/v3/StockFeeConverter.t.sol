// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FloorOracleStub, FLOOR_ORACLE} from "./helpers/OracleMocks.sol";
import {Test} from "forge-std/Test.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {LedgerStock, LedgerReceiver} from "./V3FeeLedger.t.sol";
import {StockFeeConverter} from "../../src/v3/StockFeeConverter.sol";

contract StockSellRouteMock {
    bool public lie;

    function setLie(bool yes) external {
        lie = yes;
    }
    uint256 public gross;
    uint256 public nativeOut;
    uint256 public rawOut;
    uint8 public result;
    address public asset;

    function requestSell(bytes32, address a, uint256 raw, uint256 minGross, address receiver, bytes32)
        external
        payable
    {
        gross = minGross;
        asset = a;
        require(receiver == msg.sender);
        LedgerStock(a).transferFrom(msg.sender, address(this), raw);
    }

    function configure(uint8 status, uint256 amount, uint256 remint) external {
        result = status;
        nativeOut = amount;
        rawOut = remint;
    }

    /// @dev The pre-2026-09-30 $1,000 single-order limit these unit tests were written against.
    function runLimit() external pure returns (uint256) {
        return 1000 ether;
    }

    function claimSell(bytes32, bytes calldata) external returns (uint8, uint256, uint256) {
        if (nativeOut != 0 && !lie) {
            (bool ok,) = msg.sender.call{value: nativeOut}("");
            require(ok);
        }
        if (rawOut != 0) LedgerStock(asset).mint(msg.sender, rawOut);
        return (result, nativeOut, rawOut);
    }
    receive() external payable {}
}

contract ConverterDestination {
    mapping(bytes32 => uint256) public credits;

    function fundFromConverter(bytes32 id) external payable {
        require(credits[id] == 0);
        credits[id] = msg.value;
    }
}

contract StockFeeConverterTest is Test {
    V3FeeLedger ledger;
    LedgerStock stock;
    LedgerReceiver receiver;
    bytes32 constant POOL = keccak256("pool");

    function setUp() public {
        vm.etch(FLOOR_ORACLE, type(FloorOracleStub).runtimeCode);
        ledger = new V3FeeLedger(address(this), address(0));
        stock = new LedgerStock();
        receiver = new LedgerReceiver();
        address[6] memory beneficiaries;
        for (uint256 i; i < 6; i++) {
            beneficiaries[i] = address(receiver);
        }
        beneficiaries[4] = address(this);
        beneficiaries[5] = address(this);
        ledger.registerPool(POOL, address(stock), 1, address(this), beneficiaries);
        stock.mint(address(this), 10000);
        stock.approve(address(ledger), 10000);
    }

    function test_LotCustodyCannotOverlapGenericClaim() public {
        (bool ok,) = address(ledger).call(abi.encodeWithSignature("enableStockLotCustody(bytes32,uint8)", POOL, 4));
        assertTrue(ok, "lot custody not implemented");
        ledger.creditStock(POOL, 10000);
        vm.expectRevert();
        ledger.claim(POOL, 4, 1000);
        (ok,) = address(ledger).call(abi.encodeWithSignature("claimStockLot(bytes32,uint256,uint8)", POOL, 1, 4));
        assertTrue(ok);
        assertEq(stock.balanceOf(address(this)), 1000);
        assertEq(ledger.accrued(POOL, 4), 0);
        (ok,) = address(ledger).call(abi.encodeWithSignature("claimStockLot(bytes32,uint256,uint8)", POOL, 1, 4));
        assertFalse(ok);
    }

    function test_ReserveOnlyActualLedgerBuckets() public {
        StockFeeConverter c = new StockFeeConverter(
            ledger,
            address(this),
            address(receiver),
            address(receiver),
            address(receiver),
            address(this),
            25,
            1,
            bytes32(uint256(1)),
            address(this),
            FLOOR_ORACLE
        );
        bytes32 p = keccak256("converter");
        address[6] memory b;
        for (uint256 i; i < 6; i++) {
            b[i] = address(receiver);
        }
        b[4] = address(c);
        b[5] = address(c);
        ledger.registerPool(p, address(stock), 1, address(this), b);
        c.enablePool(p, 4);
        c.enablePool(p, 5);
        ledger.creditStock(p, 10000);
        bytes32 id = c.reserve(p, 1, 4);
        assertEq(c.lotRaw(id), 1000, "actual lot missing");
        assertEq(stock.balanceOf(address(c)), 1000);
        vm.expectRevert();
        c.reserve(p, 1, 0);
        vm.expectRevert();
        c.reserve(p, 1, 4);
        assertEq(ledger.accrued(p, 0), 5750);
        assertEq(ledger.accrued(p, 5), 750);
    }

    function _ready()
        internal
        returns (
            StockFeeConverter c,
            StockSellRouteMock r,
            ConverterDestination b,
            ConverterDestination p,
            bytes32[] memory ids
        )
    {
        r = new StockSellRouteMock();
        b = new ConverterDestination();
        p = new ConverterDestination();
        c = new StockFeeConverter(
            ledger,
            vm.addr(777),
            address(r),
            address(b),
            address(p),
            address(this),
            25,
            1,
            bytes32(uint256(1)),
            address(this),
            FLOOR_ORACLE
        );
        bytes32 pool = keccak256("sell");
        address[6] memory bs;
        for (uint256 j; j < 6; j++) {
            bs[j] = address(receiver);
        }
        bs[4] = address(c);
        bs[5] = address(c);
        ledger.registerPool(pool, address(stock), 1, address(this), bs);
        c.enablePool(pool, 4);
        c.enablePool(pool, 5);
        ledger.creditStock(pool, 10000);
        ids = new bytes32[](2);
        ids[0] = c.reserve(pool, 1, 4);
        ids[1] = c.reserve(pool, 1, 5);
        if (ids[0] > ids[1]) (ids[0], ids[1]) = (ids[1], ids[0]);
    }

    function _quote(StockFeeConverter, bytes32[] memory ids) internal view returns (StockFeeConverter.Quote memory q) {
        q = StockFeeConverter.Quote(
            keccak256("order"),
            address(stock),
            keccak256(abi.encode(ids)),
            1750,
            98 ether,
            99 ether,
            block.timestamp,
            block.timestamp + 60,
            0,
            1 ether
        );
    }

    function _sig(StockFeeConverter c, StockFeeConverter.Quote memory q) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(777, c.quoteDigest(q));
        return abi.encodePacked(r, s, v);
    }

    /// @dev r7: the signer cannot value a lot more than 1% under the Chainlink execution price; no Live price, no sale.
    function test_R7OracleFloorOnSignedSaleValue() public {
        (StockFeeConverter c,,,, bytes32[] memory ids) = _ready();
        StockFeeConverter.Quote memory q = _quote(c, ids); // 1750 raw valued at $99
        vm.deal(address(this), 10 ether);
        c.depositFees{value: 1 ether}(q.orderId);
        bytes memory sig = _sig(c, q);
        FloorOracleStub(FLOOR_ORACLE).setPrice(address(stock), uint256(101e36) / 1750); // oracle says ~$101
        vm.expectRevert(bytes("oracle floor"));
        c.submit(q, ids, sig);
        FloorOracleStub(FLOOR_ORACLE).setDown(true);
        vm.expectRevert(bytes("PriceNotLive"));
        c.submit(q, ids, sig);
        FloorOracleStub(FLOOR_ORACLE).setDown(false);
        FloorOracleStub(FLOOR_ORACLE).setPrice(address(stock), uint256(100e36) / 1750); // ~$100: $99 is within 1%
        c.submit(q, ids, sig);
        assertEq(c.lotRaw(ids[0]) + c.lotRaw(ids[1]), 1750);
    }

    function test_SignedSaleGrossCeilActualReceiptsAndFixedDestinations() public {
        (
            StockFeeConverter c,
            StockSellRouteMock r,
            ConverterDestination b,
            ConverterDestination p,
            bytes32[] memory ids
        ) = _ready();
        StockFeeConverter.Quote memory q = _quote(c, ids);
        vm.deal(address(this), 10 ether);
        c.depositFees{value: 1 ether}(q.orderId);
        c.submit(q, ids, _sig(c, q));
        assertEq(stock.balanceOf(address(r)), 1750, "sale not submitted");
        uint256 gross = ((q.minUSDC18 * 10000 + 9974) / 9975 + 1e12 - 1) / 1e12 * 1e12;
        assertEq(r.gross(), gross);
        vm.deal(address(r), 100 ether);
        r.configure(1, 100 ether, 0);
        c.applyResult(q.orderId, "");
        c.route(q.orderId);
        assertEq(address(b).balance + address(p).balance, 100 ether);
        assertEq(address(b).balance, uint256(100 ether) * 1000 / 1750);
        assertEq(address(p).balance, uint256(100 ether) * 750 / 1750 + 1);
        vm.expectRevert();
        c.applyResult(q.orderId, "");
        vm.expectRevert();
        c.route(q.orderId);
    }

    function test_UnknownQuarantineNoResaleAndVerifiedRemintRetry() public {
        (StockFeeConverter c, StockSellRouteMock r,,, bytes32[] memory ids) = _ready();
        StockFeeConverter.Quote memory q = _quote(c, ids);
        q.fees18 = 0;
        c.submit(q, ids, _sig(c, q));
        r.configure(0, 0, 0);
        c.applyResult(q.orderId, "");
        (, uint8 state,,,) = c.orders(q.orderId);
        assertEq(state, 6);
        q.orderId = keccak256("retry");
        q.nonce = 1;
        bytes memory signature = _sig(c, q);
        vm.expectRevert();
        c.submit(q, ids, signature);
        bytes32 old = keccak256("order");
        r.configure(2, 0, 0);
        vm.expectRevert();
        c.applyResult(old, "");
        r.configure(2, 0, 1750);
        c.applyResult(old, "");
        assertEq(stock.balanceOf(address(c)), 1750);
        c.submit(q, ids, _sig(c, q));
        assertEq(stock.balanceOf(address(c)), 0);
        vm.expectRevert();
        c.applyResult(old, "");
    }

    function test_ControlledNativeClaimCannotBeFrontRun() public {
        bytes32 p = keccak256("native");
        address[6] memory b;
        for (uint256 j; j < 6; j++) {
            b[j] = address(receiver);
        }
        b[4] = address(this);
        ledger.registerPool(p, address(0), 0, address(this), b);
        (bool ok,) = address(ledger).call(abi.encodeWithSignature("enableControlledClaim(bytes32,uint8)", p, 4));
        assertTrue(ok, "controlled native claim missing");
        vm.deal(address(this), 1 ether);
        ledger.creditNative{value: 1 ether}(p);
        vm.prank(address(99));
        vm.expectRevert();
        ledger.claim(p, 4, 0.1 ether);
        assertTrue(ledger.claim(p, 4, 0.1 ether));
    }
    receive() external payable {}

    function test_NetShortageQuarantinesActualCashWithoutResale() public {
        (StockFeeConverter c, StockSellRouteMock r,,, bytes32[] memory ids) = _ready();
        StockFeeConverter.Quote memory q = _quote(c, ids);
        q.fees18 = 0;
        c.submit(q, ids, _sig(c, q));
        vm.deal(address(r), 97 ether);
        r.configure(1, 97 ether, 0);
        c.applyResult(q.orderId, "");
        (, uint8 state,,, uint256 paid) = c.orders(q.orderId);
        assertEq(state, 6);
        assertEq(paid, 97 ether);
        assertEq(address(c).balance, 97 ether);
        vm.expectRevert();
        c.route(q.orderId);
        vm.expectRevert();
        c.applyResult(q.orderId, "");
    }

    function test_SignatureCannotChangeAmountsOrExceedHardLimitOrFreshness() public {
        (StockFeeConverter c,,,, bytes32[] memory ids) = _ready();
        StockFeeConverter.Quote memory q = _quote(c, ids);
        q.fees18 = 0;
        bytes memory sig = _sig(c, q);
        q.minUSDC18++;
        vm.expectRevert();
        c.submit(q, ids, sig);
        q = _quote(c, ids);
        q.value18 = 1001 ether;
        q.minUSDC18 = 1001 ether;
        q.fees18 = 0;
        sig = _sig(c, q);
        vm.expectRevert();
        c.submit(q, ids, sig);
        q = _quote(c, ids);
        q.deadline = q.issuedAt + 61;
        q.fees18 = 0;
        sig = _sig(c, q);
        vm.expectRevert();
        c.submit(q, ids, sig);
        q = _quote(c, ids);
        q.fees18 = 0;
        sig = _sig(c, q);
        vm.warp(q.deadline + 1);
        vm.expectRevert();
        c.submit(q, ids, sig);
    }

    function test_MissingOpsFeesAndDuplicateSlicesKeepRawIntact() public {
        (StockFeeConverter c,,,, bytes32[] memory ids) = _ready();
        StockFeeConverter.Quote memory q = _quote(c, ids);
        bytes memory sig = _sig(c, q);
        vm.expectRevert();
        c.submit(q, ids, sig);
        assertEq(stock.balanceOf(address(c)), 1750);
        q.fees18 = 0;
        ids[1] = ids[0];
        q.slicesHash = keccak256(abi.encode(ids));
        sig = _sig(c, q);
        vm.expectRevert();
        c.submit(q, ids, sig);
        assertEq(stock.balanceOf(address(c)), 1750);
    }

    function testFuzz_GrossFloorProtectsNetAfterFeeAndSixDecimalTruncation(uint96 seed) public {
        (StockFeeConverter c,,,,) = _ready();
        uint256 net = bound(uint256(seed), 1, 1000 ether);
        uint256 gross = c.grossFloor(net);
        assertEq(gross % 1e12, 0);
        assertGe(gross * 9975 / 10000, net);
        if (gross >= 1e12) assertLt((gross - 1e12) * 9975 / 10000, net);
    }

    function testFuzz_LargestRemainderConservesActualNet(uint96 seed) public {
        (
            StockFeeConverter c,
            StockSellRouteMock r,
            ConverterDestination b,
            ConverterDestination p,
            bytes32[] memory ids
        ) = _ready();
        StockFeeConverter.Quote memory q = _quote(c, ids);
        q.fees18 = 0;
        c.submit(q, ids, _sig(c, q));
        uint256 paid = bound(uint256(seed), 98 ether, 1000 ether);
        vm.deal(address(r), paid);
        r.configure(1, paid, 0);
        c.applyResult(q.orderId, "");
        c.route(q.orderId);
        assertEq(address(b).balance + address(p).balance, paid);
        assertApproxEqAbs(address(b).balance, paid * 1000 / 1750, 1);
        assertApproxEqAbs(address(p).balance, paid * 750 / 1750, 1);
    }

    function test_OnlyActualOpsSubsidyCanReleaseFinalShortfall() public {
        (
            StockFeeConverter c,
            StockSellRouteMock r,
            ConverterDestination b,
            ConverterDestination p,
            bytes32[] memory ids
        ) = _ready();
        StockFeeConverter.Quote memory q = _quote(c, ids);
        q.fees18 = 0;
        c.submit(q, ids, _sig(c, q));
        vm.deal(address(r), 97 ether);
        r.configure(1, 97 ether, 0);
        c.applyResult(q.orderId, "");
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(c).call{value: 1 ether}(abi.encodeWithSignature("subsidizeShortfall(bytes32)", q.orderId));
        assertTrue(ok, "actual Ops recovery missing");
        c.route(q.orderId);
        assertEq(address(b).balance + address(p).balance, 98 ether);
        assertTrue(c.routePaused());
    }

    function test_LargeFeeLotCanSplitUnderDollarCapWithoutCreatingRaw() public {
        (StockFeeConverter c, StockSellRouteMock r,,, bytes32[] memory ids) = _ready();
        bytes32 parent = ids[0];
        uint256 original = c.lotRaw(parent);
        uint256 part = original / 2;
        vm.prank(vm.addr(777));
        bytes32 child = c.splitLot(parent, part);
        assertEq(c.lotRaw(child), part, "missing bounded stock slice");
        assertEq(c.lotRaw(parent) + c.lotRaw(child), original);
        bytes32[] memory one = new bytes32[](1);
        one[0] = child;
        StockFeeConverter.Quote memory q = _quote(c, one);
        q.raw = part;
        q.value18 = 999 ether;
        q.minUSDC18 = 990 ether;
        q.fees18 = 0;
        c.submit(q, one, _sig(c, q));
        assertEq(stock.balanceOf(address(r)), part);
        assertEq(stock.balanceOf(address(c)), 1750 - part);
        vm.expectRevert();
        c.splitLot(child, 1);
    }

    function test_UnbackedFinalResultCannotConsumeOrder() public {
        (StockFeeConverter c, StockSellRouteMock r,,, bytes32[] memory ids) = _ready();
        StockFeeConverter.Quote memory q = _quote(c, ids);
        q.fees18 = 0;
        c.submit(q, ids, _sig(c, q));
        r.configure(1, 100 ether, 0);
        r.setLie(true);
        vm.expectRevert();
        c.applyResult(q.orderId, "");
        assertFalse(c.finalResult(q.orderId));
        (, uint8 state,,,) = c.orders(q.orderId);
        assertEq(state, 3);
    }

    function test_RegistrationAtomicallyEnablesStockCustodyBeforeFirstFee() public {
        StockSellRouteMock r = new StockSellRouteMock();
        StockFeeConverter c = new StockFeeConverter(
            ledger,
            address(this),
            address(r),
            address(receiver),
            address(receiver),
            address(this),
            25,
            1,
            bytes32(uint256(1)),
            address(this),
            FLOOR_ORACLE
        );
        bytes32 p = keccak256("atomic admission");
        address[6] memory b;
        for (uint256 j; j < 6; j++) {
            b[j] = address(receiver);
        }
        b[4] = address(c);
        b[5] = address(c);
        ledger.registerPool(p, address(stock), 1, address(this), b);
        assertTrue(ledger.stockLotCustody(p, 4), "registration did not enable custody");
        assertTrue(ledger.stockLotCustody(p, 5));
        ledger.creditStock(p, 10000);
        vm.expectRevert();
        ledger.claim(p, 4, 1000);
        bytes32 id = c.reserve(p, 1, 4);
        assertEq(c.lotRaw(id), 1000);
    }

    function test_RouteRecoveryRequiresActualShortfallCoverageAnd48HourReview() public {
        (StockFeeConverter c, StockSellRouteMock r,,, bytes32[] memory ids) = _ready();
        StockFeeConverter.Quote memory q = _quote(c, ids);
        q.fees18 = 0;
        c.submit(q, ids, _sig(c, q));
        vm.deal(address(r), 97 ether);
        r.configure(1, 97 ether, 0);
        c.applyResult(q.orderId, "");
        bytes memory schedule =
            abi.encodeWithSignature("scheduleRouteResume(bytes32)", keccak256("independent route investigation"));
        (bool ok,) = address(c).call(schedule);
        assertFalse(ok);
        vm.deal(address(this), 1 ether);
        c.subsidizeShortfall{value: 1 ether}(q.orderId);
        vm.prank(address(55));
        (ok,) = address(c).call(schedule);
        assertFalse(ok);
        (ok,) = address(c).call(schedule);
        assertTrue(ok, "review recovery not implemented");
        bytes memory resume = abi.encodeWithSignature("resumeRoute()");
        (ok,) = address(c).call(resume);
        assertFalse(ok);
        vm.warp(block.timestamp + 48 hours);
        (ok,) = address(c).call(resume);
        assertTrue(ok);
        assertFalse(c.routePaused());
        vm.expectRevert();
        c.applyResult(q.orderId, "");
    }
}
