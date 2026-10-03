// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkStockFeed, IAggregatorV3} from "../../src/v3/oracle/ChainlinkStockFeed.sol";
import {ChainlinkStockSource} from "../../src/v3/oracle/ChainlinkStockSource.sol";
import {SolonStockOracle} from "../../src/v3/oracle/SolonStockOracle.sol";
import {StockPriceSender} from "../../src/v3/oracle/StockPriceSender.sol";
import {RelayedStockSource} from "../../src/v3/oracle/RelayedStockSource.sol";
import {StockObservation} from "../../src/v3/oracle/IStockPriceSource.sol";
import {MockLzEndpoint} from "./helpers/StockMocks.sol";
import {OracleTokenStub, OracleTestLib} from "./helpers/OracleMocks.sol";

/// FORK (Robinhood Chain mainnet 4663): the RH-side source reads the REAL Chainlink equity feeds (addresses from
/// stocklend/solon-skill/addresses.json, re-checked 2026-10-01 against the Chainlink reference-data directory
/// feeds-robinhood-mainnet.json: "Robinhood NVDA/AAPL/TSLA / USD", 8 dp, marketHours us_equities_24/5) and the
/// relay delivers them to the Arc oracle. Pattern follows stocklend leverage/test/fork/RhOracleFork.t.sol:
/// skipped when the RPC is unreachable unless REQUIRE_RH_FORK=true. A closed market (weekend/holiday) beyond the
/// wide bound must fail closed with StalePrice.
contract StockOracleForkTest is Test {
    string constant RPC = "https://rpc.mainnet.chain.robinhood.com/rpc";
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    uint256 constant WIDE = 4 days;
    // Deepest stock/USDG Uniswap V3 pools on RH (factory 0x1F7D…2efA getPool, liquidity read 2026-10-01).
    address constant NVDA_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3; // fee 500
    address constant AAPL_POOL = 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D; // fee 500
    address constant TSLA_POOL = 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3; // fee 3000

    bool forked;
    ChainlinkStockSource src;

    function setUp() public {
        try vm.createSelectFork(RPC) {
            forked = true;
            src = new ChainlinkStockSource(address(this), USDG_FEED, WIDE, 26 hours, new ChainlinkStockSource.FeedInit[](0));
            src.setFeed(NVDA, NVDA_FEED, true, NVDA);
            src.setFeed(AAPL, AAPL_FEED, true, AAPL);
            src.setFeed(TSLA, TSLA_FEED, true, TSLA);
        } catch {
            if (vm.envOr("REQUIRE_RH_FORK", false)) revert("required RH fork unavailable");
        }
    }

    function _check(address underlying, address feed, string memory name) internal {
        (,,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        assertEq(IAggregatorV3(feed).decimals(), 8, "equity feed decimals");
        if (block.timestamp - updatedAt > WIDE) {
            emit log_named_string("feed beyond the wide bound (fail-closed expected)", name);
            vm.expectRevert(ChainlinkStockFeed.StalePrice.selector);
            src.observe(underlying);
            return;
        }
        StockObservation memory o = src.observe(underlying);
        emit log_named_decimal_uint(string.concat(name, " USD"), o.price18, 18);
        emit log_named_uint(string.concat(name, " feed age (s)"), block.timestamp - updatedAt);
        emit log_named_decimal_uint(string.concat(name, " RH uiMultiplier"), o.multiplier, 18);
        emit log_named_decimal_uint("USDG/USD", o.quoteUsd18, 18);
        assertGt(o.price18, 1e18, "a listed equity above $1");
        assertLt(o.price18, 100_000e18, "and below $100k");
        assertApproxEqRel(o.quoteUsd18, 1e18, 0.01e18, "USDG near $1");
    }

    function testRealFeedsReadFailClosed() public {
        vm.skip(!forked, "RH fork unavailable");
        _check(NVDA, NVDA_FEED, "NVDA");
        _check(AAPL, AAPL_FEED, "AAPL");
        _check(TSLA, TSLA_FEED, "TSLA");
    }

    /// @notice Full path on the fork: StockPriceSender reads the real feeds, the (mock) LayerZero endpoint delivers
    ///         to RelayedStockSource, and SolonStockOracle gives a Live execution price equal to Chainlink's answer.
    function testRelayedRealPriceIsLiveOnTheOracle() public {
        vm.skip(!forked, "RH fork unavailable");
        (,,, uint256 updatedAt,) = IAggregatorV3(NVDA_FEED).latestRoundData();
        vm.skip(block.timestamp - updatedAt > WIDE, "NVDA feed beyond the wide bound (market closed)");
        MockLzEndpoint rh = new MockLzEndpoint(30416);
        MockLzEndpoint arc = new MockLzEndpoint(30417);
        rh.connect(arc);
        arc.connect(rh);
        StockPriceSender sender = new StockPriceSender(address(rh), address(this), src, 30417, "");
        RelayedStockSource relayed = new RelayedStockSource(address(arc), address(this), 30416);
        sender.setPeer(30417, bytes32(uint256(uint160(address(relayed)))));
        relayed.setPeer(30416, bytes32(uint256(uint160(address(sender)))));
        SolonStockOracle oracle = new SolonStockOracle(address(this), address(0x6A));
        address token = address(new OracleTokenStub());
        oracle.configureAsset(NVDA, token, relayed, OracleTestLib.params());
        address[] memory u = new address[](3);
        (u[0], u[1], u[2]) = (NVDA, AAPL, TSLA);
        vm.deal(address(this), 1 ether);
        sender.poke{value: 0.01 ether}(u);
        rh.deliver(0);
        oracle.poke(token);
        (uint256 p,) = oracle.execPrice(token);
        (, int256 ans,,,) = IAggregatorV3(NVDA_FEED).latestRoundData();
        assertEq(p, uint256(ans) * 1e10, "execution price = Chainlink answer (branch A, 8 -> 18 dp)");
    }

    /// @notice The RH pool TWAP (30 min) against Chainlink on real data: logs the gap the oracle's maxTwapBps
    ///         (150 bps default) is checked against, and asserts the read is sane.
    function testRealPoolTwapAgainstChainlink() public {
        vm.skip(!forked, "RH fork unavailable");
        src.setTwapPool(NVDA, NVDA_POOL, 30 minutes);
        src.setTwapPool(AAPL, AAPL_POOL, 30 minutes);
        src.setTwapPool(TSLA, TSLA_POOL, 30 minutes);
        address[3] memory u = [NVDA, AAPL, TSLA];
        string[3] memory n = ["NVDA", "AAPL", "TSLA"];
        for (uint256 i; i < 3; ++i) {
            try src.observe(u[i]) returns (StockObservation memory o) {
                uint256 twapUsd = o.twapPrice18 * o.quoteUsd18 / 1e18;
                uint256 gap = o.price18 > twapUsd ? o.price18 - twapUsd : twapUsd - o.price18;
                emit log_named_decimal_uint(string.concat(n[i], " Chainlink USD"), o.price18, 18);
                emit log_named_decimal_uint(string.concat(n[i], " 30m TWAP USD"), twapUsd, 18);
                emit log_named_uint(string.concat(n[i], " gap bps"), gap * 10_000 / o.price18);
                assertApproxEqRel(twapUsd, o.price18, 0.1e18, "TWAP within 10% of Chainlink (sanity)");
            } catch (bytes memory reason) {
                emit log_named_bytes(string.concat(n[i], " observe failed (fail closed)"), reason);
            }
        }
    }

    receive() external payable {}
}
