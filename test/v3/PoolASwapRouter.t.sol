// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HookToken} from "./helpers/HookHarness.sol";
import {StockPoolVault} from "../../src/v3/stock/StockPoolVault.sol";
import {PoolASwapRouter, IPoolAVault} from "../../src/v3/stock/PoolASwapRouter.sol";

/// @notice A recipient that tries to re-enter the router when it is paid (native on sells).
contract ReenteringRecipient {
    PoolASwapRouter public r;
    address public stock;
    bool public tried;
    bool public reentered;
    bytes public err;

    constructor(PoolASwapRouter r_, address stock_) {
        r = r_;
        stock = stock_;
    }

    receive() external payable {
        tried = true;
        try r.buy{value: msg.value}(stock, 0, address(this), block.timestamp) {
            reentered = true;
        } catch (bytes memory e) {
            err = e;
        }
    }
}

/// @notice A recipient that refuses native USDC.
contract NoNative {}

contract PoolASwapRouterTest is Test {
    using StateLibrary for IPoolManager;

    uint256 constant SIGNER = 0x9A1C;
    // pool A as on testnet #5: NVDA.sol ≈ $180 (tick ≈ −51900, STOCK.sol per native USDC)
    int24 constant REF = -51_800;

    PoolManager manager;
    HookToken nvda; // STOCK.sol with pool A
    HookToken aapl; // STOCK.sol with pool A at 1:1 (simple numbers)
    HookToken tsla; // STOCK.sol without pool A
    StockPoolVault vaultN;
    StockPoolVault vaultA;
    PoolASwapRouter router;
    address keeper = address(0xB07);
    address owner = address(0x60F);
    address user = address(0xA11CE);
    address recipient = address(0xCAFE);
    uint256 nonce;

    function setUp() public {
        manager = new PoolManager(address(this));
        nvda = new HookToken();
        aapl = new HookToken();
        tsla = new HookToken();
        vaultN = _vault(address(nvda));
        vaultA = _vault(address(aapl));
        // NVDA pool: 1,000 USDC + 10 NVDA.sol inventory, range ±~3% around REF
        vm.deal(address(vaultN), 1_000 ether);
        nvda.mint(address(vaultN), 10 ether);
        vm.prank(owner);
        vaultN.initialize(TickMath.getSqrtPriceAtTick(REF));
        _range(vaultN, REF - 400, REF + 400, REF);
        // AAPL pool: 1:1, ±~4%
        vm.deal(address(vaultA), 100 ether);
        aapl.mint(address(vaultA), 100 ether);
        vm.prank(owner);
        vaultA.initialize(uint160(1 << 96));
        _range(vaultA, -400, 400, 0);

        IPoolAVault[] memory vs = new IPoolAVault[](2);
        vs[0] = IPoolAVault(address(vaultN));
        vs[1] = IPoolAVault(address(vaultA));
        router = new PoolASwapRouter(manager, vs);

        vm.deal(user, 10_000 ether);
        nvda.mint(user, 100 ether);
        aapl.mint(user, 100 ether);
        vm.startPrank(user);
        nvda.approve(address(router), type(uint256).max);
        aapl.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _vault(address token) internal returns (StockPoolVault) {
        return new StockPoolVault(
            StockPoolVault.Config(
                manager, token, address(0xD060), address(0x4B), address(0x7EA5), keeper, vm.addr(SIGNER), owner, address(0x7EA6)
            )
        );
    }

    function _range(StockPoolVault v, int24 lower, int24 upper, int24 ref) internal {
        StockPoolVault.PriceQuote memory q = StockPoolVault.PriceQuote(ref, 100, block.timestamp + 60, ++nonce);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(SIGNER, v.quoteDigest(q));
        vm.prank(keeper);
        v.rebalanceRange(lower, upper, q, abi.encodePacked(r, s, vv));
    }

    /// @dev Not a multiple of 1e12 (AGENTS.md §4.6): x * 1e12 + a sub-1e12 tail in [1, 1e12 - 1].
    function _unaligned(uint256 x, uint256 tail, uint256 maxWhole) internal pure returns (uint256) {
        return bound(x, 1, maxWhole) * 1e12 + bound(tail, 1, 1e12 - 1);
    }

    struct Snap {
        uint256 vaultNNative;
        uint256 vaultNStock;
        uint256 vaultANative;
        uint256 vaultAStock;
        uint256 mgrNative;
        uint256 mgrNvda;
        uint256 mgrAapl;
        uint256 mgrTsla;
    }

    function _snap() internal view returns (Snap memory s) {
        s = Snap(
            address(vaultN).balance,
            nvda.balanceOf(address(vaultN)),
            address(vaultA).balance,
            aapl.balanceOf(address(vaultA)),
            address(manager).balance,
            nvda.balanceOf(address(manager)),
            aapl.balanceOf(address(manager)),
            tsla.balanceOf(address(manager))
        );
    }

    function _routerHoldsNothing() internal view {
        assertEq(address(router).balance, 0, "router native");
        assertEq(nvda.balanceOf(address(router)), 0, "router NVDA.sol");
        assertEq(aapl.balanceOf(address(router)), 0, "router AAPL.sol");
    }

    // ------------------------------------------------------------------ construction

    function testListsOnlyTheGivenVaultPools() public view {
        address[] memory s = router.stocks();
        assertEq(s.length, 2);
        assertEq(s[0], address(nvda));
        assertEq(s[1], address(aapl));
        PoolKey memory k = router.poolKey(address(nvda));
        PoolKey memory v = vaultN.poolKey();
        assertEq(keccak256(abi.encode(k)), keccak256(abi.encode(v)), "pool key from the vault");
        assertEq(Currency.unwrap(k.currency0), address(0), "native USDC");
        assertEq(address(k.hooks), address(0));
        assertEq(k.fee, 10_000);
    }

    function testConstructorRejectsBadVaults() public {
        IPoolAVault[] memory none = new IPoolAVault[](0);
        vm.expectRevert(PoolASwapRouter.InvalidDependency.selector);
        new PoolASwapRouter(manager, none);

        IPoolAVault[] memory dup = new IPoolAVault[](2);
        dup[0] = IPoolAVault(address(vaultN));
        dup[1] = IPoolAVault(address(vaultN));
        vm.expectRevert(PoolASwapRouter.InvalidDependency.selector);
        new PoolASwapRouter(manager, dup);

        // a vault on another PoolManager
        PoolManager other = new PoolManager(address(this));
        IPoolAVault[] memory one = new IPoolAVault[](1);
        one[0] = IPoolAVault(address(vaultN));
        vm.expectRevert(PoolASwapRouter.InvalidDependency.selector);
        new PoolASwapRouter(other, one);

        vm.expectRevert(PoolASwapRouter.InvalidDependency.selector);
        new PoolASwapRouter(IPoolManager(address(0xBEEF)), one);
    }

    function testUnknownStockOrArbitraryPoolIsRejected() public {
        vm.startPrank(user);
        vm.expectRevert(PoolASwapRouter.UnknownStock.selector);
        router.buy{value: 1 ether}(address(tsla), 0, user, block.timestamp);
        vm.expectRevert(PoolASwapRouter.UnknownStock.selector);
        router.sell(address(tsla), 1 ether, 0, user, block.timestamp);
        vm.expectRevert(PoolASwapRouter.UnknownStock.selector);
        router.quote(address(0), true, 1 ether);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ buy / sell

    function testBuyPaysTheQuotedStockToTheRecipient() public {
        uint256 amountIn = 10 ether + 123_456_789; // 10.000000000123456789 USDC
        (uint256 q, uint160 sqrtAfter) = router.quote(address(nvda), true, amountIn);
        assertGt(q, 0);
        Snap memory s = _snap();
        uint256 userBefore = user.balance;
        vm.expectEmit(address(router));
        emit PoolASwapRouter.Swap(address(nvda), user, recipient, true, amountIn, q);
        vm.prank(user);
        uint256 out = router.buy{value: amountIn}(address(nvda), q, recipient, block.timestamp);
        assertEq(out, q, "quote == fill");
        assertEq(nvda.balanceOf(recipient), q);
        assertEq(user.balance, userBefore - amountIn, "exactly msg.value, tail included");
        assertEq(address(manager).balance, s.mgrNative + amountIn, "all USDC into the pool");
        assertEq(nvda.balanceOf(address(manager)), s.mgrNvda - q);
        (uint160 sqrtNow,,) = router.poolState(address(nvda));
        assertEq(sqrtNow, sqrtAfter, "quote reports the post-trade price");
        // price impact sanity: ~$10 at ~$180 -> ~0.055 NVDA.sol minus the 1% LP fee
        uint256 spot = 10 ether * 1e18 / _usdcPerStock(REF);
        assertApproxEqRel(out, spot * 99 / 100, 0.01e18);
        _routerHoldsNothing();
    }

    function testSellPaysTheQuotedNativeUsdcToTheRecipient() public {
        uint256 amountIn = 0.02 ether + 7; // unaligned NVDA.sol amount
        (uint256 q,) = router.quote(address(nvda), false, amountIn);
        uint256 nativeBefore = recipient.balance;
        vm.prank(user);
        uint256 out = router.sell(address(nvda), amountIn, q, recipient, block.timestamp);
        assertEq(out, q, "quote == fill");
        assertEq(recipient.balance - nativeBefore, q, "native 18 dp, sub-1e12 tail paid out");
        assertEq(nvda.balanceOf(user), 100 ether - amountIn);
        _routerHoldsNothing();
    }

    function testFuzzBuyUnalignedQuoteMatchesFill(uint256 whole, uint256 tail) public {
        uint256 amountIn = _unaligned(whole, tail, 5_000_000); // ≤ ~5 USDC + tail
        assertTrue(amountIn % 1e12 != 0);
        (uint256 q,) = router.quote(address(nvda), true, amountIn);
        Snap memory s = _snap();
        uint256 before = user.balance;
        vm.prank(user);
        uint256 out = router.buy{value: amountIn}(address(nvda), q, recipient, block.timestamp);
        assertEq(out, q);
        assertEq(before - user.balance, amountIn, "18 dp debit, no rounding to 6 dp");
        assertEq(address(manager).balance - s.mgrNative, amountIn, "no sub-1e12 dust left behind");
        assertEq(nvda.balanceOf(recipient), out);
        assertEq(s.vaultNNative, address(vaultN).balance, "vault idle funds untouched");
        assertEq(s.vaultNStock, nvda.balanceOf(address(vaultN)));
        assertEq(s.mgrAapl, aapl.balanceOf(address(manager)), "other pool untouched");
        _routerHoldsNothing();
    }

    function testFuzzSellUnalignedQuoteMatchesFill(uint256 whole, uint256 tail) public {
        uint256 amountIn = _unaligned(whole, tail, 20_000); // ≤ ~0.02 NVDA.sol + tail
        (uint256 q,) = router.quote(address(nvda), false, amountIn);
        Snap memory s = _snap();
        uint256 before = recipient.balance;
        vm.prank(user);
        uint256 out = router.sell(address(nvda), amountIn, q, recipient, block.timestamp);
        assertEq(out, q);
        assertEq(recipient.balance - before, out, "native out exact to the wei");
        assertEq(s.mgrNative - address(manager).balance, out);
        assertEq(nvda.balanceOf(address(manager)) - s.mgrNvda, amountIn);
        assertEq(s.vaultNNative, address(vaultN).balance);
        assertEq(s.vaultNStock, nvda.balanceOf(address(vaultN)));
        assertEq(s.mgrAapl, aapl.balanceOf(address(manager)));
        _routerHoldsNothing();
    }

    function testFuzzRoundTripOnTheOneToOnePool(uint256 whole, uint256 tail) public {
        uint256 amountIn = _unaligned(whole, tail, 2_000_000); // ≤ ~2 USDC
        vm.startPrank(user);
        uint256 got = router.buy{value: amountIn}(address(aapl), 1, user, block.timestamp);
        uint256 back = router.sell(address(aapl), got, 1, user, block.timestamp);
        vm.stopPrank();
        assertLt(back, amountIn, "two 1% LP fees");
        assertGt(back, amountIn * 97 / 100);
        _routerHoldsNothing();
    }

    // ------------------------------------------------------------------ guards

    function testSlippageReverts() public {
        (uint256 q,) = router.quote(address(nvda), true, 1 ether);
        vm.prank(user);
        vm.expectRevert(PoolASwapRouter.SlippageExceeded.selector);
        router.buy{value: 1 ether}(address(nvda), q + 1, user, block.timestamp);
        (uint256 qs,) = router.quote(address(nvda), false, 0.001 ether);
        vm.prank(user);
        vm.expectRevert(PoolASwapRouter.SlippageExceeded.selector);
        router.sell(address(nvda), 0.001 ether, qs + 1, user, block.timestamp);
    }

    function testFrontRunMovesThePriceAndTheVictimRevertsInsteadOfLosing() public {
        (uint256 q,) = router.quote(address(nvda), true, 50 ether);
        uint256 minOut = q * 995 / 1000; // 0.5% tolerance
        vm.deal(address(0xBAD), 1_000 ether);
        vm.prank(address(0xBAD));
        router.buy{value: 300 ether}(address(nvda), 0, address(0xBAD), block.timestamp);
        vm.prank(user);
        vm.expectRevert(PoolASwapRouter.SlippageExceeded.selector);
        router.buy{value: 50 ether}(address(nvda), minOut, user, block.timestamp);
    }

    function testExpiredDeadlineReverts() public {
        vm.warp(1_000);
        vm.startPrank(user);
        vm.expectRevert(PoolASwapRouter.DeadlineExpired.selector);
        router.buy{value: 1 ether}(address(nvda), 0, user, 999);
        vm.expectRevert(PoolASwapRouter.DeadlineExpired.selector);
        router.sell(address(nvda), 1e15, 0, user, 999);
        router.buy{value: 1 ether}(address(nvda), 0, user, 1_000); // deadline == now is fine
        vm.stopPrank();
    }

    function testBadRequestsRevert() public {
        vm.startPrank(user);
        vm.expectRevert(PoolASwapRouter.InvalidRequest.selector);
        router.buy{value: 0}(address(nvda), 0, user, block.timestamp);
        vm.expectRevert(PoolASwapRouter.InvalidRequest.selector);
        router.buy{value: 1 ether}(address(nvda), 0, address(0), block.timestamp);
        vm.expectRevert(PoolASwapRouter.InvalidRequest.selector);
        router.sell(address(nvda), 0, 0, user, block.timestamp);
        vm.expectRevert(PoolASwapRouter.InvalidRequest.selector);
        router.quote(address(nvda), true, 0);
        vm.stopPrank();
    }

    function testSellRejectsNativeValue() public {
        // `sell` is not payable: native sent with it cannot get stuck in the router
        (bool ok,) = address(router).call{value: 1 ether}(
            abi.encodeCall(PoolASwapRouter.sell, (address(nvda), 1e15, 0, user, block.timestamp))
        );
        assertFalse(ok);
        _routerHoldsNothing();
    }

    function testDirectNativeTransferToRouterReverts() public {
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok, "no receive: the router never holds USDC");
    }

    function testDepthBeyondPoolAIsAPartialFillAndReverts() public {
        // 10 NVDA.sol inventory ≈ $1.8k, the range holds far less: $5k cannot fill in pool A
        vm.expectRevert(PoolASwapRouter.PartialFill.selector);
        router.quote(address(nvda), true, 5_000 ether);
        Snap memory s = _snap();
        vm.prank(user);
        vm.expectRevert(PoolASwapRouter.PartialFill.selector);
        router.buy{value: 5_000 ether}(address(nvda), 0, user, block.timestamp);
        Snap memory t = _snap();
        assertEq(keccak256(abi.encode(s)), keccak256(abi.encode(t)), "nothing moved");
        vm.expectRevert(PoolASwapRouter.PartialFill.selector);
        router.quote(address(nvda), false, 50 ether);
    }

    function testDustThatBuysNothingSaysZeroOutputNotDepth() public {
        vm.expectRevert(PoolASwapRouter.ZeroOutput.selector);
        router.quote(address(nvda), true, 1); // 1 wei of USDC at ~$180 a share
        vm.prank(user);
        vm.expectRevert(PoolASwapRouter.ZeroOutput.selector);
        router.buy{value: 1}(address(nvda), 0, user, block.timestamp);
    }

    function testQuoteChangesNothing() public {
        Snap memory s = _snap();
        (uint160 p0,,) = router.poolState(address(nvda));
        router.quote(address(nvda), true, 100 ether);
        router.quote(address(nvda), false, 0.1 ether);
        (uint160 p1,,) = router.poolState(address(nvda));
        assertEq(p0, p1);
        assertEq(keccak256(abi.encode(s)), keccak256(abi.encode(_snap())));
    }

    function testQuoteNeedsNoFundsOrAllowance() public {
        address nobody = address(0x0B0D7);
        vm.prank(nobody);
        (uint256 qb,) = router.quote(address(nvda), true, 25 ether);
        vm.prank(nobody);
        (uint256 qs,) = router.quote(address(nvda), false, 0.1 ether);
        assertGt(qb, 0);
        assertGt(qs, 0);
    }

    function testOnlyTheCallerPays() public {
        // the user approved the router; someone else cannot spend that allowance
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(); // ERC20InsufficientAllowance / balance of the attacker, never the user
        router.sell(address(nvda), 1 ether, 0, attacker, block.timestamp);
        assertEq(nvda.balanceOf(user), 100 ether);
    }

    function testUnlockCallbackOnlyFromTheManagerDuringASwap() public {
        PoolKey memory k = router.poolKey(address(nvda));
        bytes memory data = abi.encode(false, k, true, 1 ether, 0, user);
        vm.expectRevert(PoolASwapRouter.UnauthorizedCallback.selector);
        router.unlockCallback(data);
        // even from the manager's address, a non-quote callback outside our own swap has no payer
        vm.prank(address(manager));
        vm.expectRevert(); // CurrencyNotSettled-free: fails before touching funds (ManagerLocked on swap)
        router.unlockCallback(data);
    }

    function testReentryFromTheRecipientIsBlocked() public {
        ReenteringRecipient bad = new ReenteringRecipient(router, address(nvda));
        vm.prank(user);
        uint256 out = router.sell(address(nvda), 0.001 ether, 0, address(bad), block.timestamp);
        assertTrue(bad.tried(), "recipient got control");
        assertFalse(bad.reentered(), "re-entry did not trade");
        assertEq(bytes4(bad.err()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(bad).balance, out, "the payout stayed with the recipient");
        _routerHoldsNothing();
    }

    function testRecipientRefusingNativeRevertsTheWholeSell() public {
        NoNative nn = new NoNative();
        Snap memory s = _snap();
        vm.prank(user);
        vm.expectRevert();
        router.sell(address(nvda), 0.001 ether, 0, address(nn), block.timestamp);
        assertEq(keccak256(abi.encode(s)), keccak256(abi.encode(_snap())));
    }

    function testLpFeeGoesToThePoolNotTheRouter() public {
        vm.prank(user);
        router.buy{value: 10 ether}(address(aapl), 0, user, block.timestamp);
        _range(vaultA, -400, 400, _tickA());
        assertApproxEqAbs(vaultA.lpFees0(), 0.1 ether, 1e6, "1% of 10 USDC to the vault");
        _routerHoldsNothing();
    }

    function _tickA() internal view returns (int24 t) {
        (, t,) = router.poolState(address(aapl));
    }

    /// @dev USDC (18 dp) per 1e18 STOCK.sol at `tick` (tick = STOCK.sol per USDC).
    function _usdcPerStock(int24 tick) internal pure returns (uint256) {
        uint256 p = TickMath.getSqrtPriceAtTick(-tick);
        return p * p / (1 << 96) * 1e18 / (1 << 96);
    }
}
