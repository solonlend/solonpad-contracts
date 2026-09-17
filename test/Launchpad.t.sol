// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchpadFactory} from "../src/LaunchpadFactory.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {CurvePool} from "../src/CurvePool.sol";

contract ReentrantSeller {
    CurvePool public pool;
    LaunchToken public token;
    bool public attacked;

    function setUp(CurvePool pool_, LaunchToken token_) external {
        pool = pool_;
        token = token_;
    }

    function buyIn() external payable {
        pool.buy{value: msg.value}(0, block.timestamp);
    }

    function sellAll() external {
        uint256 bal = token.balanceOf(address(this));
        token.approve(address(pool), bal);
        pool.sell(bal / 2, 0, block.timestamp);
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            // try to re-enter sell() while the first sell is mid-flight
            pool.sell(1e18, 0, block.timestamp);
        }
    }
}

contract LaunchpadTest is Test {
    LaunchpadFactory factory;
    LaunchToken token;
    CurvePool pool;

    address deployer = makeAddr("deployer");
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant LAUNCH_FEE = 1e18;
    uint256 constant VIRTUAL = 6_000e18;
    uint256 constant GRADUATION = 20_000e18;
    uint256 constant SUPPLY = 1_000_000_000e18;

    function setUp() public {
        vm.prank(deployer);
        factory = new LaunchpadFactory(treasury);

        vm.deal(creator, 100e18);
        vm.prank(creator);
        (address t, address p) = factory.createToken{value: LAUNCH_FEE}("Pons Cat", "PCAT", "ipfs://meta");
        token = LaunchToken(t);
        pool = CurvePool(p);

        vm.deal(alice, 1_000_000e18);
        vm.deal(bob, 1_000_000e18);
    }

    // ---- launch ----

    function test_launch_initialState() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(pool)), SUPPLY);
        assertEq(pool.tokenReserve(), SUPPLY);
        assertEq(pool.realUsdc(), 0);
        assertEq(pool.creator(), creator);
        assertEq(factory.poolOf(address(token)), address(pool));
        assertEq(factory.tokenCount(), 1);
        assertEq(factory.pendingLaunchFees(), LAUNCH_FEE);
        assertEq(token.metadataURI(), "ipfs://meta");
    }

    function test_launch_wrongFeeReverts() public {
        vm.prank(creator);
        vm.expectRevert("wrong launch fee");
        factory.createToken{value: LAUNCH_FEE - 1}("X", "X", "");
    }

    function test_launch_feeCollection() public {
        vm.prank(treasury);
        factory.collectLaunchFees();
        assertEq(treasury.balance, LAUNCH_FEE);
        assertEq(factory.pendingLaunchFees(), 0);

        vm.prank(alice);
        vm.expectRevert("only treasury");
        factory.collectLaunchFees();
    }

    // ---- buy ----

    function test_buy_curveMath() public {
        uint256 usdcIn = 1_000e18;
        uint256 fee = (usdcIn * 100) / 10_000; // 1%
        uint256 net = usdcIn - fee;
        uint256 expectedOut = (SUPPLY * net) / (VIRTUAL + net);

        vm.prank(alice);
        uint256 out = pool.buy{value: usdcIn}(expectedOut, block.timestamp);

        assertEq(out, expectedOut);
        assertEq(token.balanceOf(alice), expectedOut);
        assertEq(pool.realUsdc(), net);
        assertEq(pool.tokenReserve(), SUPPLY - expectedOut);
        // fee split 50/50
        assertEq(pool.creatorFees(), fee / 2);
        assertEq(pool.protocolFees(), fee - fee / 2);
        // solvency: pool native balance covers reserve + all unclaimed fees
        assertEq(address(pool).balance, pool.realUsdc() + pool.creatorFees() + pool.protocolFees());
    }

    function test_buy_slippageReverts() public {
        vm.prank(alice);
        vm.expectRevert("slippage");
        pool.buy{value: 1_000e18}(type(uint256).max, block.timestamp);
    }

    function test_buy_deadlineReverts() public {
        vm.prank(alice);
        vm.expectRevert("expired");
        pool.buy{value: 1_000e18}(0, block.timestamp - 1);
    }

    // ---- sell ----

    function test_sell_roundTripNeverProfitable() public {
        uint256 usdcIn = 5_000e18;
        vm.startPrank(alice);
        uint256 out = pool.buy{value: usdcIn}(0, block.timestamp);
        token.approve(address(pool), out);
        uint256 back = pool.sell(out, 0, block.timestamp);
        vm.stopPrank();

        // round trip must cost the trader both fees; pool keeps a surplus
        assertLt(back, usdcIn);
        assertEq(token.balanceOf(alice), 0);
        assertEq(pool.tokenReserve(), SUPPLY);
        assertEq(address(pool).balance, pool.realUsdc() + pool.creatorFees() + pool.protocolFees());
    }

    function test_sell_slippageReverts() public {
        vm.startPrank(alice);
        uint256 out = pool.buy{value: 1_000e18}(0, block.timestamp);
        token.approve(address(pool), out);
        vm.expectRevert("slippage");
        pool.sell(out, type(uint256).max, block.timestamp);
        vm.stopPrank();
    }

    function test_sell_withoutApproveReverts() public {
        vm.startPrank(alice);
        uint256 out = pool.buy{value: 1_000e18}(0, block.timestamp);
        vm.expectRevert("insufficient allowance");
        pool.sell(out, 0, block.timestamp);
        vm.stopPrank();
    }

    // ---- graduation ----

    function test_graduation() public {
        assertFalse(pool.graduated());

        // push real reserve past the threshold (gross needed = threshold / 0.99)
        uint256 gross = (GRADUATION * 10_000) / 9_900 + 1e18;
        vm.prank(alice);
        pool.buy{value: gross}(0, block.timestamp);

        assertTrue(pool.graduated());
        assertGe(pool.realUsdc(), GRADUATION);

        // trading continues after graduation
        vm.prank(bob);
        uint256 out = pool.buy{value: 100e18}(0, block.timestamp);
        assertGt(out, 0);
    }

    // ---- fee claims ----

    function test_feeClaims() public {
        vm.prank(alice);
        pool.buy{value: 10_000e18}(0, block.timestamp);

        uint256 cFees = pool.creatorFees();
        uint256 pFees = pool.protocolFees();
        assertGt(cFees, 0);
        assertGt(pFees, 0);

        vm.prank(creator);
        pool.claimCreatorFees();
        assertEq(creator.balance, 100e18 - LAUNCH_FEE + cFees);
        assertEq(pool.creatorFees(), 0);

        vm.prank(treasury);
        pool.claimProtocolFees();
        assertEq(treasury.balance, pFees);

        vm.prank(alice);
        vm.expectRevert("only creator");
        pool.claimCreatorFees();
        vm.prank(alice);
        vm.expectRevert("only treasury");
        pool.claimProtocolFees();
    }

    // ---- reentrancy ----

    function test_sell_reentrancyBlocked() public {
        ReentrantSeller attacker = new ReentrantSeller();
        attacker.setUp(pool, token);
        vm.deal(address(this), 10_000e18);
        attacker.buyIn{value: 1_000e18}();

        // outer sell sends native → receive() re-enters sell() → guard reverts
        // the whole outer call ("usdc send failed" bubbles from the failed send)
        vm.expectRevert("usdc send failed");
        attacker.sellAll();
    }

    // ---- admin ----

    function test_setParams_onlyFutureLaunches() public {
        vm.prank(deployer);
        factory.setParams(2e18, 12_000e18, 40_000e18, 200, 3_000);

        // existing pool untouched
        assertEq(pool.virtualUsdc(), VIRTUAL);
        assertEq(pool.feeBps(), 100);

        vm.deal(creator, 10e18);
        vm.prank(creator);
        (, address p2) = factory.createToken{value: 2e18}("New", "NEW", "");
        assertEq(CurvePool(p2).virtualUsdc(), 12_000e18);
        assertEq(CurvePool(p2).feeBps(), 200);
        assertEq(CurvePool(p2).creatorShareBps(), 3_000);

        vm.prank(alice);
        vm.expectRevert("only owner");
        factory.setParams(1, 1, 1, 1, 1);
    }

    // ---- fuzz: solvency under arbitrary buy/sell sequences ----

    function testFuzz_solvency(uint96 a, uint96 b, uint96 sellPct) public {
        uint256 buyA = bound(uint256(a), 1e12, 200_000e18);
        uint256 buyB = bound(uint256(b), 1e12, 200_000e18);
        uint256 pct = bound(uint256(sellPct), 1, 100);

        vm.deal(alice, buyA);
        vm.deal(bob, buyB);

        vm.prank(alice);
        uint256 outA = pool.buy{value: buyA}(0, block.timestamp);
        vm.prank(bob);
        pool.buy{value: buyB}(0, block.timestamp);

        uint256 sellAmt = (outA * pct) / 100;
        if (sellAmt > 0) {
            vm.startPrank(alice);
            token.approve(address(pool), sellAmt);
            pool.sell(sellAmt, 0, block.timestamp);
            vm.stopPrank();
        }

        // invariant: native balance always covers curve reserve + unclaimed fees
        assertEq(address(pool).balance, pool.realUsdc() + pool.creatorFees() + pool.protocolFees());
        // invariant: token conservation
        assertEq(
            token.balanceOf(address(pool)) + token.balanceOf(alice) + token.balanceOf(bob),
            SUPPLY
        );
        assertEq(pool.tokenReserve(), token.balanceOf(address(pool)));
    }
}
