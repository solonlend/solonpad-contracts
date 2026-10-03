// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FloatRebalancer} from "../../../../src/v3/stock/FloatRebalancer.sol";
import {EthereumFloatAdapter} from "../../../../src/v3/stock/ethereum/EthereumFloatAdapter.sol";
import {FloatReceiver} from "../../../../src/v3/stock/robinhood/FloatReceiver.sol";
import {IOFTLike, OFTReceipt, IStableConverter} from "../../../../src/v3/stock/interfaces/IOFTLike.sol";
import {MessagingFee, MessagingReceipt} from "../../../../src/v3/stock/lz/ILayerZeroEndpointV2.sol";
import {CctpV2} from "../../../../src/v3/stock/libs/CctpV2.sol";
import {MockStableConverter, MockOFT} from "../../FloatRebalancer.t.sol";
import {MockLzEndpoint, MockUSDG, MockTokenMessenger, MockMessageTransmitter} from "../../helpers/StockMocks.sol";

/// @notice Same wiring as FloatRebalancerTest (Arc rebalancer, Ethereum adapter, RH receiver), without its tests.
abstract contract CovDFloatBase is Test {
    uint32 constant ARC_EID = 30417;
    uint32 constant RH_EID = 30416;
    uint32 constant OTHER_EID = 30101;
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

    function setUp() public virtual {
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
        adapter = new EthereumFloatAdapter(_adapterConfig(address(0)));
        assertEq(address(adapter), adapterAddr);
        receiver =
            new FloatReceiver(address(rhEp), owner, address(rhUsdg), address(oft), address(adapter), vault, ARC_EID);
        vm.startPrank(owner);
        adapter.setReceiver(address(receiver));
        rebalancer.setPeer(RH_EID, bytes32(uint256(uint160(address(receiver)))));
        receiver.setPeer(ARC_EID, bytes32(uint256(uint160(address(rebalancer)))));
        vm.stopPrank();
        arcUsdc.mint(address(rebalancer), 5_000e6);
        ethTransmitter.setMintToken(address(ethUsdc));
        arcTransmitter.setMintToken(address(arcUsdc));
        vm.deal(address(receiver), 1 ether);
    }

    function _adapterConfig(address rhReceiver) internal view returns (EthereumFloatAdapter.Config memory) {
        return EthereumFloatAdapter.Config(
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
            rhReceiver,
            vm.addr(SIGNER),
            owner
        );
    }

    function _enable() internal {
        vm.prank(owner);
        rebalancer.proposeEnable();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        rebalancer.enable();
    }

    function _start(bytes32 id, uint256 amount, uint256 minUSDG) internal returns (FloatRebalancer.StartQuote memory q) {
        q = FloatRebalancer.StartQuote(id, amount, minUSDG, block.timestamp + 1 hours, ++quoteNonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER, rebalancer.quoteDigest(q));
        rebalancer.start(q, abi.encodePacked(r, s, v));
    }

    function _convertQuote(bytes32 id, uint256 minOut)
        internal
        returns (EthereumFloatAdapter.ConvertQuote memory q, bytes memory sig)
    {
        q = EthereumFloatAdapter.ConvertQuote(id, minOut, block.timestamp + 60, ++quoteNonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER, adapter.quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    function _cctpN(
        bytes32 n,
        uint32 src,
        uint32 dst,
        address messenger,
        address sender,
        address mintRecipient,
        uint256 amount,
        bytes memory hook
    ) internal pure returns (bytes memory) {
        return CctpV2.build(
            src,
            dst,
            n,
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

    function _cctp(
        uint32 src,
        uint32 dst,
        address messenger,
        address sender,
        address mintRecipient,
        uint256 amount,
        bytes memory hook
    ) internal returns (bytes memory) {
        return _cctpN(bytes32(++cctpNonce), src, dst, messenger, sender, mintRecipient, amount, hook);
    }

    /// Arc burn `i` arrives on Ethereum and is attested by the adapter.
    function _arrive(uint256 i) internal returns (bytes memory m) {
        (uint256 amount,,,,,,,,) = arcMessenger.burns(i);
        m = _cctp(
            ARC_DOMAIN, ETH_DOMAIN, address(arcMessenger), address(rebalancer), address(adapter), amount, arcMessenger.hookOf(i)
        );
        adapter.attest(m, "valid");
    }

    /// Return message from the adapter to the rebalancer for `id`.
    function _back(bytes32 id, uint256 amount) internal returns (bytes memory) {
        return _cctp(
            ETH_DOMAIN, ARC_DOMAIN, address(ethMessenger), address(adapter), address(rebalancer), amount, abi.encode(id)
        );
    }

    function _receipt(bytes32 id, uint256 received) internal pure returns (bytes memory) {
        return abi.encode(id, keccak256(abi.encode("guid", id)), received);
    }
}

contract CovDFloatRebalancerTest is CovDFloatBase {
    // L135: only guardian or owner may switch off; owner arm
    function test_disable_strangerRejected_ownerAccepted() public {
        _enable();
        vm.prank(address(0xBAD));
        vm.expectRevert(FloatRebalancer.NotGuardian.selector);
        rebalancer.disable();
        assertTrue(rebalancer.enabled());
        vm.prank(owner);
        rebalancer.proposeEnable();
        vm.prank(owner);
        rebalancer.disable();
        assertFalse(rebalancer.enabled());
        assertEq(rebalancer.enableEta(), 0, "pending enable cleared too");
    }

    // L196: expire needs state Sent and a passed deadline
    function test_expire_wrongStateArms() public {
        _enable();
        vm.expectRevert(abi.encodeWithSelector(FloatRebalancer.WrongState.selector, bytes32("nope")));
        rebalancer.expire("nope"); // None
        FloatRebalancer.StartQuote memory q = _start("r1", 1_000e6, 995e6);
        vm.expectRevert(abi.encodeWithSelector(FloatRebalancer.WrongState.selector, bytes32("r1")));
        rebalancer.expire("r1"); // before the deadline
        vm.warp(q.deadline);
        vm.expectRevert(abi.encodeWithSelector(FloatRebalancer.WrongState.selector, bytes32("r1")));
        rebalancer.expire("r1"); // exactly at the deadline (<=)
        vm.warp(q.deadline + 1);
        rebalancer.expire("r1");
        assertEq(uint8(rebalancer.rebalanceOf("r1").state), uint8(FloatRebalancer.State.Quarantined));
        vm.expectRevert(abi.encodeWithSelector(FloatRebalancer.WrongState.selector, bytes32("r1")));
        rebalancer.expire("r1"); // already quarantined
        assertEq(rebalancer.inFlight(), 1_000e6);
    }

    // L204: an unattested message
    function test_receiveReturn_badAttestation_revertsReceiveFailed() public {
        _enable();
        _start("r1", 1_000e6, 995e6);
        bytes memory m = _back("r1", 1_000e6);
        vm.expectRevert(FloatRebalancer.ReceiveFailed.selector);
        rebalancer.receiveReturn(m, "forged");
        assertEq(uint8(rebalancer.rebalanceOf("r1").state), uint8(FloatRebalancer.State.Sent));
    }

    // L209: each of the three source checks
    function test_receiveReturn_wrongSourceArms() public {
        _enable();
        _start("r1", 1_000e6, 995e6);
        bytes memory hook = abi.encode(bytes32("r1"));
        bytes memory wrongDomain =
            _cctp(7, ARC_DOMAIN, address(ethMessenger), address(adapter), address(rebalancer), 1_000e6, hook);
        bytes memory wrongMessenger =
            _cctp(ETH_DOMAIN, ARC_DOMAIN, address(0xE7), address(adapter), address(rebalancer), 1_000e6, hook);
        bytes memory wrongSender =
            _cctp(ETH_DOMAIN, ARC_DOMAIN, address(ethMessenger), address(0xBAD), address(rebalancer), 1_000e6, hook);
        vm.expectRevert(FloatRebalancer.WrongSource.selector);
        rebalancer.receiveReturn(wrongDomain, "valid");
        vm.expectRevert(FloatRebalancer.WrongSource.selector);
        rebalancer.receiveReturn(wrongMessenger, "valid");
        vm.expectRevert(FloatRebalancer.WrongSource.selector);
        rebalancer.receiveReturn(wrongSender, "valid");
        assertEq(arcUsdc.balanceOf(address(rebalancer)), 4_000e6, "nothing minted or credited");
        assertEq(rebalancer.inFlight(), 1_000e6);
    }

    // L212: unknown id, a Sent (not yet quarantined) return, then a second return for the same id
    function test_receiveReturn_stateArms() public {
        _enable();
        _start("r1", 1_000e6, 995e6);
        bytes memory unknown = _back("zz", 1e6);
        vm.expectRevert(abi.encodeWithSelector(FloatRebalancer.WrongState.selector, bytes32("zz")));
        rebalancer.receiveReturn(unknown, "valid");
        // Sent arm: a return of an unquarantined rebalance is accepted and settles it
        rebalancer.receiveReturn(_back("r1", 1_000e6), "valid");
        FloatRebalancer.Rebalance memory r = rebalancer.rebalanceOf("r1");
        assertEq(uint8(r.state), uint8(FloatRebalancer.State.Returned));
        assertEq(r.returned, 1_000e6, "measured from the balance change");
        assertEq(rebalancer.inFlight(), 0);
        assertEq(arcUsdc.balanceOf(address(rebalancer)), 5_000e6);
        // Returned: a second CCTP message for the id cannot count it twice
        bytes memory again = _back("r1", 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(FloatRebalancer.WrongState.selector, bytes32("r1")));
        rebalancer.receiveReturn(again, "valid");
        assertEq(rebalancer.inFlight(), 0);
    }

    // L224: a peer on another eid (owner misconfiguration) still cannot report
    function test_lzReceive_otherEid_revertsWrongSource() public {
        _enable();
        _start("r1", 1_000e6, 995e6);
        vm.prank(owner);
        rebalancer.setPeer(OTHER_EID, bytes32(uint256(uint160(address(0x0E1)))));
        vm.expectRevert(FloatRebalancer.WrongSource.selector);
        arcEp.inject(OTHER_EID, address(0x0E1), address(rebalancer), _receipt("r1", 999e6));
        assertEq(uint8(rebalancer.rebalanceOf("r1").state), uint8(FloatRebalancer.State.Sent));
    }

    // L227: unknown id, Quarantined arm accepted, Finalized replay rejected
    function test_lzReceive_stateArms() public {
        _enable();
        FloatRebalancer.StartQuote memory q = _start("r1", 1_000e6, 995e6);
        vm.expectRevert(abi.encodeWithSelector(FloatRebalancer.WrongState.selector, bytes32("zz")));
        arcEp.inject(RH_EID, address(receiver), address(rebalancer), _receipt("zz", 1));
        vm.warp(q.deadline + 1);
        rebalancer.expire("r1");
        // the USDG did land after all: the receipt still finalizes a quarantined rebalance
        arcEp.inject(RH_EID, address(receiver), address(rebalancer), _receipt("r1", 999e6));
        FloatRebalancer.Rebalance memory r = rebalancer.rebalanceOf("r1");
        assertEq(uint8(r.state), uint8(FloatRebalancer.State.Finalized));
        assertEq(r.received, 999e6);
        assertEq(rebalancer.inFlight(), 0);
        vm.expectRevert(abi.encodeWithSelector(FloatRebalancer.WrongState.selector, bytes32("r1")));
        arcEp.inject(RH_EID, address(receiver), address(rebalancer), _receipt("r1", 999e6));
        // and a late CCTP return for a finalized rebalance is rejected as well (no double release)
        bytes memory back = _back("r1", 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(FloatRebalancer.WrongState.selector, bytes32("r1")));
        rebalancer.receiveReturn(back, "valid");
    }

    // never-called transferOwnership (Ownable2Step override)
    function test_transferOwnership_twoStep() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        rebalancer.transferOwnership(address(0xBAD));
        vm.prank(owner);
        rebalancer.transferOwnership(address(0x0E2));
        assertEq(rebalancer.owner(), owner, "two-step: not yet");
        assertEq(rebalancer.pendingOwner(), address(0x0E2));
        vm.prank(address(0x0E2));
        rebalancer.acceptOwnership();
        assertEq(rebalancer.owner(), address(0x0E2));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        rebalancer.proposeEnable();
    }
}

contract CovDEthereumFloatAdapterTest is CovDFloatBase {
    // L125/L126: receiver fixed once, by the owner, never zero
    function test_setReceiver_ownerOnlyOnceNonZero() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(EthereumFloatAdapter.NotOwner.selector);
        adapter.setReceiver(address(0x1234));
        vm.prank(owner);
        vm.expectRevert(EthereumFloatAdapter.Duplicate.selector);
        adapter.setReceiver(address(0x1234)); // already set
        assertEq(adapter.rhReceiver(), address(receiver));
        EthereumFloatAdapter fresh = new EthereumFloatAdapter(_adapterConfig(address(0)));
        vm.prank(owner);
        vm.expectRevert(EthereumFloatAdapter.Duplicate.selector);
        fresh.setReceiver(address(0)); // zero
        vm.prank(owner);
        fresh.setReceiver(address(0x1234));
        assertEq(fresh.rhReceiver(), address(0x1234));
    }

    // L142: the same rebalance id twice, and the same CCTP nonce for another id
    function test_attest_duplicateIdOrNonce() public {
        _enable();
        _start("r1", 1_000e6, 995e6);
        _start("r2", 500e6, 497e6);
        _arrive(0); // r1 at nonce 1
        bytes32 n1 = bytes32(cctpNonce);
        // r1 again under a new CCTP nonce
        bytes memory sameId = _cctp(
            ARC_DOMAIN, ETH_DOMAIN, address(arcMessenger), address(rebalancer), address(adapter), 1_000e6, arcMessenger.hookOf(0)
        );
        vm.expectRevert(EthereumFloatAdapter.Duplicate.selector);
        adapter.attest(sameId, "valid");
        // r2 under r1's CCTP nonce (a distinct message body, so the transmitter accepts it)
        bytes memory sameNonce = _cctpN(
            n1, ARC_DOMAIN, ETH_DOMAIN, address(arcMessenger), address(rebalancer), address(adapter), 500e6, arcMessenger.hookOf(1)
        );
        vm.expectRevert(EthereumFloatAdapter.Duplicate.selector);
        adapter.attest(sameNonce, "valid");
        assertEq(uint8(adapter.legOf("r2").state), uint8(EthereumFloatAdapter.State.None));
        assertEq(ethUsdc.balanceOf(address(adapter)), 1_000e6, "only r1's mint stands");
    }

    // L166: convert of an unattested id
    function test_convert_unknownLeg_revertsWrongState() public {
        (EthereumFloatAdapter.ConvertQuote memory q, bytes memory sig) = _convertQuote("zz", 1);
        vm.expectRevert(abi.encodeWithSelector(EthereumFloatAdapter.WrongState.selector, bytes32("zz")));
        adapter.convert(q, sig);
    }

    // L179: a converter that claims an output it did not deliver
    function test_convert_measuredOutputBelowFloor_reverts() public {
        _enable();
        _start("r1", 1_000e6, 995e6);
        _arrive(0);
        vm.mockCall(
            address(converter), abi.encodeWithSelector(IStableConverter.convert.selector), abi.encode(uint256(999e6))
        );
        (EthereumFloatAdapter.ConvertQuote memory q, bytes memory sig) = _convertQuote("r1", 997e6);
        vm.expectRevert(EthereumFloatAdapter.SlippageTooWide.selector);
        adapter.convert(q, sig);
        vm.clearMockedCalls();
        assertEq(uint8(adapter.legOf("r1").state), uint8(EthereumFloatAdapter.State.Attested));
        assertFalse(adapter.quoteNonceUsed(q.nonce));
        assertEq(ethUsdc.balanceOf(address(adapter)), 1_000e6);
    }

    function _converted() internal returns (FloatRebalancer.StartQuote memory sq) {
        _enable();
        sq = _start("r1", 1_000e6, 995e6);
        _arrive(0);
        (EthereumFloatAdapter.ConvertQuote memory q, bytes memory sig) = _convertQuote("r1", 997e6);
        adapter.convert(q, sig);
    }

    // L189: bridging after the rebalance deadline
    function test_bridge_afterDeadline_revertsExpired() public {
        FloatRebalancer.StartQuote memory sq = _converted();
        vm.warp(sq.deadline + 1);
        vm.expectRevert(EthereumFloatAdapter.Expired.selector);
        adapter.bridge("r1", "");
        assertEq(uint8(adapter.legOf("r1").state), uint8(EthereumFloatAdapter.State.Converted));
    }

    // L199: an OFT whose receipt credits less than the signed floor
    function test_bridge_oftReceiptBelowFloor_reverts() public {
        _converted();
        uint256 usdg = adapter.legOf("r1").usdg;
        vm.mockCall(
            address(oft),
            abi.encodeWithSelector(IOFTLike.send.selector),
            abi.encode(
                MessagingReceipt(bytes32(uint256(1)), 1, MessagingFee(0, 0)), OFTReceipt(usdg, 995e6 - 1)
            )
        );
        vm.expectRevert(EthereumFloatAdapter.SlippageTooWide.selector);
        adapter.bridge("r1", "");
        vm.clearMockedCalls();
        assertEq(uint8(adapter.legOf("r1").state), uint8(EthereumFloatAdapter.State.Converted));
        assertEq(ethUsdg.balanceOf(address(adapter)), usdg);
    }

    // L208: expire arms (None, Attested early, Converted ok, Bridging never)
    function test_expire_stateAndDeadlineArms() public {
        vm.expectRevert(abi.encodeWithSelector(EthereumFloatAdapter.WrongState.selector, bytes32("zz")));
        adapter.expire("zz");
        FloatRebalancer.StartQuote memory sq = _converted();
        vm.expectRevert(abi.encodeWithSelector(EthereumFloatAdapter.WrongState.selector, bytes32("r1")));
        adapter.expire("r1"); // before the deadline
        vm.warp(sq.deadline + 1);
        adapter.expire("r1"); // Converted arm
        assertEq(uint8(adapter.legOf("r1").state), uint8(EthereumFloatAdapter.State.Quarantined));
        // L220: quarantined after conversion holds USDG, not USDC: cannot go back as USDC
        vm.expectRevert(abi.encodeWithSelector(EthereumFloatAdapter.WrongState.selector, bytes32("r1")));
        adapter.returnToArc("r1");
        // a Bridging leg can never be quarantined
        sq = _start("r2", 500e6, 497e6);
        _arrive(1);
        (EthereumFloatAdapter.ConvertQuote memory q, bytes memory sig) = _convertQuote("r2", 499e6);
        adapter.convert(q, sig);
        vm.deal(address(this), 1 ether);
        adapter.bridge{value: 0.01 ether}("r2", "");
        vm.warp(sq.deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(EthereumFloatAdapter.WrongState.selector, bytes32("r2")));
        adapter.expire("r2");
    }

    // L220: return of a leg that is not quarantined
    function test_returnToArc_notQuarantined_reverts() public {
        _enable();
        _start("r1", 1_000e6, 995e6);
        _arrive(0);
        vm.expectRevert(abi.encodeWithSelector(EthereumFloatAdapter.WrongState.selector, bytes32("r1")));
        adapter.returnToArc("r1"); // Attested
        assertEq(ethMessenger.burnCount(), 0);
        vm.expectRevert(abi.encodeWithSelector(EthereumFloatAdapter.WrongState.selector, bytes32("zz")));
        adapter.returnToArc("zz"); // None
    }
}
