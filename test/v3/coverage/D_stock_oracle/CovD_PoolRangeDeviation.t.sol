// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookToken} from "../../helpers/HookHarness.sol";
import {RestockHub} from "../../StockPool.t.sol";
import {StockPoolVault} from "../../../../src/v3/stock/StockPoolVault.sol";

/// @notice StockPoolVault L211-213: `rebalanceRange` refuses when the pool tick is further from the signed
///         reference than the quote's `maxDeviation`, or than `RANGE_DEVIATION` (50) even with a looser quote (<= 200);
///         a gap equal to the limit passes. Both orientations of the gap (tick above / below the reference).
contract CovDPoolRangeDeviationTest is Test {
    uint256 constant SIGNER = 0x9A1C;
    PoolManager manager;
    StockPoolVault pool;
    HookToken stock;
    address keeper = address(0xB07);
    address governor = address(0x60F);
    uint256 nonce;

    function setUp() public {
        manager = new PoolManager(address(this));
        stock = new HookToken();
        RestockHub restock = new RestockHub();
        pool = new StockPoolVault(
            StockPoolVault.Config(
                IPoolManager(address(manager)),
                address(stock),
                address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC),
                address(restock),
                address(0x7EA5),
                keeper,
                vm.addr(SIGNER),
                governor,
                address(0x7EA6)
            )
        );
        vm.deal(address(pool), 1_000 ether);
        stock.mint(address(pool), 1_000 ether);
        vm.prank(governor);
        pool.initialize(uint160(1 << 96)); // tick 0
    }

    function _quote(int24 refTick, uint24 maxDev) internal returns (StockPoolVault.PriceQuote memory q, bytes memory sig) {
        q = StockPoolVault.PriceQuote(refTick, maxDev, block.timestamp + 60, ++nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER, pool.quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    function _expectDeviation(int24 refTick, uint24 maxDev) internal {
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(refTick, maxDev);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.PriceDeviation.selector);
        pool.rebalanceRange(-200, 200, q, sig);
        assertFalse(pool.nonceUsed(q.nonce), "nothing consumed");
        assertEq(pool.liquidity(), 0, "no position added");
    }

    function _rangeOk(int24 refTick, uint24 maxDev) internal {
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(refTick, maxDev);
        vm.prank(keeper);
        pool.rebalanceRange(-200, 200, q, sig);
        assertTrue(pool.nonceUsed(q.nonce));
        assertGt(pool.liquidity(), 0);
        assertEq(pool.currentTick(), 0);
    }

    /// gap (30) > the quote's maxDeviation (29), well inside RANGE_DEVIATION; both gap orientations.
    function testCovD_GapAboveQuoteMaxDeviationReverts() public {
        assertEq(pool.RANGE_DEVIATION(), 50);
        _expectDeviation(30, 29); // tick 0 < ref 30
        _expectDeviation(-30, 29); // tick 0 > ref -30
    }

    /// gap (51) > RANGE_DEVIATION even though the quote allows the loosest signable deviation
    /// (MAX_DEVIATION = 200; anything looser is refused earlier as BadQuote); both orientations.
    function testCovD_GapAboveRangeDeviationRevertsEvenWithLooseQuote() public {
        assertEq(pool.MAX_DEVIATION(), 200);
        _expectDeviation(51, 200);
        _expectDeviation(-51, 200);
        _expectDeviation(200, 200);
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(51, 201);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.BadQuote.selector);
        pool.rebalanceRange(-200, 200, q, sig);
    }

    /// Boundary: gap == maxDeviation passes.
    function testCovD_GapEqualToQuoteMaxDeviationPasses() public {
        _rangeOk(30, 30);
    }

    /// Boundary: gap == RANGE_DEVIATION (50) passes with a loose quote, for both orientations.
    function testCovD_GapEqualToRangeDeviationPasses() public {
        _rangeOk(50, 200);
        _rangeOk(-50, 50);
    }
}
