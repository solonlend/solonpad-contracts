// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkStockFeed} from "../../src/v3/oracle/ChainlinkStockFeed.sol";
import {ChainlinkStockSource} from "../../src/v3/oracle/ChainlinkStockSource.sol";
import {SolonStockOracle} from "../../src/v3/oracle/SolonStockOracle.sol";
import {StockPriceSender} from "../../src/v3/oracle/StockPriceSender.sol";
import {RelayedStockSource} from "../../src/v3/oracle/RelayedStockSource.sol";
import {IStockPriceSource, StockObservation} from "../../src/v3/oracle/IStockPriceSource.sol";
import {
    MockAggregator,
    MockMultiplierToken,
    MockPriceSource,
    OracleTokenStub,
    OracleTestLib,
    MockV3Pool,
    MockDecimalsToken
} from "./helpers/OracleMocks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockLzEndpoint} from "./helpers/StockMocks.sol";
import {Origin} from "../../src/v3/stock/lz/OAppReceiver.sol";

contract StockOracleTest is Test {
    address constant OWNER = address(0x71);
    address constant GUARDIAN = address(0x6A);
    address constant NVDA = address(0x1D);
    uint256 constant WIDE = 4 days;

    MockAggregator feed;
    MockAggregator usdg;
    MockMultiplierToken rhToken;
    ChainlinkStockSource src;
    SolonStockOracle oracle;
    MockPriceSource mock;
    address token;

    function setUp() public {
        vm.warp(1_760_000_000);
        feed = new MockAggregator(8, 180e8); // $180
        usdg = new MockAggregator(8, 1e8);
        rhToken = new MockMultiplierToken();
        src = new ChainlinkStockSource(OWNER, address(usdg), WIDE, 2 days, new ChainlinkStockSource.FeedInit[](0));
        vm.prank(OWNER);
        src.setFeed(NVDA, address(feed), true, address(rhToken));
        oracle = new SolonStockOracle(OWNER, GUARDIAN);
        mock = new MockPriceSource();
        token = address(new OracleTokenStub());
    }

    // ------------------------------------------------------------ ChainlinkStockSource (stocklend rules)

    function testReadsAndNormalises8DecimalFeed() public view {
        StockObservation memory o = src.observe(NVDA);
        assertEq(o.price18, 180e18);
        assertEq(o.quoteUsd18, 1e18);
        assertEq(o.multiplier, 1e18);
        assertEq(o.sourceUpdatedAt, block.timestamp);
        assertEq(o.observedAt, block.timestamp);
    }

    function testDecimalsAreReadNotAssumed() public {
        MockAggregator f18 = new MockAggregator(18, 180e18);
        MockAggregator f6 = new MockAggregator(6, 180e6);
        vm.startPrank(OWNER);
        src.setFeed(address(0x18), address(f18), true, address(0));
        src.setFeed(address(0x06), address(f6), true, address(0));
        vm.stopPrank();
        assertEq(src.observe(address(0x18)).price18, 180e18);
        assertEq(src.observe(address(0x06)).price18, 180e18);
    }

    /// @dev Multiply-before-divide on a low-priced ticket: $0.12345678 must keep every digit.
    function testLowPriceKeepsPrecision() public {
        feed.set(12_345_678, block.timestamp);
        assertEq(src.observe(NVDA).price18, 0.12345678e18);
    }

    function testRoundChecksFailClosed() public {
        uint256 t = block.timestamp;
        feed.setRaw(0, 180e8, t, t, 0); // roundId 0
        vm.expectRevert(ChainlinkStockFeed.BadRound.selector);
        src.observe(NVDA);
        feed.setRaw(5, 180e8, t, 0, 5); // updatedAt 0
        vm.expectRevert(ChainlinkStockFeed.BadRound.selector);
        src.observe(NVDA);
        feed.setRaw(5, 180e8, 0, t, 5); // startedAt 0
        vm.expectRevert(ChainlinkStockFeed.BadRound.selector);
        src.observe(NVDA);
        feed.setRaw(5, 180e8, t, t, 4); // answeredInRound < roundId
        vm.expectRevert(ChainlinkStockFeed.BadRound.selector);
        src.observe(NVDA);
        feed.setRaw(5, 180e8, t, t + 1, 5); // from the future
        vm.expectRevert(ChainlinkStockFeed.BadRound.selector);
        src.observe(NVDA);
        feed.setRaw(5, 0, t, t, 5);
        vm.expectRevert(ChainlinkStockFeed.NonPositive.selector);
        src.observe(NVDA);
        feed.setRaw(5, -1, t, t, 5);
        vm.expectRevert(ChainlinkStockFeed.NonPositive.selector);
        src.observe(NVDA);
    }

    /// @dev Only a very wide bound: a frozen weekend price is still readable, a dead feed is not.
    function testWideStalenessBoundOnly() public {
        vm.warp(block.timestamp + 3 days); // Friday close -> Monday open, feed frozen
        usdg.set(1e8, block.timestamp); // the stable feed keeps its 24h heartbeat
        assertEq(src.observe(NVDA).price18, 180e18);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(ChainlinkStockFeed.StalePrice.selector);
        src.observe(NVDA);
    }

    function testQuoteLegIsReadAndFailsClosed() public {
        usdg.set(0.99e8, block.timestamp);
        assertEq(src.observe(NVDA).quoteUsd18, 0.99e18);
        vm.warp(block.timestamp + 2 days + 1);
        feed.set(180e8, block.timestamp);
        vm.expectRevert(ChainlinkStockFeed.StalePrice.selector);
        src.observe(NVDA);
    }

    function testBranchBAppliesMultiplierAndFailsOnZero() public {
        MockMultiplierToken t = new MockMultiplierToken();
        MockAggregator bare = new MockAggregator(8, 100e8);
        vm.prank(OWNER);
        src.setFeed(address(0xB), address(bare), false, address(t));
        t.setMultiplier(2e18); // e.g. a 2:1 corporate action
        StockObservation memory o = src.observe(address(0xB));
        assertEq(o.price18, 200e18);
        assertEq(o.multiplier, 2e18);
        t.setMultiplier(0);
        vm.expectRevert(ChainlinkStockFeed.NonPositive.selector);
        src.observe(address(0xB));
    }

    /// @dev Branch A never depends on the token: a broken uiMultiplier only blanks the reported value.
    function testBranchAImmuneToMultiplierFailure() public {
        rhToken.setBroken(true);
        StockObservation memory o = src.observe(NVDA);
        assertEq(o.price18, 180e18);
        assertEq(o.multiplier, 0);
    }

    function testFeedsAreSetOnceByOwner() public {
        vm.expectRevert(ChainlinkStockSource.NotOwner.selector);
        src.setFeed(address(0xA), address(feed), true, address(0));
        vm.startPrank(OWNER);
        vm.expectRevert(ChainlinkStockSource.AlreadySet.selector);
        src.setFeed(NVDA, address(feed), true, address(0));
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        src.setFeed(address(0xA), address(feed), false, address(0)); // branch B needs a token
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(ChainlinkStockSource.NoFeed.selector, address(0xA)));
        src.observe(address(0xA));
    }

    // ------------------------------------------------------------ SolonStockOracle state machine

    function _list(IStockPriceSource s) internal {
        vm.prank(OWNER);
        oracle.configureAsset(NVDA, token, s, OracleTestLib.params());
    }

    function testDirectChainlinkSourceGoesLiveAfterFirstPoke() public {
        _list(src);
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Suspect)); // no accepted price yet
        (uint256 p0, uint256 at0) = oracle.priceUSD18(token);
        assertEq(p0 + at0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(SolonStockOracle.PriceNotLive.selector, token, SolonStockOracle.Status.Suspect)
        );
        oracle.execPrice(token);
        assertEq(uint8(oracle.poke(token)), uint8(SolonStockOracle.Status.Live));
        (uint256 p, uint256 at) = oracle.execPrice(token);
        assertEq(p, 180e18);
        assertEq(at, block.timestamp);
        (p, at) = oracle.priceUSD18(NVDA); // the underlying works as a key too
        assertEq(p, 180e18);
        assertEq(oracle.rawFor(token, 360e18), 2e18);
        assertEq(oracle.usdFor(token, 3e18), 540e18);
        (uint128 peeked,) = oracle.peek(token);
        assertEq(peeked, 180e18);
        assertEq(oracle.getPrice(NVDA), 180e18);
        assertEq(oracle.multiplierOf(token), 1e18);
        assertFalse(oracle.isStale(token));
    }

    function testUnknownAssetReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SolonStockOracle.UnknownAsset.selector, token));
        oracle.execPrice(token);
        (uint256 p,) = oracle.priceUSD18(token);
        assertEq(p, 0);
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.None));
    }

    function testSourceFailureIsStaleAndPriceUsdNeverReverts() public {
        _list(mock);
        mock.set(NVDA, 180e18, uint64(block.timestamp));
        oracle.poke(token);
        mock.setFailing(NVDA, true);
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Stale));
        (uint256 p, uint256 at) = oracle.priceUSD18(token);
        assertEq(p + at, 0);
        assertTrue(oracle.isStale(token));
        assertEq(uint8(oracle.poke(token)), uint8(SolonStockOracle.Status.Stale));
    }

    function testObservationOlderThanMaxAgeIsStale() public {
        _list(mock);
        mock.set(NVDA, 180e18, uint64(block.timestamp));
        oracle.poke(token);
        vm.warp(block.timestamp + 15 minutes);
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Live));
        vm.warp(block.timestamp + 1);
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Stale));
        // push-threshold consumers get the aged price with its time and apply their own oracleMaxAge
        (uint256 p, uint256 at) = oracle.priceUSD18(token);
        assertEq(p, 180e18);
        assertEq(at, block.timestamp - 15 minutes - 1);
        vm.expectRevert(
            abi.encodeWithSelector(SolonStockOracle.PriceNotLive.selector, token, SolonStockOracle.Status.Stale)
        );
        oracle.execPrice(token);
        mock.setFull(NVDA, StockObservation(180e18, 1e18, 0.9e18, 0, uint64(at), 9, uint64(at), 1)); // de-pegged
        (p,) = oracle.priceUSD18(token);
        assertEq(p, 0, "any other failure still reads as no price");
    }

    function testStableDepegIsDivergent() public {
        _list(src);
        oracle.poke(token);
        usdg.set(0.9949e8, block.timestamp); // 51 bps off
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Divergent));
        usdg.set(0.995e8, block.timestamp); // exactly 50 bps: allowed
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Live));
    }

    function testJumpNeedsASecondRoundToConfirm() public {
        _list(mock);
        mock.set(NVDA, 100e18, 1);
        oracle.poke(token);
        mock.set(NVDA, 111e18, 2); // +11% > 10%
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Suspect));
        assertEq(uint8(oracle.poke(token)), uint8(SolonStockOracle.Status.Suspect)); // becomes the candidate
        assertEq(oracle.candidateOf(token).price18, 111e18);
        // same Chainlink round again: not a confirmation
        assertEq(uint8(oracle.poke(token)), uint8(SolonStockOracle.Status.Suspect));
        mock.set(NVDA, 113.3e18, 3); // later round, +2.07% vs candidate: new candidate
        assertEq(uint8(oracle.poke(token)), uint8(SolonStockOracle.Status.Suspect));
        mock.set(NVDA, 114e18, 4); // later round within 2%: confirmed
        assertEq(uint8(oracle.poke(token)), uint8(SolonStockOracle.Status.Live));
        (uint256 p,) = oracle.execPrice(token);
        assertEq(p, 114e18);
        assertEq(oracle.candidateOf(token).price18, 0);
    }

    function testSmallMovesFollowTheSource() public {
        _list(mock);
        mock.set(NVDA, 100e18, 1);
        oracle.poke(token);
        mock.set(NVDA, 109e18, 2);
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Live)); // within 10% of the anchor
        oracle.poke(token);
        (uint128 a,) = oracle.peek(token);
        assertEq(a, 109e18);
    }

    function testGuardianPausesOwnerResumes() public {
        _list(src);
        oracle.poke(token);
        vm.expectRevert(SolonStockOracle.NotGuardian.selector);
        oracle.pause(token, "x");
        vm.prank(GUARDIAN);
        oracle.pause(token, keccak256("split"));
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Paused));
        vm.prank(GUARDIAN);
        vm.expectRevert(SolonStockOracle.NotOwner.selector);
        oracle.resume(token);
        vm.prank(OWNER);
        oracle.resume(token);
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Live));
    }

    function testGuardianOnlyTightens() public {
        _list(src);
        vm.prank(GUARDIAN);
        oracle.tighten(token, SolonStockOracle.Params(10 minutes, 500, 100, 25, 26 hours, 0));
        vm.prank(GUARDIAN);
        vm.expectRevert(SolonStockOracle.BadParams.selector);
        oracle.tighten(token, SolonStockOracle.Params(20 minutes, 500, 100, 25, 26 hours, 0));
        vm.prank(GUARDIAN);
        vm.expectRevert(SolonStockOracle.NotOwner.selector);
        oracle.configureAsset(NVDA, token, src, OracleTestLib.params());
    }

    function testConfigBoundsAndTokenBindingPermanent() public {
        _list(src);
        address other = address(new OracleTokenStub());
        vm.startPrank(OWNER);
        vm.expectRevert(SolonStockOracle.BadParams.selector);
        oracle.configureAsset(NVDA, other, src, OracleTestLib.params());
        vm.expectRevert(SolonStockOracle.BadParams.selector);
        oracle.configureAsset(address(0xA), token, src, OracleTestLib.params()); // token already bound
        vm.expectRevert(SolonStockOracle.BadParams.selector);
        oracle.configureAsset(address(0xA), other, src, SolonStockOracle.Params(8 days, 1000, 200, 50, 26 hours, 0));
        vm.expectRevert(SolonStockOracle.BadParams.selector);
        oracle.configureAsset(address(0xA), other, src, SolonStockOracle.Params(1 hours, 1000, 2000, 50, 26 hours, 0));
        vm.stopPrank();
    }

    function testSwitchingSourceResetsAcceptedPrice() public {
        _list(src);
        oracle.poke(token);
        mock.set(NVDA, 500e18, 1);
        vm.prank(OWNER);
        oracle.configureAsset(NVDA, token, mock, OracleTestLib.params());
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Suspect));
        oracle.poke(token);
        (uint256 p,) = oracle.execPrice(token);
        assertEq(p, 500e18);
    }

    function testPokeEmitsObservation() public {
        _list(src);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit SolonStockOracle.PriceObserved(
            NVDA,
            180e18,
            1e18,
            0,
            uint64(block.timestamp),
            feed.roundId(),
            uint64(block.timestamp),
            uint64(block.number),
            SolonStockOracle.Status.Live
        );
        oracle.poke(token);
    }

    // ------------------------------------------------------------ RH -> Arc relay

    function _relay() internal returns (MockLzEndpoint rh, MockLzEndpoint arc, StockPriceSender sender, RelayedStockSource relayed) {
        rh = new MockLzEndpoint(30416);
        arc = new MockLzEndpoint(30417);
        rh.connect(arc);
        arc.connect(rh);
        sender = new StockPriceSender(address(rh), OWNER, src, 30417, hex"0003");
        relayed = new RelayedStockSource(address(arc), OWNER, 30416);
        vm.startPrank(OWNER);
        sender.setPeer(30417, bytes32(uint256(uint160(address(relayed)))));
        relayed.setPeer(30416, bytes32(uint256(uint160(address(sender)))));
        vm.stopPrank();
    }

    function testRelayedChainlinkPriceReachesTheOracle() public {
        (MockLzEndpoint rh,, StockPriceSender sender, RelayedStockSource relayed) = _relay();
        _list(relayed);
        address[] memory u = new address[](2);
        u[0] = NVDA;
        u[1] = address(0xDEAD); // no feed: skipped, does not block NVDA
        uint256 fee = sender.quote(u);
        vm.deal(address(this), 1 ether);
        vm.expectEmit(true, false, false, false, address(sender));
        emit StockPriceSender.ObservationSkipped(address(0xDEAD), "");
        sender.poke{value: fee}(u);
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Stale)); // not delivered yet
        rh.deliver(0);
        StockObservation memory o = relayed.observe(NVDA);
        assertEq(o.price18, 180e18);
        assertEq(o.observedAt, block.timestamp);
        oracle.poke(token);
        (uint256 p,) = oracle.execPrice(token);
        assertEq(p, 180e18);
        vm.expectRevert(abi.encodeWithSelector(RelayedStockSource.NoObservation.selector, address(0xDEAD)));
        relayed.observe(address(0xDEAD));
        vm.warp(block.timestamp + 16 minutes); // nobody relayed since: Stale for execution
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Stale));
    }

    function testRelayIgnoresOlderAndReplayedReads() public {
        (MockLzEndpoint rh,, StockPriceSender sender, RelayedStockSource relayed) = _relay();
        address[] memory u = new address[](1);
        u[0] = NVDA;
        vm.deal(address(this), 1 ether);
        sender.poke{value: 0.01 ether}(u); // packet 0 at block N
        vm.roll(block.number + 5);
        feed.set(190e8, block.timestamp);
        sender.poke{value: 0.01 ether}(u); // packet 1 at block N+5
        rh.deliver(1);
        rh.deliver(0); // arrives late: ignored
        assertEq(relayed.observe(NVDA).price18, 190e18);
        rh.redeliver(1); // replay: ignored
        assertEq(relayed.observe(NVDA).price18, 190e18);
    }

    function testRelayRejectsForgedSenders() public {
        (, MockLzEndpoint arc,, RelayedStockSource relayed) = _relay();
        address[] memory k = new address[](1);
        k[0] = NVDA;
        StockObservation[] memory o = new StockObservation[](1);
        o[0] = StockObservation(1e18, 1e18, 1e18, 0, 1, 1, uint64(block.timestamp), 999);
        vm.expectRevert();
        arc.inject(30416, address(0xBAD), address(relayed), abi.encode(k, o));
        vm.expectRevert();
        relayed.lzReceive(
            Origin(30416, bytes32(uint256(uint160(address(0xBAD)))), 1), bytes32(0), abi.encode(k, o), address(0), ""
        );
    }

    function testSenderRefusesEmptyAndPeersAreTimelocked() public {
        (,, StockPriceSender sender, RelayedStockSource relayed) = _relay();
        address[] memory u = new address[](1);
        u[0] = address(0xDEAD);
        vm.expectRevert(StockPriceSender.NothingToSend.selector);
        sender.poke(u);
        vm.startPrank(OWNER);
        vm.expectRevert(StockPriceSender.Timelocked.selector);
        sender.setPeer(30417, bytes32(uint256(1)));
        relayed.proposePeer(30416, bytes32(uint256(2)));
        vm.expectRevert(RelayedStockSource.Timelocked.selector);
        relayed.executePeer(30416);
        vm.warp(block.timestamp + 48 hours);
        relayed.executePeer(30416);
        vm.stopPrank();
        assertEq(relayed.peers(30416), bytes32(uint256(2)));
    }

    // ------------------------------------------------------------ r7 hardening: closed market and TWAP

    /// @dev A 24/5 equity feed freezes while the market is closed: fresh relays of a frozen feed stop being
    ///      Live once the Chainlink update is older than maxSourceAge (26h), even though each read is new.
    function testFrozenFeedIsStaleAfterMaxSourceAge() public {
        _list(src);
        oracle.poke(token);
        vm.warp(block.timestamp + 26 hours);
        oracle.poke(token); // fresh read of the same Chainlink round
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Live));
        vm.warp(block.timestamp + 1);
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Stale));
        (uint256 p,) = oracle.priceUSD18(token);
        assertEq(p, 0);
        feed.set(181e8, block.timestamp); // market reopens: a new round
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Live));
    }

    function _twapList() internal returns (SolonStockOracle.Params memory p) {
        p = OracleTestLib.params();
        p.maxTwapBps = 150;
        vm.prank(OWNER);
        oracle.configureAsset(NVDA, token, mock, p);
    }

    function _obs(uint256 price18, uint256 twap18, uint256 usdg18) internal view returns (StockObservation memory) {
        return StockObservation(
            price18, 1e18, usdg18, twap18, uint64(block.timestamp), 7, uint64(block.timestamp), uint64(block.number)
        );
    }

    function testTwapCrossCheckDivergent() public {
        _twapList();
        mock.setFull(NVDA, _obs(100e18, 100e18, 1e18));
        oracle.poke(token);
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Live));
        mock.setFull(NVDA, _obs(100e18, 101.5e18, 1e18)); // Chainlink 1.478% under the TWAP of 101.5: allowed
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Live));
        mock.setFull(NVDA, _obs(100e18, 98.5e18, 1e18)); // 1.52% over the TWAP: divergent
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Divergent));
        vm.expectRevert(
            abi.encodeWithSelector(SolonStockOracle.PriceNotLive.selector, token, SolonStockOracle.Status.Divergent)
        );
        oracle.execPrice(token);
        mock.setFull(NVDA, _obs(100e18, 0, 1e18)); // no TWAP when one is required: fail closed
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Divergent));
        // the TWAP is in USDG: at USDG = $0.996 a TWAP of 100.4 USDG is $99.998
        mock.setFull(NVDA, _obs(100e18, 100.4e18, 0.996e18));
        assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Live));
    }

    function testGuardianCannotSwitchTwapCheckOff() public {
        SolonStockOracle.Params memory p = _twapList();
        p.maxTwapBps = 0;
        vm.prank(GUARDIAN);
        vm.expectRevert(SolonStockOracle.BadParams.selector);
        oracle.tighten(token, p);
        p.maxTwapBps = 100;
        p.maxSourceAge = 27 hours;
        vm.prank(GUARDIAN);
        vm.expectRevert(SolonStockOracle.BadParams.selector);
        oracle.tighten(token, p);
        p.maxSourceAge = 20 hours;
        vm.prank(GUARDIAN);
        oracle.tighten(token, p);
        assertEq(oracle.assetOf(token).params.maxTwapBps, 100);
    }

    function _pool(bool stockIs0, uint8 stableDec) internal returns (MockV3Pool pool, address stock) {
        MockDecimalsToken st = new MockDecimalsToken(18);
        MockDecimalsToken usd = new MockDecimalsToken(stableDec);
        stock = address(st);
        pool = stockIs0 ? new MockV3Pool(stock, address(usd)) : new MockV3Pool(address(usd), stock);
        vm.startPrank(OWNER);
        src.setFeed(stock, address(feed), true, address(0));
        src.setTwapPool(stock, address(pool), 30 minutes);
        vm.stopPrank();
    }

    /// @dev $180 per share against 6-dp USDG: 180e6 raw USDG per 1e18 raw stock.
    function testTwapReadBothOrderings() public {
        (MockV3Pool p0, address s0) = _pool(true, 6);
        // stock = token0: price token1/token0 = 180e6 / 1e18 = 1.8e-10 -> tick = log1.0001(1.8e-10) ~ -224391
        p0.setTick(-224_391);
        uint256 t0 = src.twapOf(s0);
        assertApproxEqRel(t0, 180e18, 0.0001e18);
        (MockV3Pool p1, address s1) = _pool(false, 6);
        p1.setTick(224_391); // token1 = stock: price = 1e18 / 180e6
        assertApproxEqRel(src.twapOf(s1), 180e18, 0.0001e18);
        StockObservation memory o = src.observe(s0);
        assertEq(o.twapPrice18, t0);
        p0.setShort(true); // pool cannot cover the window: the whole observation fails closed
        vm.expectRevert();
        src.observe(s0);
        assertEq(src.twapOf(NVDA), 0); // no pool configured: no TWAP, oracle decides whether that is allowed
    }

    function testTwapPoolSetOnceAndChecked() public {
        (MockV3Pool p0, address s0) = _pool(true, 6);
        vm.startPrank(OWNER);
        vm.expectRevert(ChainlinkStockSource.AlreadySet.selector);
        src.setTwapPool(s0, address(p0), 30 minutes);
        MockV3Pool wrong = new MockV3Pool(address(new MockDecimalsToken(6)), address(new MockDecimalsToken(6)));
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        src.setTwapPool(NVDA, address(wrong), 30 minutes); // pool does not hold the underlying
        vm.expectRevert(abi.encodeWithSelector(ChainlinkStockSource.NoFeed.selector, address(0xBEEF)));
        src.setTwapPool(address(0xBEEF), address(p0), 30 minutes);
        vm.stopPrank();
        vm.expectRevert(ChainlinkStockSource.NotOwner.selector);
        src.setTwapPool(NVDA, address(p0), 30 minutes);
    }

    /// @dev The TWAP quote is 1.0001^tick (inverted when the stock is token1), within TickMath's precision.
    function testFuzzTwapQuoteMatchesTick(int24 tick, bool stockIs0) public {
        tick = int24(bound(tick, -400_000, 400_000));
        (MockV3Pool p, address s) = _pool(stockIs0, 18);
        p.setTick(tick);
        uint256 q = src.twapOf(s);
        // reference: price(token1/token0) from sqrtPrice in 1e18 fixed point
        uint256 sq = TickMath.getSqrtPriceAtTick(tick);
        uint256 ref1per0 = sq * sq / (1 << 96) * 1e18 / (1 << 96);
        if (ref1per0 < 1e6 || ref1per0 > 1e30) return; // outside what 18-dp fixed point resolves
        uint256 ref = stockIs0 ? ref1per0 : 1e36 / ref1per0;
        assertApproxEqRel(q, ref, 0.000001e18);
    }

    /// @dev The status is a pure function of the move against the anchor: Live iff within maxMoveBps, and a
    ///      rejected jump never moves the accepted price.
    function testFuzzMoveGate(uint256 p1, uint256 p2) public {
        p1 = bound(p1, 1e12, 1e24);
        p2 = bound(p2, 1e12, 1e24);
        _list(mock);
        mock.set(NVDA, p1, 1);
        oracle.poke(token);
        mock.set(NVDA, p2, 2);
        uint256 d = p2 > p1 ? p2 - p1 : p1 - p2;
        bool within = d * 10_000 <= p1 * 1_000;
        oracle.poke(token);
        (uint128 anchor,) = oracle.peek(token);
        if (within) {
            assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Live));
            assertEq(anchor, p2);
        } else {
            assertEq(uint8(oracle.status(token)), uint8(SolonStockOracle.Status.Suspect));
            assertEq(anchor, p1);
            vm.expectRevert();
            oracle.execPrice(token);
        }
    }

    /// @dev tighten never loosens any threshold, whatever the guardian submits.
    function testFuzzTightenNeverLoosens(uint32 age, uint16 move, uint16 conf, uint16 depeg, uint32 srcAge, uint16 twap)
        public
    {
        _twapList();
        SolonStockOracle.Params memory c = oracle.assetOf(token).params;
        SolonStockOracle.Params memory p = SolonStockOracle.Params(age, move, conf, depeg, srcAge, twap);
        vm.prank(GUARDIAN);
        try oracle.tighten(token, p) {
            SolonStockOracle.Params memory n = oracle.assetOf(token).params;
            assertLe(n.maxAge, c.maxAge);
            assertLe(n.maxMoveBps, c.maxMoveBps);
            assertLe(n.confirmBps, c.confirmBps);
            assertLe(n.maxDepegBps, c.maxDepegBps);
            assertLe(n.maxSourceAge, c.maxSourceAge);
            assertLe(n.maxTwapBps, c.maxTwapBps);
            assertGt(n.maxTwapBps, 0);
        } catch {}
    }

    function testFeedsAndPoolsSetAtDeployment() public {
        MockDecimalsToken st = new MockDecimalsToken(18);
        MockV3Pool pool = new MockV3Pool(address(st), address(new MockDecimalsToken(6)));
        pool.setTick(-224_391);
        ChainlinkStockSource.FeedInit[] memory init = new ChainlinkStockSource.FeedInit[](2);
        init[0] = ChainlinkStockSource.FeedInit(address(st), address(feed), true, address(0), address(pool), 30 minutes);
        init[1] = ChainlinkStockSource.FeedInit(NVDA, address(feed), true, address(rhToken), address(0), 0);
        ChainlinkStockSource s2 = new ChainlinkStockSource(OWNER, address(usdg), WIDE, 2 days, init);
        assertEq(s2.underlyings().length, 2);
        assertApproxEqRel(s2.observe(address(st)).twapPrice18, 180e18, 0.0001e18);
        assertEq(s2.observe(NVDA).twapPrice18, 0);
        init[1] = init[0]; // duplicate underlying
        vm.expectRevert(ChainlinkStockSource.AlreadySet.selector);
        new ChainlinkStockSource(OWNER, address(usdg), WIDE, 2 days, init);
    }
}
