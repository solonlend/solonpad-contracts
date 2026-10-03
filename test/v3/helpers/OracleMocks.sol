// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IStockPriceSource, StockObservation} from "../../../src/v3/oracle/IStockPriceSource.sol";
import {SolonStockOracle} from "../../../src/v3/oracle/SolonStockOracle.sol";

/// @notice Chainlink AggregatorV3 test double.
contract MockAggregator {
    uint8 public decimals;
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;

    constructor(uint8 dec, int256 ans) {
        decimals = dec;
        set(ans, block.timestamp);
    }

    function set(int256 ans, uint256 at) public {
        answer = ans;
        updatedAt = at;
        startedAt = at;
        ++roundId;
        answeredInRound = roundId;
    }

    function setRaw(uint80 r, int256 a, uint256 s, uint256 u, uint80 air) external {
        roundId = r;
        answer = a;
        startedAt = s;
        updatedAt = u;
        answeredInRound = air;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

contract MockMultiplierToken {
    uint256 public mult = 1e18;
    bool public broken;

    function setMultiplier(uint256 m) external {
        mult = m;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function uiMultiplier() external view returns (uint256) {
        require(!broken, "broken");
        return mult;
    }
}

/// @notice Settable IStockPriceSource.
contract MockPriceSource is IStockPriceSource {
    mapping(address => StockObservation) public obs;
    mapping(address => bool) public failing;

    /// @dev A `sourceUpdatedAt` below 1e6 is a round sequence number: stored as now + seq (a fresh feed
    ///      update, ordered by seq), so the oracle's feed-age rule does not see a 1970 timestamp.
    function set(address u, uint256 price18, uint64 sourceUpdatedAt) public {
        uint64 at = sourceUpdatedAt < 1e6 ? uint64(block.timestamp) + sourceUpdatedAt : sourceUpdatedAt;
        obs[u] = StockObservation(
            price18, 1e18, 1e18, 0, at, uint80(sourceUpdatedAt), uint64(block.timestamp), uint64(block.number)
        );
    }

    function setFull(address u, StockObservation memory o) external {
        obs[u] = o;
    }

    function setFailing(address u, bool f) external {
        failing[u] = f;
    }

    function observe(address u) external view returns (StockObservation memory o) {
        require(!failing[u], "source down");
        o = obs[u];
        require(o.observedAt != 0, "none");
    }
}

/// @notice Stand-in Arc stock token address holder (the oracle needs code at the token address).
contract OracleTokenStub {}

library OracleTestLib {
    function params() internal pure returns (SolonStockOracle.Params memory) {
        return SolonStockOracle.Params(15 minutes, 1_000, 200, 50, 26 hours, 0);
    }
}

/// @notice Consumer-side SolonStockOracle stand-in (execPrice/rawFor/usdFor/priceUSD18). Price 0 = no floor
///         (rawFor/usdFor return 0), which keeps pre-r7 consumer tests unchanged; set a price to test floors.
///         Installed with vm.etch at FLOOR_ORACLE so no CREATE nonce moves in address-predicting fixtures.
contract FloorOracleStub {
    mapping(address => uint256) public price;
    bool public down;

    function setPrice(address asset, uint256 p) external {
        price[asset] = p;
    }

    function setDown(bool d) external {
        down = d;
    }

    function execPrice(address asset) public view returns (uint256, uint256) {
        require(!down, "PriceNotLive");
        return (price[asset], block.timestamp);
    }

    function rawFor(address asset, uint256 usd18) external view returns (uint256) {
        (uint256 p,) = execPrice(asset);
        return p == 0 ? 0 : usd18 * 1e18 / p;
    }

    function usdFor(address asset, uint256 raw) external view returns (uint256) {
        (uint256 p,) = execPrice(asset);
        return raw * p / 1e18;
    }

    function priceUSD18(address asset) external view returns (uint256, uint256) {
        if (down) return (0, 0);
        return (price[asset], block.timestamp);
    }
}

address constant FLOOR_ORACLE = address(0xF100F100f100F100f100f100f100f100f100f100);

/// @notice Uniswap V3 pool observe() double: a constant mean tick over any window.
contract MockV3Pool {
    address public token0;
    address public token1;
    int24 public meanTick;
    bool public short; // too little cardinality: observe reverts

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function setTick(int24 t) external {
        meanTick = t;
    }

    function setShort(bool s) external {
        short = s;
    }

    function observe(uint32[] calldata ago) external view returns (int56[] memory c, uint160[] memory l) {
        require(!short, "OLD");
        c = new int56[](ago.length);
        l = new uint160[](ago.length);
        for (uint256 i; i < ago.length; ++i) {
            c[i] = int56(meanTick) * -int56(uint56(ago[i])) + 1_000_000;
        }
    }
}

contract MockDecimalsToken {
    uint8 public decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}
