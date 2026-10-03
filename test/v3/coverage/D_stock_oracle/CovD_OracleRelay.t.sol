// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ChainlinkStockSource} from "../../../../src/v3/oracle/ChainlinkStockSource.sol";
import {StockPriceSender} from "../../../../src/v3/oracle/StockPriceSender.sol";
import {RelayedStockSource} from "../../../../src/v3/oracle/RelayedStockSource.sol";
import {IStockPriceSource, StockObservation} from "../../../../src/v3/oracle/IStockPriceSource.sol";
import {MockAggregator} from "../../helpers/OracleMocks.sol";
import {MockLzEndpoint} from "../../helpers/StockMocks.sol";

/// @notice Branch coverage for RelayedStockSource and StockPriceSender (LayerZero mocked by MockLzEndpoint).
contract CovDOracleRelayTest is Test {
    address constant OWNER = address(0x71);
    address constant NVDA = address(0x1D);
    uint32 constant RH = 30416;
    uint32 constant ARC = 30417;

    MockAggregator feed;
    ChainlinkStockSource src;
    MockLzEndpoint rh;
    MockLzEndpoint arc;
    StockPriceSender sender;
    RelayedStockSource relayed;

    function setUp() public {
        vm.warp(1_760_000_000);
        feed = new MockAggregator(8, 180e8);
        src = new ChainlinkStockSource(OWNER, address(0), 4 days, 0, new ChainlinkStockSource.FeedInit[](0));
        vm.prank(OWNER);
        src.setFeed(NVDA, address(feed), true, address(0));
        rh = new MockLzEndpoint(RH);
        arc = new MockLzEndpoint(ARC);
        rh.connect(arc);
        arc.connect(rh);
        sender = new StockPriceSender(address(rh), OWNER, src, ARC, hex"0003");
        relayed = new RelayedStockSource(address(arc), OWNER, RH);
        vm.startPrank(OWNER);
        sender.setPeer(ARC, bytes32(uint256(uint160(address(relayed)))));
        relayed.setPeer(RH, bytes32(uint256(uint160(address(sender)))));
        vm.stopPrank();
        vm.deal(address(this), 10 ether);
    }

    function _one(address k, StockObservation memory o) internal pure returns (bytes memory) {
        address[] memory keys = new address[](1);
        keys[0] = k;
        StockObservation[] memory obs = new StockObservation[](1);
        obs[0] = o;
        return abi.encode(keys, obs);
    }

    function _obs(uint256 price18, uint64 observedAt, uint64 rhBlock) internal view returns (StockObservation memory) {
        return StockObservation(price18, 1e18, 1e18, 0, uint64(block.timestamp), 7, observedAt, rhBlock);
    }

    /// Deliver `message` to `relayed` as the real RH peer through the Arc endpoint.
    function _fromPeer(bytes memory message) internal {
        arc.inject(RH, address(sender), address(relayed), message);
    }

    // ================================================================ RelayedStockSource

    /// L40 both arms.
    function test_relayed_ctorRejectsZeroEid() public {
        vm.expectRevert(); // bare require(rhEid_ != 0); endpoint/owner are valid, so only that check can fail
        new RelayedStockSource(address(arc), OWNER, 0);
        RelayedStockSource r = new RelayedStockSource(address(arc), OWNER, 7);
        assertEq(r.rhEid(), 7);
    }

    /// L53 true arm: a configured peer on another eid still cannot write prices (only RH is a source).
    function test_relayed_wrongSourceEidReverts() public {
        address other = address(0xF00);
        vm.prank(OWNER);
        relayed.setPeer(999, bytes32(uint256(uint160(other))));
        vm.expectRevert(abi.encodeWithSelector(RelayedStockSource.WrongSource.selector, uint32(999)));
        arc.inject(999, other, address(relayed), _one(NVDA, _obs(1e18, uint64(block.timestamp), 5)));
        vm.expectRevert(abi.encodeWithSelector(RelayedStockSource.NoObservation.selector, NVDA));
        relayed.observe(NVDA);
    }

    /// L55 true arm: keys / observations length mismatch rejects the whole message.
    function test_relayed_lengthMismatchReverts() public {
        address[] memory keys = new address[](2);
        keys[0] = NVDA;
        keys[1] = address(0xA1);
        StockObservation[] memory obs = new StockObservation[](1);
        obs[0] = _obs(1e18, uint64(block.timestamp), 5);
        try arc.inject(RH, address(sender), address(relayed), abi.encode(keys, obs)) {
            fail();
        } catch (bytes memory reason) {
            assertEq(reason.length, 0); // bare require(keys.length == obs.length)
        }
        vm.expectRevert(abi.encodeWithSelector(RelayedStockSource.NoObservation.selector, NVDA));
        relayed.observe(NVDA);
    }

    /// L59 each ignore arm (zero price, zero observedAt), then accepted; empty message is a no-op.
    function test_relayed_ignoresZeroPriceAndZeroObservedAt() public {
        vm.expectEmit(true, false, false, true, address(relayed));
        emit RelayedStockSource.RelayIgnored(NVDA, 5, 0);
        _fromPeer(_one(NVDA, _obs(0, uint64(block.timestamp), 5)));
        vm.expectEmit(true, false, false, true, address(relayed));
        emit RelayedStockSource.RelayIgnored(NVDA, 5, 0);
        _fromPeer(_one(NVDA, _obs(1e18, 0, 5)));
        vm.expectRevert(abi.encodeWithSelector(RelayedStockSource.NoObservation.selector, NVDA));
        relayed.observe(NVDA);
        _fromPeer(abi.encode(new address[](0), new StockObservation[](0)));
        _fromPeer(_one(NVDA, _obs(2e18, uint64(block.timestamp) - 10, 5)));
        StockObservation memory o = relayed.observe(NVDA);
        assertEq(o.price18, 2e18);
        assertEq(o.observedAt, block.timestamp - 10); // L63 false arm: past time kept as is
        assertEq(o.sourceBlock, 5);
    }

    /// L63 true arm: an RH read time ahead of Arc time is clamped to Arc time.
    function test_relayed_futureObservedAtClamped() public {
        _fromPeer(_one(NVDA, _obs(3e18, uint64(block.timestamp) + 120, 9)));
        StockObservation memory o = relayed.observe(NVDA);
        assertEq(o.price18, 3e18);
        assertEq(o.observedAt, block.timestamp);
    }

    /// L70 true arm, plus onlyOwner.
    function test_relayed_setPeerOnlyFirstTime() public {
        vm.prank(OWNER);
        vm.expectRevert(RelayedStockSource.Timelocked.selector);
        relayed.setPeer(RH, bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        relayed.setPeer(12345, bytes32(uint256(1)));
        assertEq(relayed.peers(RH), bytes32(uint256(uint160(address(sender)))));
    }

    /// executePeer L82: never proposed (eta == 0), and the exact eta boundary.
    function test_relayed_executePeerTimelock() public {
        vm.startPrank(OWNER);
        vm.expectRevert(RelayedStockSource.Timelocked.selector);
        relayed.executePeer(RH); // nothing pending
        relayed.proposePeer(RH, bytes32(uint256(2)));
        (, uint64 eta) = relayed.pendingPeer(RH);
        assertEq(eta, block.timestamp + 48 hours);
        vm.warp(eta - 1);
        vm.expectRevert(RelayedStockSource.Timelocked.selector);
        relayed.executePeer(RH);
        vm.warp(eta);
        relayed.executePeer(RH);
        vm.stopPrank();
        assertEq(relayed.peers(RH), bytes32(uint256(2)));
        (, eta) = relayed.pendingPeer(RH);
        assertEq(eta, 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        relayed.proposePeer(RH, bytes32(uint256(3)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        relayed.executePeer(RH);
    }

    function test_relayed_transferOwnershipIsTwoStep() public {
        address n = address(0x0E2);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        relayed.transferOwnership(n);
        vm.prank(OWNER);
        relayed.transferOwnership(n);
        assertEq(relayed.owner(), OWNER);
        assertEq(relayed.pendingOwner(), n);
        vm.prank(n);
        relayed.acceptOwnership();
        assertEq(relayed.owner(), n);
        assertEq(relayed.pendingOwner(), address(0));
    }

    // ================================================================ StockPriceSender

    function test_sender_ctorRejectsZeroSourceOrEid() public {
        vm.expectRevert(); // bare require(source != 0 && arcEid != 0)
        new StockPriceSender(address(rh), OWNER, IStockPriceSource(address(0)), ARC, "");
        vm.expectRevert();
        new StockPriceSender(address(rh), OWNER, src, 0, "");
        StockPriceSender s = new StockPriceSender(address(rh), OWNER, src, ARC, "");
        assertEq(s.arcEid(), ARC);
    }

    /// L54: empty list and > MAX_ASSETS refused; exactly MAX_ASSETS accepted.
    function test_sender_collectBounds() public {
        vm.expectRevert(StockPriceSender.TooMany.selector);
        sender.collect(new address[](0));
        address[] memory u = new address[](17);
        for (uint256 i; i < 17; ++i) u[i] = NVDA;
        vm.expectRevert(StockPriceSender.TooMany.selector);
        sender.collect(u);
        vm.expectRevert(StockPriceSender.TooMany.selector);
        sender.poke{value: 0.01 ether}(u);
        address[] memory u16 = new address[](16);
        for (uint256 i; i < 16; ++i) u16[i] = NVDA;
        (bytes memory payload, uint256 count) = sender.collect(u16);
        assertEq(count, 16);
        (address[] memory k, StockObservation[] memory o) = abi.decode(payload, (address[], StockObservation[]));
        assertEq(k.length, 16);
        assertEq(o.length, 16);
        assertEq(o[15].price18, 180e18);
    }

    /// L73: quote refuses when nothing is readable; otherwise returns the endpoint fee.
    function test_sender_quoteNothingToSend() public {
        address[] memory u = new address[](1);
        u[0] = address(0xDEAD);
        vm.expectRevert(StockPriceSender.NothingToSend.selector);
        sender.quote(u);
        u[0] = NVDA;
        assertEq(sender.quote(u), 0.01 ether);
    }

    function test_sender_setOptionsOnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        sender.setOptions(hex"0101");
        assertEq(sender.options(), hex"0003");
        vm.expectEmit(false, false, false, true, address(sender));
        emit StockPriceSender.OptionsSet(hex"00030100110100000000000000000000000000030d40");
        vm.prank(OWNER);
        sender.setOptions(hex"00030100110100000000000000000000000000030d40");
        assertEq(sender.options(), hex"00030100110100000000000000000000000000030d40");
    }

    /// proposePeer / executePeer L112: eta == 0, before eta, at eta.
    function test_sender_peerChangeTimelock() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        sender.proposePeer(ARC, bytes32(uint256(5)));
        vm.startPrank(OWNER);
        vm.expectRevert(StockPriceSender.Timelocked.selector);
        sender.executePeer(ARC); // nothing pending
        vm.expectEmit(true, false, false, true, address(sender));
        emit StockPriceSender.PeerProposed(ARC, bytes32(uint256(5)), uint64(block.timestamp + 48 hours));
        sender.proposePeer(ARC, bytes32(uint256(5)));
        (bytes32 pp, uint64 eta) = sender.pendingPeer(ARC);
        assertEq(pp, bytes32(uint256(5)));
        vm.warp(eta - 1);
        vm.expectRevert(StockPriceSender.Timelocked.selector);
        sender.executePeer(ARC);
        assertEq(sender.peers(ARC), bytes32(uint256(uint160(address(relayed)))));
        vm.warp(eta);
        sender.executePeer(ARC);
        vm.stopPrank();
        assertEq(sender.peers(ARC), bytes32(uint256(5)));
        (, eta) = sender.pendingPeer(ARC);
        assertEq(eta, 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        sender.executePeer(ARC);
    }

    /// _lzReceive: even a genuine packet from the configured Arc peer is refused (send-only OApp).
    function test_sender_refusesInboundMessages() public {
        vm.expectRevert(StockPriceSender.NotReceiver.selector);
        rh.inject(ARC, address(relayed), address(sender), _one(NVDA, _obs(1e18, uint64(block.timestamp), 5)));
    }

    function test_sender_transferOwnershipIsTwoStep() public {
        address n = address(0x0E2);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        sender.transferOwnership(n);
        vm.prank(OWNER);
        sender.transferOwnership(n);
        assertEq(sender.owner(), OWNER);
        assertEq(sender.pendingOwner(), n);
        vm.prank(n);
        sender.acceptOwnership();
        assertEq(sender.owner(), n);
    }

    /// End to end with a quote-feed-less RH source: poke relays, the Arc side stores the read.
    function test_sender_pokeAllReadableRelays() public {
        address[] memory u = new address[](1);
        u[0] = NVDA;
        sender.poke{value: 0.01 ether}(u);
        rh.deliver(0);
        StockObservation memory o = relayed.observe(NVDA);
        assertEq(o.price18, 180e18);
        assertEq(o.quoteUsd18, 1e18);
        assertEq(o.sourceBlock, block.number);
    }
}
