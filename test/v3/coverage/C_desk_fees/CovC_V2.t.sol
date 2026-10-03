// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V2FeeConverter} from "../../../../src/v3/V2FeeConverter.sol";
import {V2FeeIngress} from "../../../../src/v3/V2FeeIngress.sol";
import {V2PlatformRouter} from "../../../../src/v3/V2PlatformRouter.sol";
import {DeskRoyaltyConverter} from "../../../../src/v3/DeskRoyaltyConverter.sol";
import {V2StakingReceiver, V2BuybackReceiver} from "../../V2Ingress.t.sol";
import {LedgerStock} from "../../V3FeeLedger.t.sol";
import {CovCToken, CovCSwitchReceiver} from "./CovCMocks.sol";

/// @notice Programmable fixed sell route (IV2FixedSellRoute + asset()).
contract CovCV2Route {
    address public asset;
    uint24 public feePpm = 10000;
    bytes32 public path = bytes32(uint256(1));
    uint256 public output = 10 ether;
    bool public pull = true;
    bool public pay = true;

    constructor(address a) {
        asset = a;
    }

    function setFee(uint24 f) external {
        feePpm = f;
    }

    function setPath(bytes32 p) external {
        path = p;
    }

    function configure(uint256 out, bool pull_, bool pay_) external {
        output = out;
        pull = pull_;
        pay = pay_;
    }

    function sell(address token, uint256 raw, uint256, address recipient, bytes32) external payable returns (uint256) {
        if (pull) CovCToken(token).transferFrom(msg.sender, address(this), raw);
        if (pay) {
            (bool ok,) = recipient.call{value: output}("");
            require(ok, "route pay");
        }
        return output;
    }

    function poke(address payable to) external payable {
        (bool ok,) = to.call{value: msg.value}("");
        require(ok, "poke failed");
    }

    receive() external payable {}
}

