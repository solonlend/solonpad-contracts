// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FloatRebalancer} from "../../src/v3/stock/FloatRebalancer.sol";
import {EthereumFloatAdapter} from "../../src/v3/stock/ethereum/EthereumFloatAdapter.sol";
import {FloatReceiver} from "../../src/v3/stock/robinhood/FloatReceiver.sol";
import {IOFTLike, SendParam, OFTReceipt, IStableConverter} from "../../src/v3/stock/interfaces/IOFTLike.sol";
import {MessagingFee, MessagingReceipt} from "../../src/v3/stock/lz/ILayerZeroEndpointV2.sol";
import {CctpV2} from "../../src/v3/stock/libs/CctpV2.sol";
import {MockLzEndpoint, MockUSDG, MockTokenMessenger, MockMessageTransmitter} from "./helpers/StockMocks.sol";

/// @notice USDC -> USDG converter double at a configurable loss in bps.
contract MockStableConverter is IStableConverter {
    MockUSDG public immutable usdc;
    MockUSDG public immutable usdg;
    uint256 public lossBps = 5;

    constructor(MockUSDG usdc_, MockUSDG usdg_) {
        usdc = usdc_;
        usdg = usdg_;
    }

    function setLoss(uint256 b) external {
        lossBps = b;
    }

    function convert(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 out)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        out = amountIn * (10_000 - lossBps) / 10_000;
        require(out >= minOut, "min");
        MockUSDG(tokenOut).mint(msg.sender, out);
    }
}

/// @notice One mock plays the USDG OFT on both Ethereum (send) and Robinhood Chain (credit + compose).
contract MockOFT is IOFTLike {
    struct Sent {
        SendParam p;
        bytes32 guid;
        address sender;
    }

    MockUSDG public immutable ethToken;
    MockUSDG public immutable rhToken;
    MockLzEndpoint public immutable rhEndpoint;
    Sent[] internal _sent;
    uint64 public nonce;

    constructor(MockUSDG eth_, MockUSDG rh_, MockLzEndpoint rhEp) {
        ethToken = eth_;
        rhToken = rh_;
        rhEndpoint = rhEp;
    }

    function token() external view returns (address) {
        return address(ethToken);
    }

    function send(SendParam calldata p, MessagingFee calldata fee, address)
        external
        payable
        returns (MessagingReceipt memory r, OFTReceipt memory o)
    {
        require(msg.value == fee.nativeFee, "fee");
        ethToken.transferFrom(msg.sender, address(this), p.amountLD);
        require(p.amountLD >= p.minAmountLD, "slippage");
        bytes32 guid = keccak256(abi.encode("oft", ++nonce));
        _sent.push(Sent(p, guid, msg.sender));
        r = MessagingReceipt(guid, nonce, fee);
        o = OFTReceipt(p.amountLD, p.amountLD);
    }

    function sentCount() external view returns (uint256) {
        return _sent.length;
    }

    /// @notice Credit on RH and run the compose exactly as OFTCore + EndpointV2 would.
    function deliver(uint256 i) external {
        Sent storage s = _sent[i];
        address to = address(uint160(uint256(s.p.to)));
        rhToken.mint(to, s.p.amountLD);
        bytes memory compose = abi.encodePacked(
            uint64(i + 1), uint32(30101), s.p.amountLD, bytes32(uint256(uint160(s.sender))), s.p.composeMsg
        );
        rhEndpoint.composeTo(to, address(this), s.guid, compose);
    }
}

