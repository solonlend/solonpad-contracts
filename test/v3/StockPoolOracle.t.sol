// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {HookToken} from "./helpers/HookHarness.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StockPoolVault} from "../../src/v3/stock/StockPoolVault.sol";
import {SolonStockOracle} from "../../src/v3/oracle/SolonStockOracle.sol";
import {OracleRefTickSigner, IRefTickVault} from "../../src/v3/oracle/OracleRefTickSigner.sol";
import {MockPriceSource, OracleTestLib} from "./helpers/OracleMocks.sol";
import {RestockHub} from "./StockPool.t.sol";

/// @notice r7 (design §12.2): pool A's reference price comes from SolonStockOracle through the ERC-1271
///         OracleRefTickSigner; StockPoolVault itself is unchanged.
contract StockPoolOracleTest is HookFixture {
    using StateLibrary for *;

    StockPoolVault pool;
    HookToken stock;
    RestockHub restock;
    SolonStockOracle oracle;
    MockPriceSource source;
    OracleRefTickSigner signer;
    address keeper = address(0xB07);
    address governor = address(0x60F);
    address underlying = address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);
    uint256 nonce;

    function setUp() public {
        _setUp();
        _launch(1);
        stock = HookToken(quotes[1]);
        restock = new RestockHub();
        source = new MockPriceSource();
        oracle = new SolonStockOracle(governor, governor);
        vm.prank(governor);
        oracle.configureAsset(underlying, address(stock), source, OracleTestLib.params());
        source.set(underlying, 1e18, 1); // $1 per NVDA.sol in this fixture's units -> tick 0
        oracle.poke(address(stock));
        signer = new OracleRefTickSigner(oracle);
        pool = new StockPoolVault(
            StockPoolVault.Config(
                manager,
                address(stock),
                underlying,
                address(restock),
                address(0x7EA5),
                keeper,
                address(signer),
                governor,
                address(0x7EA6)
            )
        );
        vm.deal(address(pool), 1_000 ether);
        stock.mint(address(pool), 1_000 ether);
        vm.prank(governor);
        pool.initialize(uint160(1 << 96));
    }

    function _q(int24 refTick, uint24 maxDev) internal returns (StockPoolVault.PriceQuote memory q, bytes memory sig) {
        q = StockPoolVault.PriceQuote(refTick, maxDev, block.timestamp + 60, ++nonce);
        sig = abi.encode(q);
    }

    function testOracleTickDerivation() public {
        assertEq(signer.refTickOf(address(stock)), 0);
        source.set(underlying, 180e18, 2); // $180 -> STOCK per USDC = 1/180 -> tick floor(log1.0001(1/180)) = -51933
        oracle.poke(address(stock)); // > 10% move: candidate
        source.set(underlying, 180e18, 3);
        oracle.poke(address(stock)); // confirmed
        int24 t = signer.refTickOf(address(stock));
        assertEq(t, -51933);
        // the tick's price brackets 1/180
        uint256 lo = uint256(TickMath.getSqrtPriceAtTick(t));
        uint256 hi = uint256(TickMath.getSqrtPriceAtTick(t + 1));
        assertLe(lo * lo / (1 << 96) * 180 / (1 << 96), 1);
        assertGe(hi * hi / (1 << 96) * 180 * 1e6 / (1 << 96), 1e6 - 1);
    }

    function testRangeUsesTheOracleReference() public {
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _q(0, 100);
        vm.prank(keeper);
        pool.rebalanceRange(-400, 400, q, sig);
        assertGt(pool.liquidity(), 0);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.BadQuote.selector);
        pool.rebalanceRange(-400, 400, q, sig); // nonce spent
    }

    function testKeeperCannotChooseAnotherReference() public {
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _q(11, 100); // 11 ticks off the oracle
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.BadQuote.selector);
        pool.rebalanceRange(-400, 400, q, sig);
        (q, sig) = _q(10, 100); // within tolerance
        vm.prank(keeper);
        pool.rebalanceRange(-400, 400, q, sig);
    }

    function testEncodedQuoteMustMatchTheCheckedDigest() public {
        (StockPoolVault.PriceQuote memory q,) = _q(0, 100);
        StockPoolVault.PriceQuote memory other = StockPoolVault.PriceQuote(0, 200, q.deadline, q.nonce);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.BadQuote.selector);
        pool.rebalanceRange(-400, 400, q, abi.encode(other));
    }

    function testNoLivePriceNoKeeperAction() public {
        vm.prank(governor);
        oracle.pause(address(stock), "halt");
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _q(0, 100);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.BadQuote.selector);
        pool.rebalanceRange(-400, 400, q, sig);
        vm.prank(governor);
        oracle.resume(address(stock));
        vm.warp(block.timestamp + 16 minutes); // observation too old
        (q, sig) = _q(0, 100);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.BadQuote.selector);
        pool.rebalanceRange(-400, 400, q, sig);
    }

    function testRestockMinimumBoundToOracleReference() public {
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _q(0, 100);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.Slippage.selector);
        pool.restockMint(10 ether, 1, 0.1 ether, q, sig);
        (q, sig) = _q(0, 100);
        vm.prank(keeper);
        pool.restockMint(10 ether, 9.9 ether, 0.1 ether, q, sig);
        assertEq(restock.callCount(), 1);
    }

    function testSignerRejectsDirectCallsFromNonVaults() public {
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _q(0, 100);
        bytes32 digest = pool.quoteDigest(q);
        vm.prank(address(0xE0A));
        vm.expectRevert(); // a caller that is not a vault has no quoteDigest
        signer.isValidSignature(digest, sig);
        IRefTickVault.PriceQuote memory rq = IRefTickVault.PriceQuote(q.refTick, q.maxDeviation, q.deadline, q.nonce);
        assertEq(signer.encode(rq), sig);
    }
}