contract CovCV2FeeConverterTest is Test {
    CovCToken token;
    CovCV2Route route;
    V2FeeConverter conv;
    uint256 constant SIGNER = 777;
    bool rejectNative;

    function setUp() public {
        token = new CovCToken();
        route = new CovCV2Route(address(token));
        conv = new V2FeeConverter(address(this), address(route), vm.addr(SIGNER), address(0x0B5), bytes32(uint256(1)), 1);
        vm.deal(address(route), 100 ether);
        token.mint(address(this), 100 ether);
        token.approve(address(conv), type(uint256).max);
    }

    receive() external payable {
        require(!rejectNative, "reject");
    }

    function _data(bytes32 id, uint256 raw, uint256 nonce, uint256 fees) internal view returns (bytes memory) {
        V2FeeConverter.Quote memory q = V2FeeConverter.Quote(
            id, address(token), raw, 9.9 ether, 10 ether, block.timestamp, block.timestamp + 60, nonce, fees
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER, conv.quoteDigest(q));
        return abi.encode(q, abi.encodePacked(r, s, v));
    }

    /// L54 false arm: lpFeePpm >= 100% or a path not matching the route is rejected.
    function test_ConstructorRouteBinding() public {
        CovCV2Route bad = new CovCV2Route(address(token));
        bad.setFee(1_000_000);
        vm.expectRevert();
        new V2FeeConverter(address(this), address(bad), vm.addr(1), address(1), bytes32(uint256(1)), 1);
        bad.setFee(999_999);
        bad.setPath(bytes32(uint256(2)));
        vm.expectRevert();
        new V2FeeConverter(address(this), address(bad), vm.addr(1), address(1), bytes32(uint256(1)), 1);
        V2FeeConverter good =
            new V2FeeConverter(address(this), address(bad), vm.addr(1), address(1), bytes32(uint256(2)), 1);
        assertEq(good.lpFeePpm(), 999_999);
    }

    /// L64 both arms.
    function test_ReceiveSellRouteOnly() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(conv).call{value: 1}("");
        assertFalse(ok);
        route.poke{value: 1}(payable(address(conv)));
        assertEq(address(conv).balance, 1);
    }

    /// L85 both arms: fees accrue before conversion and are frozen after it; fees are forwarded to the route.
    function test_DepositFeesUntilConverted() public {
        bytes32 id = keccak256("lot");
        vm.deal(address(this), 1 ether);
        conv.depositFees{value: 0.2 ether}(id);
        assertEq(conv.feeBalance(id), 0.2 ether);
        uint256 routeBefore = address(route).balance;
        uint256 out = conv.convert(id, address(token), 1 ether, _data(id, 1 ether, 1, 0.2 ether));
        assertEq(out, 10 ether);
        assertEq(conv.feeBalance(id), 0);
        assertEq(address(route).balance, routeBefore - 10 ether + 0.2 ether);
        vm.expectRevert();
        conv.depositFees{value: 0.1 ether}(id);
    }

    /// L116 false arm: fee-on-transfer pull from the router is rejected and nothing is consumed.
    function test_PullMustBeExact() public {
        bytes32 id = keccak256("lot");
        bytes memory data = _data(id, 1 ether, 1, 0);
        token.setShortFrom(address(this));
        vm.expectRevert();
        conv.convert(id, address(token), 1 ether, data);
        assertFalse(conv.converted(id));
        assertFalse(conv.nonceUsed(1));
        assertEq(token.balanceOf(address(this)), 100 ether);
    }

    /// L121 false arm: route that under-delivers native, or does not take the raw, is rejected.
    function test_SaleDeltaChecks() public {
        bytes32 id = keccak256("lot");
        bytes memory data = _data(id, 1 ether, 1, 0);
        route.configure(10 ether, true, false); // reports 10 but pays nothing
        vm.expectRevert();
        conv.convert(id, address(token), 1 ether, data);
        route.configure(10 ether, false, true); // pays but leaves raw with converter
        vm.expectRevert();
        conv.convert(id, address(token), 1 ether, data);
        route.configure(9.9 ether - 1, true, true); // below the signed floor
        vm.expectRevert();
        conv.convert(id, address(token), 1 ether, data);
        assertFalse(conv.converted(id));
        assertEq(token.balanceOf(address(this)), 100 ether);
    }

    /// L126 both arms: router refusing native reverts the whole conversion.
    function test_RouterMustAcceptProceeds() public {
        bytes32 id = keccak256("lot");
        bytes memory data = _data(id, 1 ether, 1, 0);
        rejectNative = true;
        vm.expectRevert();
        conv.convert(id, address(token), 1 ether, data);
        assertFalse(conv.converted(id));
        rejectNative = false;
        uint256 before = address(this).balance;
        assertEq(conv.convert(id, address(token), 1 ether, data), 10 ether);
        assertEq(address(this).balance, before + 10 ether);
        assertEq(token.balanceOf(address(route)), 1 ether);
    }
}

contract CovCV2FundRouter {
    uint256 public calls;
    uint256 public lastAmount;
    uint256 public lastValue;

    function onFunded(bytes32, uint8, address, uint256 amount) external payable {
        calls++;
        lastAmount = amount;
        lastValue = msg.value;
    }
}

