// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/*
  ChainlinkStockFeed — fail-closed Chainlink reads for tokenized-equity feeds.

  Provenance: adapted from Solon lending's stocklend/contracts/src/StockOracleAdapter.sol
  (GPL-2.0-or-later, three review passes) and the lessons in stocklend/DESIGN-DETAILED.md §2.2–2.3.
  Kept from the original (each rule is tested in test/v3/StockOracle.t.sol):
    · fail-closed round checks: answer > 0, updatedAt != 0, roundId != 0, answeredInRound >= roundId,
      plus startedAt != 0 (DESIGN-DETAILED §2.2 item 5: answeredInRound is deprecated upstream and may be
      constant, so it cannot be the only guard) and updatedAt <= now;
    · the feed's decimals are read, never assumed to be 8;
    · multiply before divide (normalising to 18 dp scales up for decimals <= 18);
    · multiplier branch A/B fixed per feed at configuration: A = the feed already includes the stock
      token's uiMultiplier (preferred — immune to a multiplier-decimals upgrade), B = bare per-share price
      times uiMultiplier() read from the token (mult == 0 -> revert);
    · only a very wide on-chain staleness bound: Chainlink equity feeds are 24/5 and freeze with no
      heartbeat while the market is closed (nights, weekends, holidays), so a tight hour bound cannot tell
      "closed, correctly frozen" from "broken". Fine freshness belongs to the off-chain keeper calendar.
  Changed: the output is a USD price with 18 decimals per raw token (not a Morpho 1e36-scaled price);
  the quote-stable leg (USDG/USD on Robinhood Chain, USDC/USD on Arc) is read separately by the caller
  as a de-peg guard instead of being divided in.
*/

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IStockMultiplier {
    function uiMultiplier() external view returns (uint256); // 18 dp
}

library ChainlinkStockFeed {
    error BadRound();
    error StalePrice();
    error NonPositive();
    error FeedDecimals();

    struct Reading {
        uint256 price18; // USD per raw token, 18 dp
        uint256 updatedAt;
        uint80 roundId;
    }

    /// @notice One fail-closed read of `feed`, normalised to 18 dp. Reverts instead of returning a dirty value.
    function read(address feed, uint256 maxStaleness) internal view returns (Reading memory r) {
        (uint80 roundId, int256 ans, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(feed).latestRoundData();
        if (updatedAt == 0 || roundId == 0 || startedAt == 0) revert BadRound();
        if (answeredInRound < roundId || updatedAt > block.timestamp) revert BadRound();
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice();
        if (ans <= 0) revert NonPositive();
        uint256 dec = IAggregatorV3(feed).decimals();
        if (dec > 36) revert FeedDecimals();
        // multiply before divide: scale up when the feed has fewer than 18 decimals
        r.price18 = dec <= 18 ? uint256(ans) * 10 ** (18 - dec) : uint256(ans) / 10 ** (dec - 18);
        if (r.price18 == 0) revert NonPositive();
        r.updatedAt = updatedAt;
        r.roundId = roundId;
    }

    /// @notice Branch B: per-share price times the token's uiMultiplier (18 dp). Multiply before divide.
    function applyMultiplier(uint256 price18, address stockToken) internal view returns (uint256) {
        uint256 mult = IStockMultiplier(stockToken).uiMultiplier();
        if (mult == 0) revert NonPositive();
        uint256 p = (price18 * mult) / 1e18;
        if (p == 0) revert NonPositive();
        return p;
    }
}
