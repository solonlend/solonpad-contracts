// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {HookToken} from "./helpers/HookHarness.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {StockPoolVault} from "../../src/v3/stock/StockPoolVault.sol";
import {V3MultiHopRouter, IV3HopEligibility} from "../../src/v3/V3MultiHopRouter.sol";

/// @notice Stand-in for the hub's order entry points used by the restock bot.
contract RestockHub {
    struct Call {
        address caller;
        bool buy;
        address underlying;
        uint256 amount;
        uint256 minOut;
        uint256 value;
    }

    Call[] public calls;

    function requestBuy(address underlying, uint256 usdcIn, uint256 minShares) external payable returns (uint256) {
        calls.push(Call(msg.sender, true, underlying, usdcIn, minShares, msg.value));
        return calls.length - 1;
    }

    function requestSell(address underlying, uint256 shares, uint256 minUsdc) external payable returns (uint256) {
        calls.push(Call(msg.sender, false, underlying, shares, minUsdc, msg.value));
        return calls.length - 1;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    struct Exit {
        address caller;
        uint8 kind; // 0 cancel, 1 escalate, 2 escalateFunds
        uint256 id;
        address to;
        uint256 value;
    }

    Exit[] public exits;

    function cancel(uint256 id) external {
        exits.push(Exit(msg.sender, 0, id, address(0), 0));
    }

    function escalate(uint256 id, address to) external payable {
        exits.push(Exit(msg.sender, 1, id, to, msg.value));
    }

    function escalateFunds(uint256 id, address to) external payable {
        exits.push(Exit(msg.sender, 2, id, to, msg.value));
    }
}

contract StockPoolTest is HookFixture {
    using StateLibrary for *;

    uint256 constant SIGNER = 0x9A1C;
    StockPoolVault pool;
    V3MultiHopRouter hop;
    RestockHub restock;
    HookToken stock; // plays NVDA.sol: the quote of keys[1]
    HookToken meme;
    address keeper = address(0xB07);
    address treasury = address(0x7EA5);
    address governor = address(0x60F);
    address underlying = address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);
    address recipient = address(0xCAFE);
    address rhTreasury = address(0x7EA6);
    uint256 nonce;

    function setUp() public {
        _setUp();
        _launch(1); // stock-quote meme pool: quote = quotes[1], meme = memes[1]
        stock = HookToken(quotes[1]);
        meme = HookToken(memes[1]);
        restock = new RestockHub();
        pool = new StockPoolVault(
            StockPoolVault.Config(
                manager,
                address(stock),
                underlying,
                address(restock),
                treasury,
                keeper,
                vm.addr(SIGNER),
                governor,
                rhTreasury
            )
        );
        vm.deal(address(pool), 1_000 ether);
        stock.mint(address(pool), 1_000 ether);
        vm.prank(governor);
        pool.initialize(uint160(1 << 96)); // 1 NVDA.sol per USDC in this fixture's units, tick 0
        _range(-400, 400, 0, 100);
        hop = new V3MultiHopRouter(manager, hook, pool.poolKey(), IV3HopEligibility(address(0)));
        meme.approve(address(hop), type(uint256).max);
    }

    function _quote(int24 refTick, uint24 maxDev)
        internal
        returns (StockPoolVault.PriceQuote memory q, bytes memory sig)
    {
        q = StockPoolVault.PriceQuote(refTick, maxDev, block.timestamp + 60, ++nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER, pool.quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    function _range(int24 lower, int24 upper, int24 refTick, uint24 maxDev) internal {
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(refTick, maxDev);
        vm.prank(keeper);
        pool.rebalanceRange(lower, upper, q, sig);
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(pool.poolKey().toId());
    }

    function _req(bool buy, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (V3MultiHopRouter.HopRequest memory)
    {
        return V3MultiHopRouter.HopRequest(keys[1], buy, amountIn, minOut, recipient, block.timestamp);
    }

    // ------------------------------------------------------------ pool A

    function testPoolAIsAPlainOnePercentPoolOwnedByTheVault() public view {
        PoolKey memory k = pool.poolKey();
        assertEq(Currency.unwrap(k.currency0), address(0), "native USDC");
        assertEq(Currency.unwrap(k.currency1), address(stock));
        assertEq(k.fee, 10_000, "1% LP fee to the protocol");
        assertEq(address(k.hooks), address(0), "not a v3 hook pool");
        assertGt(pool.liquidity(), 0);
        assertEq(pool.tickLower(), -400);
        assertEq(pool.tickUpper(), 400);
    }

    function testRangeNeedsTheSignedPriceANarrowWidthAndTheKeeper() public {
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(0, 100);
        vm.expectRevert(StockPoolVault.NotKeeper.selector);
        pool.rebalanceRange(-200, 200, q, sig);
        vm.startPrank(keeper);
        vm.expectRevert(StockPoolVault.BadRange.selector);
        pool.rebalanceRange(200, 400, q, sig); // does not contain the reference price
        vm.expectRevert(StockPoolVault.BadRange.selector);
        pool.rebalanceRange(-2200, 2200, q, sig); // wider than the approved narrow band
        vm.stopPrank();
        (StockPoolVault.PriceQuote memory far, bytes memory farSig) = _quote(600, 100);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.PriceDeviation.selector); // pool price not near the signed reference
        pool.rebalanceRange(400, 800, far, farSig);
        (StockPoolVault.PriceQuote memory bad,) = _quote(0, 100);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, pool.quoteDigest(bad));
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.BadQuote.selector);
        pool.rebalanceRange(-200, 200, bad, abi.encodePacked(r, s, v));
        vm.prank(keeper);
        pool.rebalanceRange(-200, 200, q, sig);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.BadQuote.selector);
        pool.rebalanceRange(-200, 200, q, sig); // nonce spent
    }

    function testPushPriceMovesTowardTheReferenceAndNeverPastIt() public {
        // A buyer drains NVDA.sol: pool price of the stock rises (tick falls below the reference).
        hop.swapExactIn{value: 300 ether}(_req(true, 300 ether, 1));
        stock.mint(address(pool), 1_000 ether); // restocked inventory (minted through the hub in production)
        int24 before = _tick();
        assertLt(before, -100);
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(0, 200);
        uint256 stockBefore = stock.balanceOf(address(pool));
        vm.prank(keeper);
        pool.pushPrice(q, sig, 1_000 ether); // more than enough: the signed reference is the stop
        int24 afterTick = _tick();
        assertGt(afterTick, before, "sold NVDA.sol back into the pool");
        assertLe(afterTick, 0, "stops at the signed reference");
        assertGe(afterTick, -1);
        assertLt(stock.balanceOf(address(pool)), stockBefore);
    }

    function testLpFeesStayWithTheVaultAndOnlyTheTimelockWithdrawsToTreasury() public {
        hop.swapExactIn{value: 20 ether}(_req(true, 20 ether, 1));
        hop.swapExactIn(_req(false, 1 ether, 1));
        assertEq(pool.lpFees0() + pool.lpFees1(), 0);
        _range(-400, 400, _tick(), 200); // collects the 1% LP fees into the vault
        assertGt(pool.lpFees0(), 0.19 ether, "about 1% of the 20 USDC input");
        assertGt(pool.lpFees1(), 0, "and 1% of the NVDA.sol input of the sell");
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.NotOwner.selector);
        pool.withdraw(1 ether, 0);
        vm.prank(governor);
        pool.exit();
        assertEq(pool.liquidity(), 0);
        vm.prank(governor);
        pool.withdraw(1 ether, 1 ether);
        assertEq(treasury.balance, 1 ether);
        assertEq(stock.balanceOf(treasury), 1 ether);
    }

    function testRestockMintsAndRedeemsOnlyThroughTheHubForTheVault() public {
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(0, 100);
        vm.prank(address(0xBAD));
        vm.expectRevert(StockPoolVault.NotKeeper.selector);
        pool.restockMint(100 ether, 1, 1 ether, q, sig);
        vm.prank(governor);
        pool.exit();
        vm.prank(keeper);
        pool.restockMint(100 ether, 99 ether, 1 ether, q, sig);
        (q, sig) = _quote(0, 100);
        vm.prank(keeper);
        pool.restockRedeem(50 ether, 49.4 ether, 0.01 ether, q, sig);
        (address caller, bool buy, address u, uint256 amount, uint256 minOut, uint256 value) = restock.calls(0);
        assertEq(caller, address(pool));
        assertTrue(buy);
        assertEq(u, underlying);
        assertEq(amount, 100 ether);
        assertEq(minOut, 99 ether);
        assertEq(value, 101 ether);
        (caller, buy,, amount,, value) = restock.calls(1);
        assertFalse(buy);
        assertEq(amount, 50 ether);
        assertEq(value, 0.01 ether);
    }

    /// Review #7: restock minimums are bound to a signed reference price (and its signed tolerance, at
    /// most ~2%, less the 25 bps fee); the keeper can no longer send 0 and be sandwiched.
    function testRestockMinimumsAreBoundToTheSignedPrice() public {
        vm.prank(governor);
        pool.exit();
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(0, 100); // 1 NVDA.sol per USDC, ±~1%
        vm.startPrank(keeper);
        vm.expectRevert(StockPoolVault.Slippage.selector);
        pool.restockMint(100 ether, 0, 1 ether, q, sig);
        vm.expectRevert(StockPoolVault.Slippage.selector);
        pool.restockMint(100 ether, 98 ether, 1 ether, q, sig); // below 100 x 0.99 x 0.9975
        vm.expectRevert(StockPoolVault.Slippage.selector);
        pool.restockRedeem(100 ether, 0, 0.01 ether, q, sig);
        vm.stopPrank();
        (StockPoolVault.PriceQuote memory wide, bytes memory wideSig) = _quote(0, 201);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.BadQuote.selector); // tolerance above the 2% ceiling
        pool.restockMint(100 ether, 97 ether, 1 ether, wide, wideSig);
        // At tick 6932 (~2 NVDA.sol per USDC) a 100 USDC mint must ask for ~198 shares.
        (q, sig) = _quote(6932, 100);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.Slippage.selector);
        pool.restockMint(100 ether, 100 ether, 1 ether, q, sig);
        vm.prank(keeper);
        pool.restockMint(100 ether, 198 ether, 1 ether, q, sig);
        (StockPoolVault.PriceQuote memory old, bytes memory oldSig) = _quote(0, 100);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.BadQuote.selector); // stale
        pool.restockMint(100 ether, 99 ether, 1 ether, old, oldSig);
    }

    /// Review #7: the vault's own restock orders have exits: cancel, and the canonical lane to a fixed
    /// reserve-chain recipient (never a keeper-chosen address), paying the 1 USDC hook.
    function testRestockOrdersHaveFixedExits() public {
        vm.deal(address(pool), 10 ether); // idle native pays the hooks (the position holds the rest)
        vm.prank(address(0xBAD));
        vm.expectRevert(StockPoolVault.NotKeeper.selector);
        pool.cancelRestock(7);
        vm.startPrank(keeper);
        pool.cancelRestock(7);
        pool.escalateRestock(8);
        pool.escalateRestockFunds(9);
        vm.stopPrank();
        vm.prank(governor);
        pool.escalateRestockFunds(10);
        (address caller, uint8 kind, uint256 id,,) = restock.exits(0);
        assertEq(caller, address(pool));
        assertEq(kind, 0);
        assertEq(id, 7);
        address to;
        uint256 value;
        (, kind, id, to, value) = restock.exits(1);
        assertEq(kind, 1);
        assertEq(to, rhTreasury, "fixed reserve-chain recipient");
        assertEq(value, 1 ether, "pays the canonical hook");
        (, kind, id, to,) = restock.exits(2);
        assertEq(kind, 2);
        assertEq(id, 9);
        assertEq(to, rhTreasury);
    }

    /// Review low: anchoring must work exactly when the pool is far from the reference.
    function testPushPriceWorksBeyondTheTwoPercentBand() public {
        hop.swapExactIn{value: 600 ether}(_req(true, 600 ether, 1));
        stock.mint(address(pool), 2_000 ether);
        int24 before = _tick();
        assertLt(before, -200, "beyond the old ~2% window");
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(0, 200);
        vm.prank(keeper);
        pool.pushPrice(q, sig, 2_000 ether);
        assertLe(_tick(), 0);
        assertGe(_tick(), -1, "pushed back to the reference, not past it");
    }

    /// Review low: liquidity is only re-added when the pool already sits at the reference (~0.5%) and
    /// inside the new range, whatever tolerance the quote allows.
    function testRangeIsOnlyAddedAtTheReferencePrice() public {
        hop.swapExactIn{value: 300 ether}(_req(true, 300 ether, 1));
        int24 t = _tick();
        assertLt(t, -60);
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(0, 200);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.PriceDeviation.selector);
        pool.rebalanceRange(-400, 400, q, sig);
        (q, sig) = _quote(t, 10);
        vm.prank(keeper);
        pool.rebalanceRange(-400, 400, q, sig);
        assertGt(pool.liquidity(), 0);
    }

    // ------------------------------------------------------------ multi-hop router

    function testBuyMemeWithUsdcInOneTransactionAndQuoteMatches() public {
        bytes32 memePool = PoolId.unwrap(keys[1].toId());
        uint256 feeBefore = ledger.totalReceived(memePool);
        (uint256 qOut, uint256 poolAFee, uint256 hookFee) =
            hop.quote{value: 10 ether}(_req(true, 10 ether, 1), address(this));
        assertEq(meme.balanceOf(recipient), 0, "quote changes nothing");
        uint256 out = hop.swapExactIn{value: 10 ether}(_req(true, 10 ether, 1));
        assertEq(out, qOut);
        assertEq(meme.balanceOf(recipient), out);
        assertEq(poolAFee, 0.1 ether, "1% exchange fee on pool A, shown separately");
        assertEq(ledger.totalReceived(memePool) - feeBefore, hookFee);
        assertGt(hookFee, 0, "the v3 hook still takes its 1% in NVDA.sol");
        assertEq(address(hop).balance, 0);
        assertEq(stock.balanceOf(address(hop)), 0);
    }

    function testSellMemeBackToUsdc() public {
        hop.swapExactIn{value: 10 ether}(_req(true, 10 ether, 1));
        uint256 before = recipient.balance;
        uint256 out = hop.swapExactIn(_req(false, 1 ether, 1));
        assertEq(recipient.balance - before, out);
        assertGt(out, 0);
    }

    function testRejectsPoolsThatAreNotStockQuotedByPoolAsAsset() public {
        V3MultiHopRouter.HopRequest memory r = _req(true, 1 ether, 1);
        r.memeKey = keys[0]; // native-quoted meme pool
        vm.expectRevert(V3MultiHopRouter.UnknownPool.selector);
        hop.swapExactIn{value: 1 ether}(r);
        r.memeKey = keys[2]; // not registered
        vm.expectRevert(V3MultiHopRouter.UnknownPool.selector);
        hop.swapExactIn{value: 1 ether}(r);
        r = _req(true, 1 ether, type(uint128).max);
        vm.expectRevert(V3MultiHopRouter.SlippageExceeded.selector);
        hop.swapExactIn{value: 1 ether}(r);
        r = _req(true, 1 ether, 1);
        vm.expectRevert(V3MultiHopRouter.NativeValueMismatch.selector);
        hop.swapExactIn{value: 2 ether}(r);
    }
}