contract CovCV2IngressTest is Test {
    V2FeeIngress ingress;
    CovCV2FundRouter router;
    CovCToken token;
    V2FeeIngress.Source source;

    function setUp() public {
        vm.chainId(5042);
        ingress = new V2FeeIngress(address(this), [vm.addr(101), vm.addr(102), vm.addr(103)], address(this), 0);
        router = new CovCV2FundRouter();
        ingress.setRouter(address(router));
        token = new CovCToken();
        source = V2FeeIngress.Source(
            5042, address(0), address(token), 10000, 100, address(0), 123, address(0x55), address(this), 0, 1, 2
        );
        ingress.scheduleSource(source);
        vm.warp(block.timestamp + 48 hours);
        ingress.activateSource(source);
        token.mint(address(this), 1000 ether);
        token.approve(address(ingress), type(uint256).max);
        vm.deal(address(this), 1000 ether);
    }

    function _ev(address t, uint256 amount, bytes32 tx_) internal view returns (V2FeeIngress.Evidence memory e) {
        e = V2FeeIngress.Evidence(ingress.sourceKey(source), tx_, uint64(block.number), 0, t, amount, 1);
    }

    function _sign(V2FeeIngress.Evidence memory e, uint256 k0, uint256 k1)
        internal
        view
        returns (V2FeeIngress.AuditSignature[2] memory sigs)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(k0, ingress.evidenceDigest(e));
        sigs[0] = V2FeeIngress.AuditSignature(0, abi.encodePacked(r, s, v));
        (v, r, s) = vm.sign(k1, ingress.evidenceDigest(e));
        sigs[1] = V2FeeIngress.AuditSignature(1, abi.encodePacked(r, s, v));
    }

    /// L79 / L81 both arms.
    function test_ConstructorAuditorSet() public {
        vm.expectRevert();
        new V2FeeIngress(address(this), [vm.addr(1), address(0), vm.addr(3)], address(this), 0);
        vm.expectRevert();
        new V2FeeIngress(address(this), [vm.addr(1), vm.addr(2), vm.addr(1)], address(this), 0);
        vm.expectRevert();
        new V2FeeIngress(address(this), [vm.addr(1), vm.addr(1), vm.addr(3)], address(this), 0);
        V2FeeIngress ok = new V2FeeIngress(address(this), [vm.addr(1), vm.addr(2), vm.addr(3)], address(this), 0);
        assertEq(ok.auditors(2), vm.addr(3));
    }

    /// L126 both arms: a non-auditor signature in either slot is rejected.
    function test_RecordLotRequiresAuditorSignatures() public {
        V2FeeIngress.Evidence memory e = _ev(address(0), 1 ether, keccak256("c1"));
        V2FeeIngress.AuditSignature[2] memory badA = _sign(e, 999, 102);
        V2FeeIngress.AuditSignature[2] memory badB = _sign(e, 101, 999);
        vm.expectRevert();
        ingress.recordLot(e, badA);
        vm.expectRevert();
        ingress.recordLot(e, badB);
        bytes32 id = ingress.recordLot(e, _sign(e, 101, 102));
        assertEq(ingress.lotInfo(id).state, 1);
        assertTrue(ingress.lotInfo(id).admitted);
    }

    /// L129 both arms: the same collect receipt cannot be recorded twice, even under different evidence fields.
    function test_ReceiptReplay() public {
        V2FeeIngress.Evidence memory e = _ev(address(0), 1 ether, keccak256("c1"));
        ingress.recordLot(e, _sign(e, 101, 102));
        e.actualPlatformAmount = 2 ether;
        V2FeeIngress.AuditSignature[2] memory sigs = _sign(e, 101, 102);
        vm.expectRevert();
        ingress.recordLot(e, sigs);
    }

    /// L145 / L148 both arms on the native path.
    function test_FundNativeFunderAndAmount() public {
        V2FeeIngress.Evidence memory e = _ev(address(0), 1 ether, keccak256("c1"));
        bytes32 id = ingress.recordLot(e, _sign(e, 101, 102));
        vm.deal(address(0xBAD), 1 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        ingress.fundLot{value: 1 ether}(id);
        vm.expectRevert();
        ingress.fundLot{value: 1 ether - 1}(id);
        assertEq(ingress.lotInfo(id).state, 1);
        ingress.fundLot{value: 1 ether}(id);
        assertEq(ingress.lotInfo(id).state, 2);
        assertEq(router.lastValue(), 1 ether);
        assertEq(address(router).balance, 1 ether);
    }

    /// L151 both arms; L155 false arm; L158 false arm on the token path.
    function test_FundTokenExactness() public {
        V2FeeIngress.Evidence memory e = _ev(address(token), 10 ether, keccak256("t1"));
        bytes32 id = ingress.recordLot(e, _sign(e, 101, 102));
        vm.expectRevert();
        ingress.fundLot{value: 1}(id); // attached native on a token lot
        token.setShortFrom(address(this));
        vm.expectRevert();
        ingress.fundLot(id); // fee-on-transfer into ingress
        token.setShortFrom(address(ingress));
        vm.expectRevert();
        ingress.fundLot(id); // fee-on-transfer into router
        token.setShortFrom(address(0));
        assertEq(ingress.lotInfo(id).state, 1);
        assertEq(token.balanceOf(address(this)), 1000 ether);
        ingress.fundLot(id);
        assertEq(token.balanceOf(address(router)), 10 ether);
        assertEq(token.balanceOf(address(ingress)), 0);
        assertEq(router.lastAmount(), 10 ether);
        assertEq(router.lastValue(), 0);
    }
}

