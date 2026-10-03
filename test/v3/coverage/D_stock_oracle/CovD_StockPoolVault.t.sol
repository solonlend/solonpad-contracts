// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookToken} from "../../helpers/HookHarness.sol";
import {RestockHub} from "../../StockPool.t.sol";
import {StockPoolVault} from "../../../../src/v3/stock/StockPoolVault.sol";

/// @notice Branch coverage for StockPoolVault (pool A): keeper/owner exits gate, treasury refusal,
///         pushPrice guards, unlockCallback caller check, zero-liquidity re-range, push input clamp.
contract CovDPoolVaultTest is Test {
    using StateLibrary for IPoolManager;

    uint256 constant SIGNER = 0x9A1C;
    PoolManager manager;
    StockPoolVault pool;
    RestockHub restock;
    HookToken stock;
    address keeper = address(0xB07);
    address treasury = address(0x7EA5);
    address governor = address(0x60F);
    address underlying = address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);
    address rhTreasury = address(0x7EA6);
    uint256 nonce;

    function setUp() public {
        manager = new PoolManager(address(this));
        stock = new HookToken();
        restock = new RestockHub();
        pool = new StockPoolVault(
            StockPoolVault.Config(
                IPoolManager(address(manager)),
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
        pool.initialize(uint160(1 << 96)); // tick 0
        _range(-400, 400, 0, 100);
    }

    function _quote(int24 refTick, uint24 maxDev) internal returns (StockPoolVault.PriceQuote memory q, bytes memory sig) {
        q = StockPoolVault.PriceQuote(refTick, maxDev, block.timestamp + 60, ++nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER, pool.quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    function _range(int24 lower, int24 upper, int24 refTick, uint24 maxDev) internal {
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(refTick, maxDev);
        vm.prank(keeper);
        pool.rebalanceRange(lower, upper, q, sig);
    }

    // ---------------------------------------------------------------- L150 onlyKeeperOrOwner

    function test_exitsGate_strangerRejected_keeperAndOwnerAccepted() public {
        vm.deal(address(pool), address(pool).balance + 10 ether);
        vm.startPrank(address(0xBAD));
        vm.expectRevert(StockPoolVault.NotKeeper.selector);
        pool.cancelRestock(1);
        vm.expectRevert(StockPoolVault.NotKeeper.selector);
        pool.escalateRestock(1);
        vm.expectRevert(StockPoolVault.NotKeeper.selector);
        pool.escalateRestockFunds(1);
        vm.stopPrank();
        // owner (second operand of the &&) passes for each exit
        vm.startPrank(governor);
        pool.cancelRestock(11);
        pool.escalateRestock(12);
        vm.stopPrank();
        // keeper (first operand) passes
        vm.prank(keeper);
        pool.escalateRestockFunds(13);
        (address caller, uint8 kind, uint256 id, address to, uint256 value) = restock.exits(0);
        assertEq(caller, address(pool));
        assertEq(kind, 0);
        assertEq(id, 11);
        (, kind, id, to, value) = restock.exits(1);
        assertEq(kind, 1);
        assertEq(id, 12);
        assertEq(to, rhTreasury);
        assertEq(value, 1 ether);
        (, kind, id, to, value) = restock.exits(2);
        assertEq(kind, 2);
        assertEq(id, 13);
        assertEq(to, rhTreasury);
        assertEq(value, 1 ether);
    }

    // ---------------------------------------------------------------- L195 treasury refuses native

    function test_withdraw_treasuryRefusesNative_revertsTransferFailed() public {
        vm.etch(treasury, hex"60006000fd"); // PUSH1 0 PUSH1 0 REVERT
        vm.deal(address(pool), address(pool).balance + 1 ether); // idle native the vault really holds
        stock.mint(address(pool), 1 ether); // idle stock (the position holds the rest)
        uint256 balBefore = address(pool).balance;
        uint256 stockBefore = stock.balanceOf(address(pool));
        vm.prank(governor);
        vm.expectRevert(StockPoolVault.TransferFailed.selector);
        pool.withdraw(1 ether, 1);
        assertEq(address(pool).balance, balBefore);
        assertEq(stock.balanceOf(address(pool)), stockBefore);
        // the stock-only arm (nativeAmount == 0) still works: ERC20 transfer needs no receive hook
        vm.prank(governor);
        pool.withdraw(0, 1 ether);
        assertEq(stock.balanceOf(treasury), 1 ether);
        assertEq(address(pool).balance, balBefore);
    }

    // ---------------------------------------------------------------- L228 pushPrice guards

    function test_pushPrice_atReference_orZeroMaxIn_revertsBadRange() public {
        assertEq(pool.currentTick(), 0);
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(0, 100);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.BadRange.selector);
        pool.pushPrice(q, sig, 1 ether); // fromTick == refTick
        assertFalse(pool.nonceUsed(q.nonce), "nonce burn rolled back");
        (q, sig) = _quote(100, 100);
        vm.prank(keeper);
        vm.expectRevert(StockPoolVault.BadRange.selector);
        pool.pushPrice(q, sig, 0); // maxIn == 0
        assertFalse(pool.nonceUsed(q.nonce));
        assertEq(pool.currentTick(), 0);
    }

    // ---------------------------------------------------------------- L287 unlockCallback

    function test_unlockCallback_notManager_reverts() public {
        vm.expectRevert(StockPoolVault.OnlyManager.selector);
        pool.unlockCallback(abi.encode(uint8(2), int24(0), int24(0), uint256(0), int24(0)));
        assertGt(pool.liquidity(), 0, "position untouched");
    }

    // ---------------------------------------------------------------- L322 zero liquidity re-add

    function test_rebalanceRange_withNoIdleFunds_setsRangeWithZeroLiquidity() public {
        vm.prank(governor);
        pool.exit();
        assertEq(pool.liquidity(), 0);
        uint256 nat = address(pool).balance;
        uint256 stk = stock.balanceOf(address(pool));
        vm.prank(governor);
        pool.withdraw(nat, stk);
        assertEq(address(pool).balance, 0);
        assertEq(stock.balanceOf(address(pool)), 0);
        assertEq(treasury.balance, nat);
        _range(-200, 200, 0, 100);
        assertEq(pool.liquidity(), 0, "nothing to add");
        assertEq(pool.tickLower(), -200, "range recorded");
        assertEq(pool.tickUpper(), 200);
        // a later exit with zero liquidity is a no-op (_removeAll early return)
        vm.prank(governor);
        pool.exit();
        assertEq(address(pool).balance, 0);
    }

    // ---------------------------------------------------------------- L336 push clamp (both directions)

    function test_pushPrice_maxInAboveIdleStock_clampsToBalance() public {
        stock.mint(address(pool), 100 ether);
        uint256 idle = stock.balanceOf(address(pool));
        assertGe(idle, 100 ether);
        uint256 nativeBefore = address(pool).balance;
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(100, 100); // tick 0 < ref: sell STOCK in
        vm.prank(keeper);
        pool.pushPrice(q, sig, type(uint128).max); // far more than held
        int24 t = pool.currentTick();
        assertGt(t, 0, "price moved toward the reference");
        assertLe(t, 100, "never past it");
        assertLt(stock.balanceOf(address(pool)), idle, "spent idle stock, at most what it had");
        assertGt(address(pool).balance, nativeBefore, "received native out");
    }

    function test_pushPrice_maxInAboveIdleNative_clampsToBalance() public {
        vm.deal(address(pool), address(pool).balance + 100 ether);
        uint256 idle = address(pool).balance;
        uint256 stockBefore = stock.balanceOf(address(pool));
        (StockPoolVault.PriceQuote memory q, bytes memory sig) = _quote(-100, 100); // tick 0 > ref: sell native in
        vm.prank(keeper);
        pool.pushPrice(q, sig, type(uint128).max);
        int24 t = pool.currentTick();
        assertLt(t, 0);
        assertGe(t, -100);
        assertLt(address(pool).balance, idle);
        assertGt(stock.balanceOf(address(pool)), stockBefore);
    }
}
