// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {FloorOracleStub, FLOOR_ORACLE} from "../../helpers/OracleMocks.sol";
import {V3FeeLedger} from "../../../../src/v3/V3FeeLedger.sol";
import {StockFeeConverter} from "../../../../src/v3/StockFeeConverter.sol";
import {LedgerReceiver} from "../../V3FeeLedger.t.sol";
import {ConverterDestination} from "../../StockFeeConverter.t.sol";
import {CovCToken, CovCMockLedger} from "./CovCMocks.sol";

/// @notice Programmable IStockSellRoute.
contract CovCStockRoute {
    CovCToken token;
    uint256 public pullShort;
    uint8 public status;
    uint256 public paid;
    uint256 public sendPaid;
    uint256 public reminted;
    uint256 public mintAmount;

    constructor(CovCToken t) {
        token = t;
    }

    function setPullShort(uint256 s) external {
        pullShort = s;
    }

    function configure(uint8 st, uint256 paid_, uint256 send_, uint256 rem_, uint256 mint_) external {
        status = st;
        paid = paid_;
        sendPaid = send_;
        reminted = rem_;
        mintAmount = mint_;
    }

    function runLimit() external pure returns (uint256) {
        return 1000 ether;
    }

    function requestSell(bytes32, address, uint256 raw, uint256, address, bytes32) external payable {
        token.transferFrom(msg.sender, address(this), raw - pullShort);
    }

    function claimSell(bytes32, bytes calldata) external returns (uint8, uint256, uint256) {
        if (sendPaid != 0) {
            (bool ok,) = msg.sender.call{value: sendPaid}("");
            require(ok, "route pay");
        }
        if (mintAmount != 0) token.mint(msg.sender, mintAmount);
        return (status, paid, reminted);
    }

    function poke(address payable to) external payable {
        (bool ok,) = to.call{value: msg.value}("");
        require(ok, "poke failed");
    }

    receive() external payable {}
}