contract FloatRebalancerTest is Test {
    uint32 constant ARC_EID = 30417;
    uint32 constant RH_EID = 30416;
    uint32 constant ARC_DOMAIN = 26;
    uint32 constant ETH_DOMAIN = 0;
    uint256 constant SIGNER = 0xF10A7;

    MockLzEndpoint arcEp;
    MockLzEndpoint rhEp;
    MockUSDG arcUsdc;
    MockUSDG ethUsdc;
    MockUSDG ethUsdg;
    MockUSDG rhUsdg;
    MockTokenMessenger arcMessenger;
    MockTokenMessenger ethMessenger;
    MockMessageTransmitter arcTransmitter;
    MockMessageTransmitter ethTransmitter;
    MockStableConverter converter;
    MockOFT oft;
    FloatRebalancer rebalancer;
    EthereumFloatAdapter adapter;
    FloatReceiver receiver;
    address owner = address(0xA11CE);
    address guardian = address(0x6A2D);
    address vault = address(0x7A017);
    uint256 cctpNonce;
    uint256 quoteNonce;

    function setUp() public {
        arcEp = new MockLzEndpoint(ARC_EID);
        rhEp = new MockLzEndpoint(RH_EID);
        arcEp.connect(rhEp);
        rhEp.connect(arcEp);
        arcUsdc = new MockUSDG();
        ethUsdc = new MockUSDG();
        ethUsdg = new MockUSDG();
        rhUsdg = new MockUSDG();
        arcMessenger = new MockTokenMessenger();
        ethMessenger = new MockTokenMessenger();
        arcTransmitter = new MockMessageTransmitter();
        ethTransmitter = new MockMessageTransmitter();
        converter = new MockStableConverter(ethUsdc, ethUsdg);
        oft = new MockOFT(ethUsdg, rhUsdg, rhEp);
        address adapterAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rebalancer = new FloatRebalancer(
            FloatRebalancer.Config(
                address(arcEp),
                owner,
                guardian,
                address(arcUsdc),
                address(arcMessenger),
                address(arcTransmitter),
                ETH_DOMAIN,
                address(ethMessenger),
                adapterAddr,
                RH_EID,
                vm.addr(SIGNER)
            )
        );
        adapter = new EthereumFloatAdapter(
            EthereumFloatAdapter.Config(
                address(ethTransmitter),
                address(ethMessenger),
                address(ethUsdc),
                address(ethUsdg),
                address(converter),
                address(oft),
                ARC_DOMAIN,
                address(arcMessenger),
                address(rebalancer),
                RH_EID,
                address(0), // receiver set below (fixed once)
                vm.addr(SIGNER),
                owner
            )
        );
        assertEq(address(adapter), adapterAddr);
        receiver =
            new FloatReceiver(address(rhEp), owner, address(rhUsdg), address(oft), address(adapter), vault, ARC_EID);
        vm.startPrank(owner);
        adapter.setReceiver(address(receiver));
        rebalancer.setPeer(RH_EID, bytes32(uint256(uint160(address(receiver)))));
        receiver.setPeer(ARC_EID, bytes32(uint256(uint160(address(rebalancer)))));
        vm.stopPrank();
        arcUsdc.mint(address(rebalancer), 5_000e6); // independently funded float
        ethTransmitter.setMintToken(address(ethUsdc));
        arcTransmitter.setMintToken(address(arcUsdc));
        vm.deal(address(receiver), 1 ether); // LZ gas for receipts
    }

    function _enable() internal {
        vm.prank(owner);
        rebalancer.proposeEnable();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        rebalancer.enable();
    }

    function _startQuote(bytes32 id, uint256 amount, uint256 minUSDG)
        internal
        returns (FloatRebalancer.StartQuote memory q, bytes memory sig)
    {
        q = FloatRebalancer.StartQuote(id, amount, minUSDG, block.timestamp + 1 hours, ++quoteNonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER, rebalancer.quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    function _convertQuote(bytes32 id, uint256 minOut)
        internal
        returns (EthereumFloatAdapter.ConvertQuote memory q, bytes memory sig)
    {
        q = EthereumFloatAdapter.ConvertQuote(id, minOut, block.timestamp + 60, ++quoteNonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER, adapter.quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    function _cctp(
        uint32 src,
        uint32 dst,
        address messenger,
        address sender,
        address mintRecipient,
        uint256 amount,
        bytes memory hook
    ) internal returns (bytes memory) {
        return CctpV2.build(
            src,
            dst,
            bytes32(++cctpNonce),
            CctpV2.toBytes32(messenger),
            bytes32(0),
            bytes32(0),
            CctpV2.FINALITY_FINALIZED,
            CctpV2.FINALITY_FINALIZED,
            bytes32(0),
            CctpV2.toBytes32(mintRecipient),
            amount,
            CctpV2.toBytes32(sender),
            hook
        );
    }

    /// Arc burn arrives on Ethereum: Circle mints USDC to the adapter and the adapter attests the leg.
    function _arrive(uint256 burnIndex) internal returns (bytes memory m) {
        (uint256 amount,,,,,,,,) = arcMessenger.burns(burnIndex);
        m = _cctp(
            ARC_DOMAIN,
            ETH_DOMAIN,
            address(arcMessenger),
            address(rebalancer),
            address(adapter),
            amount,
            arcMessenger.hookOf(burnIndex)
        );
        adapter.attest(m, "valid");
    }

    function testDisabledByDefaultAndEnablingWaitsFortyEightHours() public {
        (FloatRebalancer.StartQuote memory q, bytes memory sig) = _startQuote("r1", 1_000e6, 995e6);
        vm.expectRevert(FloatRebalancer.Disabled.selector);
        rebalancer.start(q, sig);
        vm.prank(owner);
        rebalancer.proposeEnable();
        vm.prank(owner);
        vm.expectRevert(FloatRebalancer.Timelocked.selector);
        rebalancer.enable();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        rebalancer.enable();
        vm.prank(guardian);
        rebalancer.disable(); // guardian may only switch it off
        assertFalse(rebalancer.enabled());
    }

    function testEveryLegIsBoundToItsOwnReceiptAndSettlesOnce() public {
        _enable();
        (FloatRebalancer.StartQuote memory q, bytes memory sig) = _startQuote("r1", 1_000e6, 995e6);
        rebalancer.start(q, sig);
        assertEq(rebalancer.inFlight(), 1_000e6);
        (bool ok, uint256 free,) = rebalancer.previewRebalance(4_001e6);
        assertFalse(ok, "in-flight money is not spendable again");
        assertEq(free, 4_000e6);
        bytes memory m = _arrive(0);
        EthereumFloatAdapter.Leg memory leg = adapter.legOf("r1");
        assertEq(uint8(leg.state), uint8(EthereumFloatAdapter.State.Attested));
        assertEq(leg.usdc, 1_000e6, "actual USDC received, not the claimed amount");
        assertEq(leg.cctpNonce, bytes32(cctpNonce));
        vm.expectRevert(); // the same CCTP message cannot be redeemed twice
        adapter.attest(m, "valid");
        (EthereumFloatAdapter.ConvertQuote memory cq, bytes memory csig) = _convertQuote("r1", 997e6);
        adapter.convert(cq, csig);
        leg = adapter.legOf("r1");
        assertEq(leg.usdg, 999.5e6);
        vm.deal(address(this), 1 ether);
        adapter.bridge{value: 0.01 ether}("r1", "");
        leg = adapter.legOf("r1");
        assertEq(uint8(leg.state), uint8(EthereumFloatAdapter.State.Bridging));
        assertEq(leg.guid, keccak256(abi.encode("oft", uint64(1))), "OFT guid from the send receipt");
        oft.deliver(0);
        assertEq(rhUsdg.balanceOf(vault), 999.5e6, "USDG lands in the reserve vault");
        assertEq(receiver.received("r1"), 999.5e6);
        arcEp.connect(rhEp);
        rhEp.deliver(rhEp.packetCount() - 1);
        FloatRebalancer.Rebalance memory rb = rebalancer.rebalanceOf("r1");
        assertEq(uint8(rb.state), uint8(FloatRebalancer.State.Finalized));
        assertEq(rb.received, 999.5e6);
        assertEq(rb.guid, leg.guid);
        assertEq(rebalancer.inFlight(), 0);
        vm.expectRevert();
        oft.deliver(0); // a replayed compose cannot credit twice
    }

    function testConversionHonoursSignedNetAndThirtyBpsCeiling() public {
        _enable();
        (FloatRebalancer.StartQuote memory q, bytes memory sig) = _startQuote("r1", 1_000e6, 995e6);
        rebalancer.start(q, sig);
        _arrive(0);
        (EthereumFloatAdapter.ConvertQuote memory low, bytes memory lowSig) = _convertQuote("r1", 996e6);
        vm.expectRevert(EthereumFloatAdapter.SlippageTooWide.selector); // > 30 bps below the input
        adapter.convert(low, lowSig);
        (EthereumFloatAdapter.ConvertQuote memory under, bytes memory uSig) = _convertQuote("r1", 994e6);
        under.minOut = 999e6; // tampered after signing
        vm.expectRevert(EthereumFloatAdapter.BadQuote.selector);
        adapter.convert(under, uSig);
        converter.setLoss(40);
        (EthereumFloatAdapter.ConvertQuote memory ok_, bytes memory okSig) = _convertQuote("r1", 998e6);
        vm.expectRevert(); // actual output below the signed floor
        adapter.convert(ok_, okSig);
    }

    function testTimeoutQuarantinesTheLegAndTheMoneyIsNeverSpentTwice() public {
        _enable();
        (FloatRebalancer.StartQuote memory q, bytes memory sig) = _startQuote("r1", 1_000e6, 995e6);
        rebalancer.start(q, sig);
        _arrive(0);
        vm.warp(block.timestamp + 2 hours);
        (EthereumFloatAdapter.ConvertQuote memory cq, bytes memory csig) = _convertQuote("r1", 997e6);
        vm.expectRevert(EthereumFloatAdapter.Expired.selector);
        adapter.convert(cq, csig);
        adapter.expire("r1");
        vm.expectRevert();
        adapter.bridge{value: 0}("r1", "");
        rebalancer.expire("r1");
        assertEq(uint8(rebalancer.rebalanceOf("r1").state), uint8(FloatRebalancer.State.Quarantined));
        assertEq(rebalancer.inFlight(), 1_000e6, "quarantined money stays reserved");
        (FloatRebalancer.StartQuote memory q2, bytes memory sig2) = _startQuote("r2", 4_001e6, 3_990e6);
        vm.expectRevert(FloatRebalancer.InsufficientFree.selector);
        rebalancer.start(q2, sig2);
        adapter.returnToArc("r1");
        (uint256 amount,,,,,,,,) = ethMessenger.burns(0);
        bytes memory back = _cctp(
            ETH_DOMAIN,
            ARC_DOMAIN,
            address(ethMessenger),
            address(adapter),
            address(rebalancer),
            amount,
            ethMessenger.hookOf(0)
        );
        rebalancer.receiveReturn(back, "valid");
        assertEq(arcUsdc.balanceOf(address(rebalancer)), 5_000e6, "the float is whole again");
        assertEq(uint8(rebalancer.rebalanceOf("r1").state), uint8(FloatRebalancer.State.Returned));
        assertEq(rebalancer.inFlight(), 0);
    }

    function testOnlyTheFixedCounterpartiesAreAccepted() public {
        _enable();
        (FloatRebalancer.StartQuote memory q, bytes memory sig) = _startQuote("r1", 1_000e6, 995e6);
        rebalancer.start(q, sig);
        bytes memory hook = arcMessenger.hookOf(0);
        bytes memory wrongSender =
            _cctp(ARC_DOMAIN, ETH_DOMAIN, address(arcMessenger), address(0xBAD), address(adapter), 1_000e6, hook);
        vm.expectRevert(EthereumFloatAdapter.WrongSource.selector);
        adapter.attest(wrongSender, "valid");
        bytes memory wrongDomain =
            _cctp(7, ETH_DOMAIN, address(arcMessenger), address(rebalancer), address(adapter), 1_000e6, hook);
        vm.expectRevert(EthereumFloatAdapter.WrongSource.selector);
        adapter.attest(wrongDomain, "valid");
        vm.expectRevert(FloatReceiver.NotOft.selector);
        rhEp.composeTo(address(receiver), address(0xBAD), bytes32(0), "");
        vm.expectRevert(FloatReceiver.NotEndpoint.selector);
        receiver.lzCompose(address(oft), bytes32(0), "", address(0), "");
        vm.expectRevert(FloatRebalancer.BadQuote.selector);
        rebalancer.start(q, sig); // quote nonce spent
    }
}