/// @notice Programmable IV2FeeConversion bound to a platform router.
contract CovCPlatConverter {
    address public router;
    address public sellRoute;
    uint256 public ret = 5 ether;
    uint256 public sendAmt = 5 ether;
    bool public pull = true;

    constructor(address r, address s) {
        router = r;
        sellRoute = s;
    }

    function configure(uint256 ret_, uint256 send_, bool pull_) external {
        ret = ret_;
        sendAmt = send_;
        pull = pull_;
    }

    function convert(bytes32, address token, uint256 amount, bytes calldata) external returns (uint256) {
        if (pull) CovCToken(token).transferFrom(msg.sender, address(this), amount);
        if (sendAmt != 0) {
            (bool ok,) = msg.sender.call{value: sendAmt}("");
            require(ok, "conv pay");
        }
        return ret;
    }

    receive() external payable {}
}

contract CovCAssetView {
    address public asset;

    constructor(address a) {
        asset = a;
    }
}

contract CovCV2PlatformRouterTest is Test {
    V2PlatformRouter platform;
    V2StakingReceiver staking;
    V2BuybackReceiver buyback;
    CovCToken token;
    address sink = address(0xdead);

    function setUp() public {
        staking = new V2StakingReceiver();
        buyback = new V2BuybackReceiver();
        platform = new V2PlatformRouter(address(this), address(this), address(staking), address(buyback), sink);
        token = new CovCToken();
        vm.deal(address(this), 100 ether);
    }

    function _rawLot(bytes32 id, uint256 amount) internal {
        token.mint(address(platform), amount);
        platform.onFunded(id, 2, address(token), amount);
        platform.routeLot(id);
    }

    function _converter() internal returns (CovCPlatConverter c) {
        c = new CovCPlatConverter(address(platform), address(new CovCAssetView(address(token))));
        vm.deal(address(c), 100 ether);
        platform.setConverter(address(c));
    }

    /// L72 both arms.
    function test_NativeAmountMustEqualValue() public {
        vm.expectRevert();
        platform.onFunded{value: 1 ether}(bytes32(uint256(1)), 2, address(0), 2 ether);
        platform.onFunded{value: 1 ether}(bytes32(uint256(1)), 2, address(0), 1 ether);
        assertEq(platform.state(bytes32(uint256(1))), 4);
        assertEq(buyback.credited(bytes32(uint256(1))), 1 ether);
        assertTrue(buyback.desk(bytes32(uint256(1))));
    }

    /// L77 false arm: raw lot must be backed by actual unencumbered balance.
    function test_RawLotMustBeBacked() public {
        token.mint(address(platform), 5 ether);
        platform.onFunded(bytes32(uint256(1)), 2, address(token), 5 ether);
        vm.expectRevert();
        platform.onFunded(bytes32(uint256(2)), 2, address(token), 1);
        assertEq(platform.rawLiability(address(token)), 5 ether);
        assertEq(platform.state(bytes32(uint256(2))), 0);
    }

    /// L96 both arms.
    function test_RouteLotRequiresFundedState() public {
        vm.expectRevert();
        platform.routeLot(bytes32(uint256(1)));
        token.mint(address(platform), 5 ether);
        platform.onFunded(bytes32(uint256(1)), 2, address(token), 5 ether);
        platform.routeLot(bytes32(uint256(1)));
        assertEq(platform.state(bytes32(uint256(1))), 2);
        vm.expectRevert();
        platform.routeLot(bytes32(uint256(1)));
    }

    function _etchSolon() internal returns (LedgerStock s) {
        address solon = platform.SOLON();
        vm.etch(solon, address(new LedgerStock()).code);
        s = LedgerStock(solon);
    }

    /// L108 false arm: taxed burn transfer; L112 true arm: a 1-wei SOLON lot burns entirely and closes.
    function test_SolonBurnHalfEdgeCases() public {
        LedgerStock s = _etchSolon();
        s.mint(address(platform), 1);
        platform.onFunded(bytes32(uint256(1)), 1, address(s), 1);
        platform.routeLot(bytes32(uint256(1)));
        assertEq(platform.state(bytes32(uint256(1))), 4);
        assertEq(s.balanceOf(sink), 1);
        assertEq(platform.rawLiability(address(s)), 0);
        (, uint256 raw,) = platform.pending(bytes32(uint256(1)));
        assertEq(raw, 0);
        // carried odd remainder: the next 1-wei lot keeps its unit for conversion
        s.mint(address(platform), 1);
        platform.onFunded(bytes32(uint256(2)), 1, address(s), 1);
        platform.routeLot(bytes32(uint256(2)));
        assertEq(platform.state(bytes32(uint256(2))), 2);
        // taxed burn transfer
        s.mint(address(platform), 10);
        platform.onFunded(bytes32(uint256(3)), 1, address(s), 10);
        s.configure(false, true, false);
        vm.expectRevert();
        platform.routeLot(bytes32(uint256(3)));
        assertEq(platform.state(bytes32(uint256(3))), 1);
    }

    /// L132 both arms; L136 both arms.
    function test_ConvertRequiresRoutedStateAndConverter() public {
        vm.expectRevert();
        platform.convertLot(bytes32(uint256(1)), "");
        _rawLot(bytes32(uint256(1)), 5 ether);
        vm.expectRevert(); // no converter selected
        platform.convertLot(bytes32(uint256(1)), "");
        _converter();
        platform.convertLot(bytes32(uint256(1)), "");
        assertEq(platform.state(bytes32(uint256(1))), 4);
        assertEq(buyback.credited(bytes32(uint256(1))), 5 ether);
        assertEq(platform.rawLiability(address(token)), 0);
        vm.expectRevert();
        platform.convertLot(bytes32(uint256(1)), "");
    }

    /// L148 false arm: zero output, unpaid output, or raw not taken.
    function test_ConversionDeltaChecks() public {
        _rawLot(bytes32(uint256(1)), 5 ether);
        CovCPlatConverter c = _converter();
        c.configure(0, 0, true);
        vm.expectRevert();
        platform.convertLot(bytes32(uint256(1)), "");
        c.configure(5 ether, 4 ether, true);
        vm.expectRevert();
        platform.convertLot(bytes32(uint256(1)), "");
        c.configure(5 ether, 5 ether, false);
        vm.expectRevert();
        platform.convertLot(bytes32(uint256(1)), "");
        assertEq(platform.state(bytes32(uint256(1))), 2);
        assertEq(token.balanceOf(address(platform)), 5 ether);
        assertEq(platform.conversionCount(bytes32(uint256(1))), 0);
    }

    /// L175 / L176 false arms; L180 both arms.
    function test_AssetConverterBinding() public {
        CovCPlatConverter wrongRouter =
            new CovCPlatConverter(address(0x1234), address(new CovCAssetView(address(token))));
        vm.expectRevert();
        platform.scheduleAssetConverter(address(token), address(wrongRouter));
        CovCPlatConverter wrongAsset = new CovCPlatConverter(address(platform), address(new CovCAssetView(address(1))));
        vm.expectRevert();
        platform.scheduleAssetConverter(address(token), address(wrongAsset));
        CovCPlatConverter good = new CovCPlatConverter(address(platform), address(new CovCAssetView(address(token))));
        vm.prank(address(0xBAD));
        vm.expectRevert();
        platform.scheduleAssetConverter(address(token), address(good));
        platform.scheduleAssetConverter(address(token), address(good));
        assertEq(platform.converterActivation(keccak256(abi.encode(address(token), address(good)))), block.timestamp + 48 hours);
        vm.expectRevert();
        platform.activateAssetConverter(address(token), address(good));
        vm.warp(block.timestamp + 48 hours);
        platform.activateAssetConverter(address(token), address(good));
        assertEq(platform.assetConverter(address(token)), address(good));
        assertTrue(platform.registeredConverter(address(good)));
    }
}