contract CovCStockFeeConverterTest is Test {
    V3FeeLedger ledger;
    CovCToken stock;
    LedgerReceiver receiver;
    CovCStockRoute route;
    ConverterDestination buyback;
    ConverterDestination protocol;
    StockFeeConverter c;
    bytes32[] ids;
    bytes32 constant POOL = keccak256("sell");
    uint256 constant SIGNER = 777;

    function setUp() public {
        vm.etch(FLOOR_ORACLE, type(FloorOracleStub).runtimeCode);
        ledger = new V3FeeLedger(address(this), address(0));
        stock = new CovCToken();
        receiver = new LedgerReceiver();
        route = new CovCStockRoute(stock);
        buyback = new ConverterDestination();
        protocol = new ConverterDestination();
        c = new StockFeeConverter(
            ledger,
            vm.addr(SIGNER),
            address(route),
            address(buyback),
            address(protocol),
            address(this),
            25,
            1,
            bytes32(uint256(1)),
            address(this),
            FLOOR_ORACLE
        );
        address[6] memory bs;
        for (uint256 j; j < 6; j++) {
            bs[j] = address(receiver);
        }
        bs[4] = address(c);
        bs[5] = address(c);
        ledger.registerPool(POOL, address(stock), 1, address(this), bs);
        stock.mint(address(this), 10000);
        stock.approve(address(ledger), 10000);
        ledger.creditStock(POOL, 10000);
        bytes32 a = c.reserve(POOL, 1, 4);
        bytes32 b = c.reserve(POOL, 1, 5);
        if (a > b) (a, b) = (b, a);
        ids.push(a);
        ids.push(b);
        vm.deal(address(route), 1000 ether);
    }

    receive() external payable {}

    function _q() internal view returns (StockFeeConverter.Quote memory q) {
        bytes32[] memory m = ids;
        q = StockFeeConverter.Quote(
            keccak256("order"),
            address(stock),
            keccak256(abi.encode(m)),
            1750,
            98 ether,
            99 ether,
            block.timestamp,
            block.timestamp + 60,
            0,
            0
        );
    }

    function _sig(StockFeeConverter.Quote memory q) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER, c.quoteDigest(q));
        return abi.encodePacked(r, s, v);
    }

    function _expectSubmitRevert(StockFeeConverter.Quote memory q, bytes32[] memory list) internal {
        bytes memory sig = _sig(q);
        vm.expectRevert();
        c.submit(q, list, sig);
        (, uint8 st,,,) = c.orders(q.orderId);
        assertEq(st, 0);
        assertEq(stock.balanceOf(address(c)), 1750);
    }

    /// L105 both arms: a (pool, feeLot, bucket) lot is reserved once.
    function test_ReserveOnce() public {
        (address asset, uint8 bucket, uint8 st, uint256 raw,) = c.lots(ids[0]);
        assertEq(asset, address(stock));
        assertEq(st, 1);
        assertTrue(bucket == 4 || bucket == 5);
        assertTrue(raw == 1000 || raw == 750);
        vm.expectRevert();
        c.reserve(POOL, 1, 4);
        vm.expectRevert();
        c.reserve(POOL, 1, 5);
    }

    /// L108 false arm (needs a misbehaving ledger): zero lot, or short delivery vs reported raw.
    function test_ReserveRequiresActualDelivery() public {
        CovCMockLedger ml = new CovCMockLedger();
        StockFeeConverter mc = new StockFeeConverter(
            V3FeeLedger(payable(address(ml))),
            vm.addr(SIGNER),
            address(route),
            address(buyback),
            address(protocol),
            address(this),
            25,
            1,
            bytes32(uint256(1)),
            address(this),
            FLOOR_ORACLE
        );
        address[6] memory b;
        b[4] = address(mc);
        ml.setPool(POOL, address(stock), 1, address(1), b);
        stock.mint(address(ml), 100);
        ml.setLot(0, 0);
        vm.expectRevert();
        mc.reserve(POOL, 1, 4);
        ml.setLot(10, 9);
        vm.expectRevert();
        mc.reserve(POOL, 1, 4);
        ml.setLot(10, 10);
        bytes32 id = mc.reserve(POOL, 1, 4);
        assertEq(mc.lotRaw(id), 10);
        // wrong bucket / wrong settlement kind
        vm.expectRevert();
        mc.reserve(POOL, 2, 3);
        ml.setPool(POOL, address(stock), 0, address(1), b);
        vm.expectRevert();
        mc.reserve(POOL, 2, 4);
    }

    /// L160 both arms.
    function test_ReceiveSellRouteOnly() public {
        vm.deal(address(this), 1);
        (bool ok,) = address(c).call{value: 1}("");
        assertFalse(ok);
        route.poke{value: 1}(payable(address(c)));
        assertEq(address(c).balance, 1);
    }

    /// L164 both arms: ops fees can be pre-funded only before the order exists.
    function test_DepositFeesBeforeSubmitOnly() public {
        StockFeeConverter.Quote memory q = _q();
        vm.deal(address(this), 2 ether);
        c.depositFees{value: 1 ether}(q.orderId);
        q.fees18 = 1 ether;
        c.submit(q, ids, _sig(q));
        assertEq(c.feeBalance(q.orderId), 0);
        assertEq(address(route).balance, 1001 ether);
        vm.expectRevert();
        c.depositFees{value: 1 ether}(q.orderId);
    }

    /// L169-L171 false arms: each structural precondition of submit.
    function test_SubmitStructuralGuards() public {
        StockFeeConverter.Quote memory q = _q();
        q.orderId = 0;
        _expectSubmitRevert(q, ids);
        q = _q();
        bytes32[] memory empty = new bytes32[](0);
        q.slicesHash = keccak256(abi.encode(empty));
        _expectSubmitRevert(q, empty);
        bytes32[] memory many = new bytes32[](17);
        q.slicesHash = keccak256(abi.encode(many));
        _expectSubmitRevert(q, many);
        q = _q();
        q.slicesHash = bytes32(uint256(123));
        _expectSubmitRevert(q, ids);
        q = _q();
        q.raw = 0;
        _expectSubmitRevert(q, ids);
        q = _q();
        q.minUSDC18 = 0;
        _expectSubmitRevert(q, ids);
        q = _q();
        q.value18 = 0;
        _expectSubmitRevert(q, ids);
        q = _q();
        q.value18 = 1000 ether + 1;
        q.minUSDC18 = 1000 ether;
        _expectSubmitRevert(q, ids);
    }

    /// L175 / L179 false arms: freshness, nonce, fee balance and signature.
    function test_SubmitFreshnessNonceFeesSignature() public {
        StockFeeConverter.Quote memory q = _q();
        q.issuedAt = block.timestamp + 1;
        q.deadline = block.timestamp + 30;
        _expectSubmitRevert(q, ids);
        q = _q();
        q.deadline = q.issuedAt + 61;
        _expectSubmitRevert(q, ids);
        q = _q();
        q.fees18 = 1;
        _expectSubmitRevert(q, ids);
        q = _q();
        bytes memory wrong;
        {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER + 1, c.quoteDigest(q));
            wrong = abi.encodePacked(r, s, v);
        }
        vm.expectRevert();
        c.submit(q, ids, wrong);
        // nonce reuse after a successful submit
        c.submit(q, ids, _sig(q));
        StockFeeConverter.Quote memory q2 = _q();
        q2.orderId = keccak256("order2");
        bytes memory sig2 = _sig(q2);
        vm.expectRevert();
        c.submit(q2, ids, sig2);
    }

    /// L182 both arms at the exact boundary: min >= ceil(value * (1 - fee) * 99%).
    function test_SubmitNetFloorBoundary() public {
        StockFeeConverter.Quote memory q = _q();
        // 99e18 * 9975 * 9900 / 1e8 = 97.764975e18 exactly
        q.minUSDC18 = 97.764975 ether - 1;
        _expectSubmitRevert(q, ids);
        q.minUSDC18 = 97.764975 ether;
        c.submit(q, ids, _sig(q));
        (, uint8 st,,,) = c.orders(q.orderId);
        assertEq(st, 3);
        assertEq(stock.balanceOf(address(route)), 1750);
    }

    /// L193 / L195 / L200 false arms: unsorted slices, unknown lot, raw mismatch.
    function test_SubmitSliceGuards() public {
        bytes32[] memory rev = new bytes32[](2);
        rev[0] = ids[1];
        rev[1] = ids[0];
        StockFeeConverter.Quote memory q = _q();
        q.slicesHash = keccak256(abi.encode(rev));
        _expectSubmitRevert(q, rev);
        bytes32[] memory unknown = new bytes32[](2);
        unknown[0] = ids[0];
        unknown[1] = bytes32(type(uint256).max);
        q = _q();
        q.slicesHash = keccak256(abi.encode(unknown));
        _expectSubmitRevert(q, unknown);
        q = _q();
        q.raw = 1749;
        _expectSubmitRevert(q, ids);
        q.raw = 1751;
        _expectSubmitRevert(q, ids);
        // wrong asset for the reserved lots
        q = _q();
        q.asset = address(0x1234);
        _expectSubmitRevert(q, ids);
    }

    /// L209 false arm: the route must take exactly the submitted raw.
    function test_SubmitRouteMustTakeAllRaw() public {
        route.setPullShort(1);
        StockFeeConverter.Quote memory q = _q();
        _expectSubmitRevert(q, ids);
        (,, uint8 st,,) = c.lots(ids[0]);
        assertEq(st, 1);
        assertFalse(c.nonceUsed(0));
    }

    /// L222 false arm: reported native/reminted must match actual receipts.
    function test_ApplyResultDeltas() public {
        StockFeeConverter.Quote memory q = _q();
        c.submit(q, ids, _sig(q));
        route.configure(1, 100 ether, 99 ether, 0, 0); // under-sent native
        vm.expectRevert();
        c.applyResult(q.orderId, "");
        route.configure(2, 0, 0, 1750, 1749); // under-minted raw
        vm.expectRevert();
        c.applyResult(q.orderId, "");
        route.configure(1, 100 ether, 101 ether, 0, 0); // over-sent native
        vm.expectRevert();
        c.applyResult(q.orderId, "");
        assertFalse(c.finalResult(q.orderId));
        route.configure(1, 100 ether, 100 ether, 0, 0);
        c.applyResult(q.orderId, "");
        (, uint8 st,,, uint256 actual) = c.orders(q.orderId);
        assertEq(st, 4);
        assertEq(actual, 100 ether);
    }

    /// L284 both arms: only a fully-settled order routes; proceeds go to the fixed bucket destinations.
    function test_RouteOnlySettledOrder() public {
        StockFeeConverter.Quote memory q = _q();
        vm.expectRevert();
        c.route(q.orderId);
        c.submit(q, ids, _sig(q));
        vm.expectRevert();
        c.route(q.orderId);
        route.configure(1, 175 ether, 175 ether, 0, 0);
        c.applyResult(q.orderId, "");
        c.route(q.orderId);
        assertEq(address(buyback).balance, 100 ether);
        assertEq(address(protocol).balance, 75 ether);
        assertEq(address(c).balance, 0);
        vm.expectRevert();
        c.route(q.orderId);
    }

    /// L169 paused arm: a shortfall pauses new submits until reviewed resume.
    function test_PausedRouteBlocksSubmit() public {
        StockFeeConverter.Quote memory q = _q();
        c.submit(q, ids, _sig(q));
        route.configure(1, 97 ether, 97 ether, 0, 0);
        c.applyResult(q.orderId, "");
        assertTrue(c.routePaused());
        // reserve a fresh lot to submit against
        stock.mint(address(this), 10000);
        stock.approve(address(ledger), 10000);
        ledger.creditStock(POOL, 10000);
        bytes32 fresh = c.reserve(POOL, 2, 4);
        bytes32[] memory one = new bytes32[](1);
        one[0] = fresh;
        StockFeeConverter.Quote memory q2 = _q();
        q2.orderId = keccak256("order2");
        q2.nonce = 1;
        q2.slicesHash = keccak256(abi.encode(one));
        q2.raw = 1000;
        bytes memory sig = _sig(q2);
        vm.expectRevert();
        c.submit(q2, one, sig);
        (,, uint8 st,,) = c.lots(fresh);
        assertEq(st, 1);
    }
}
