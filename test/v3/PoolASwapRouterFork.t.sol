// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolASwapRouter, IPoolAVault} from "../../src/v3/stock/PoolASwapRouter.sol";

/// @notice PoolASwapRouter against the LIVE pool A of testnet deployment #5 (Arc testnet 5042002,
///         docs/TESTNET-v3-deployment.md §9.1): StockPoolVault 0x2A35…f26F on the testnet PoolManager 0x0d0f…d5b.
///         Buys and sells real pool-A liquidity with amounts that are not multiples of 1e12 (AGENTS.md §4.6) and
///         asserts quote == fill and exact 18-dp balance deltas. Needs ARC_TESTNET_FORK_RPC (skipped without it
///         unless REQUIRE_POOLA_FORK=true).
contract PoolASwapRouterForkTest is Test {
    address constant VAULT = 0x2A35b9774300380C28F6B0cf5CB05510Ef28f26F;
    address constant MANAGER = 0x0d0f6A9e8c7b715854fA87e7E0b3c993E543ad5b;
    address constant NVDA_SOL = 0xDfd3BB1C697089D24f7F0126ef550a45593CE573;
    address constant AAPL_SOL = 0xe7Eac59935D1e7c6Bc513287bCFb5EdB5204cbE8;

    PoolASwapRouter router;
    address user = makeAddr("poolA-fork-user"); // fresh EOA (no code on the fork)

    function setUp() public {
        string memory rpc = vm.envOr("ARC_TESTNET_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            if (vm.envOr("REQUIRE_POOLA_FORK", false)) revert("ARC_TESTNET_FORK_RPC required");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 5042002, "Arc testnet");
        assertEq(address(IPoolAVault(VAULT).manager()), MANAGER, "deployment #5 pool A");
        IPoolAVault[] memory vs = new IPoolAVault[](1);
        vs[0] = IPoolAVault(VAULT);
        router = new PoolASwapRouter(IPoolManager(MANAGER), vs);
        assertEq(user.code.length, 0);
        vm.deal(user, 5 ether);
    }

    function testForkBuyThenSellOnLivePoolA() public {
        uint256 amountIn = 0.5 ether + 123_456; // 0.500000000000123456 USDC
        (uint160 p0,, uint128 liq) = router.poolState(NVDA_SOL);
        assertGt(liq, 0, "pool A has in-range liquidity");
        (uint256 q, uint160 pAfter) = router.quote(NVDA_SOL, true, amountIn);
        uint256 nBefore = IERC20(NVDA_SOL).balanceOf(user);
        uint256 uBefore = user.balance;
        uint256 mBefore = MANAGER.balance;
        vm.prank(user);
        uint256 out = router.buy{value: amountIn}(NVDA_SOL, q, user, block.timestamp + 60);
        assertEq(out, q, "buy: quote == fill");
        assertEq(IERC20(NVDA_SOL).balanceOf(user) - nBefore, out);
        assertEq(uBefore - user.balance, amountIn, "18-dp debit with the sub-1e12 tail");
        assertEq(MANAGER.balance - mBefore, amountIn);
        (uint160 p1,,) = router.poolState(NVDA_SOL);
        assertEq(p1, pAfter);
        assertLt(p1, p0, "buying NVDA.sol lowers STOCK.sol per USDC");
        emit log_named_uint("buy in (wei)", amountIn);
        emit log_named_uint("buy out NVDA.sol (wei)", out);

        uint256 sellIn = out / 2 + 1;
        (uint256 qs,) = router.quote(NVDA_SOL, false, sellIn);
        vm.startPrank(user);
        IERC20(NVDA_SOL).approve(address(router), sellIn);
        uint256 nat = user.balance;
        uint256 back = router.sell(NVDA_SOL, sellIn, qs, user, block.timestamp + 60);
        vm.stopPrank();
        assertEq(back, qs, "sell: quote == fill");
        assertEq(user.balance - nat, back, "native out exact to the wei");
        assertEq(address(router).balance, 0);
        assertEq(IERC20(NVDA_SOL).balanceOf(address(router)), 0);
        emit log_named_uint("sell in NVDA.sol (wei)", sellIn);
        emit log_named_uint("sell out USDC (wei)", back);
    }

    function testForkNoPoolForAaplAndTooLargeIsPartial() public {
        vm.expectRevert(PoolASwapRouter.UnknownStock.selector);
        router.quote(AAPL_SOL, true, 1 ether);
        // more USDC than the whole PoolManager holds of NVDA.sol's worth can never fill in pool A (depth-independent)
        uint256 huge = MANAGER.balance * 1_000 + 1_000_000 ether;
        vm.expectRevert(PoolASwapRouter.PartialFill.selector);
        router.quote(NVDA_SOL, true, huge);
    }
}