contract CovCDeskRoyaltyConverterTest is Test {
    CovCToken raw;
    CovCV2Route route;
    CovCSwitchReceiver rewards;
    DeskRoyaltyConverter escrow;
    uint256 constant SIGNER = 42;

    function setUp() public {
        vm.warp(10 days);
        raw = new CovCToken();
        route = new CovCV2Route(address(raw));
        vm.deal(address(route), 100 ether);
        rewards = new CovCSwitchReceiver();
        escrow = new DeskRoyaltyConverter(
            address(rewards), address(raw), address(route), vm.addr(SIGNER), address(0xFEE), bytes32(uint256(1)), 1
        );
        raw.mint(address(this), 100 ether);
        raw.approve(address(escrow), type(uint256).max);
    }

    function _data(bytes32 slice, uint256 amount, uint256 nonce) internal view returns (bytes memory) {
        V2FeeConverter c = escrow.converter();
        V2FeeConverter.Quote memory q = V2FeeConverter.Quote(
            slice, address(raw), amount, 9.9 ether, 10 ether, block.timestamp, block.timestamp + 60, nonce, 0
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER, c.quoteDigest(q));
        return abi.encode(q, abi.encodePacked(r, s, v));
    }

    /// L27 false arm.
    function test_ConstructorFixedRoute() public {
        CovCV2Route other = new CovCV2Route(address(0x1234));
        vm.expectRevert(bytes("fixed royalty route"));
        new DeskRoyaltyConverter(address(rewards), address(raw), address(other), vm.addr(1), address(1), bytes32(uint256(1)), 1);
        vm.expectRevert(bytes("fixed royalty route"));
        new DeskRoyaltyConverter(address(0x777), address(raw), address(route), vm.addr(1), address(1), bytes32(uint256(1)), 1);
    }

    /// L36 both arms.
    function test_DepositNonZero() public {
        vm.expectRevert(bytes("empty royalty"));
        escrow.deposit(0);
        bytes32 id = escrow.deposit(3 ether);
        assertEq(id, keccak256(abi.encode(address(escrow), uint256(1))));
        assertEq(escrow.pending(id), 3 ether);
        assertEq(raw.balanceOf(address(escrow)), 3 ether);
    }

    /// L42 false arm: escrow receipt short, or payer debited extra.
    function test_DepositDelta() public {
        raw.setShortFrom(address(this));
        vm.expectRevert(bytes("royalty delta"));
        escrow.deposit(1 ether);
        raw.setShortFrom(address(0));
        raw.setExtraFrom(address(this));
        vm.expectRevert(bytes("royalty delta"));
        escrow.deposit(1 ether);
        assertEq(escrow.nonce(), 0);
    }

    /// L65 false arm: escrow debited more than the converted slice.
    function test_ConversionDelta() public {
        bytes32 id = escrow.deposit(10 ether);
        raw.setExtraFrom(address(escrow));
        bytes memory data = _data(escrow.nextConversionId(id), 5 ether, 1);
        vm.expectRevert(bytes("conversion delta"));
        escrow.convert(id, 5 ether, data);
        assertEq(escrow.pending(id), 10 ether);
        assertEq(escrow.conversionCount(id), 0);
    }

    /// L72 false arm: rewards pot refusing native.
    function test_PotDelta() public {
        bytes32 id = escrow.deposit(10 ether);
        rewards.setRejects(true);
        bytes memory data = _data(escrow.nextConversionId(id), 5 ether, 1);
        vm.expectRevert(bytes("pot delta"));
        escrow.convert(id, 5 ether, data);
        rewards.setRejects(false);
        assertEq(escrow.convert(id, 5 ether, data), 10 ether);
        assertEq(address(rewards).balance, 10 ether);
        assertEq(escrow.pending(id), 5 ether);
        assertEq(address(escrow).balance, 0);
    }

    /// L77 both arms.
    function test_ReceiveConverterOnly() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(escrow).call{value: 1}("");
        assertFalse(ok);
        address c = address(escrow.converter());
        vm.deal(c, 1);
        vm.prank(c);
        (ok,) = address(escrow).call{value: 1}("");
        assertTrue(ok);
    }
}
