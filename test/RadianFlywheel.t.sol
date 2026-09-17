// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RadianStaking} from "../src/radian/RadianStaking.sol";
import {RadianTreasury} from "../src/radian/RadianTreasury.sol";

// Minimal ERC20 with burn, mirroring the launcher token surface the flywheel needs.
contract MockRadian {
    string public name = "Radian";
    string public symbol = "RADIAN";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
        totalSupply += v;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[to] += v;
        return true;
    }

    function burn(uint256 v) external {
        balanceOf[msg.sender] -= v;
        totalSupply -= v;
    }
}

// Mock bonding curve: holds a RADIAN reserve (like a real curve) and buy()
// transfers 1:1 from that reserve to the buyer — no minting, so a later burn
// genuinely reduces total supply. Exposes a settable quote reserve so the
// treasury's per-flush cap can be exercised.
contract MockCurve {
    MockRadian public radian;
    bool public graduated;
    uint256 public quoteReserve = 1_000e18;

    constructor(MockRadian r) {
        radian = r;
        r.mint(address(this), 1_000_000_000e18); // curve reserve
    }

    function setGraduated(bool g) external {
        graduated = g;
    }

    function setQuoteReserve(uint256 q) external {
        quoteReserve = q;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (quoteReserve, radian.balanceOf(address(this)));
    }

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256) {
        require(msg.value == quoteIn, "value");
        require(quoteIn >= minTokensOut, "slippage"); // 1 USDC -> 1 RADIAN
        radian.transfer(recipient, quoteIn);
        return quoteIn;
    }
}

// Mirrors PonsV2FeeEscrow: balances are credited per recipient and paid to
// whoever calls claim() — which is exactly why the treasury must call it.
contract MockEscrow {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public tokenBalanceOf;

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
    }

    function creditToken(address recipient, address token, uint256 amount) external {
        tokenBalanceOf[recipient][token] += amount;
    }

    function claim() external returns (uint256 amount) {
        amount = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send");
    }

    function claimToken(address token) external returns (uint256 amount) {
        amount = tokenBalanceOf[msg.sender][token];
        tokenBalanceOf[msg.sender][token] = 0;
        MockRadian(token).transfer(msg.sender, amount);
    }
}

// A staking pool for a different token — must be rejected by setStaking.
contract OtherStaking {
    address public stakingToken = address(0xBEEF);
    function notifyReward() external payable {}
}

contract RadianFlywheelTest is Test {
    MockRadian radian;
    MockCurve curve;
    MockEscrow escrow;
    RadianStaking staking;
    RadianTreasury treasury;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    uint256 constant FAR = 1 days;

    function setUp() public {
        radian = new MockRadian();
        curve = new MockCurve(radian);
        escrow = new MockEscrow();
        staking = new RadianStaking(address(radian), owner);
        treasury = new RadianTreasury(address(radian), address(curve), address(escrow), owner);

        vm.startPrank(owner);
        treasury.setStaking(address(staking));
        treasury.setKeeper(keeper);
        staking.setRewardsDistributor(address(treasury));
        vm.stopPrank();

        radian.mint(alice, 1_000e18);
        radian.mint(bob, 1_000e18);
        vm.warp(1_700_000_000); // a realistic clock so "too soon" checks have room
    }

    function _stake(address who, uint256 amt) internal {
        vm.startPrank(who);
        radian.approve(address(staking), amt);
        staking.stake(amt);
        vm.stopPrank();
    }

    function _fund(uint256 amt) internal {
        vm.deal(address(this), amt);
        (bool ok,) = address(treasury).call{value: amt}("");
        assertTrue(ok);
    }

    function _flush(uint256 minOut) internal returns (uint256 burned, uint256 toStakers) {
        vm.prank(owner);
        return treasury.flush(minOut, block.timestamp + FAR);
    }

    // ---- staking ----

    function test_stakingRealYieldSplitByStake() public {
        _stake(alice, 300e18);
        _stake(bob, 100e18); // 3:1

        vm.deal(owner, 8e18);
        vm.prank(owner);
        staking.notifyReward{value: 8e18}();

        vm.warp(block.timestamp + 7 days); // full period

        assertApproxEqRel(staking.earned(alice), 6e18, 0.01e18);
        assertApproxEqRel(staking.earned(bob), 2e18, 0.01e18);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        staking.getReward();
        assertApproxEqRel(alice.balance - balBefore, 6e18, 0.01e18);
    }

    function test_stakingSecondNotifyMidPeriodRollsLeftover() public {
        _stake(alice, 100e18);
        vm.deal(owner, 14e18);
        vm.startPrank(owner);
        staking.notifyReward{value: 7e18}();
        vm.warp(block.timestamp + 3.5 days); // half streamed
        staking.notifyReward{value: 7e18}(); // leftover 3.5 + 7 = 10.5 over a fresh 7 days
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        // alice is the only staker: she ends up with everything ever notified
        assertApproxEqRel(staking.earned(alice), 14e18, 0.01e18);
        assertEq(staking.totalDistributed(), 14e18);
    }

    function test_onlyDistributorOrOwnerNotifies() public {
        vm.deal(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert("not distributor");
        staking.notifyReward{value: 1e18}();
    }

    function test_withdrawAndExit() public {
        _stake(alice, 500e18);
        vm.deal(owner, 7e18);
        vm.prank(owner);
        staking.notifyReward{value: 7e18}();
        vm.warp(block.timestamp + 7 days);

        uint256 tokBefore = radian.balanceOf(alice);
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        staking.exit(); // withdraw all + claim
        assertEq(radian.balanceOf(alice) - tokBefore, 500e18);
        assertApproxEqRel(alice.balance - ethBefore, 7e18, 0.01e18);
        assertEq(staking.totalStaked(), 0);

        // exit again with nothing staked must not revert
        vm.prank(alice);
        staking.exit();
    }

    function test_stakingTwoStepOwnership() public {
        vm.prank(owner);
        staking.transferOwnership(bob);
        assertEq(staking.owner(), owner, "owner unchanged until accepted");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob)); // not owner yet
        staking.setRewardsDistributor(bob);
        vm.prank(bob);
        staking.acceptOwnership();
        assertEq(staking.owner(), bob);
        vm.prank(bob);
        vm.expectRevert("renounce disabled");
        staking.renounceOwnership();
    }

    // ---- treasury ----

    function test_treasuryFlushBuysBackBurnsAndFundsStakers() public {
        _stake(alice, 100e18);
        _fund(10e18);
        uint256 supplyBefore = radian.totalSupply();

        (uint256 burned, uint256 toStakers) = _flush(5e18);

        // 50/50: 5 USDC buys 5 RADIAN which is burned; 5 USDC funds staking
        assertEq(burned, 5e18);
        assertEq(toStakers, 5e18);
        assertEq(radian.totalSupply(), supplyBefore - 5e18, "supply burned");
        assertEq(treasury.totalBurned(), 5e18);
        assertEq(treasury.totalToStakers(), 5e18);
        assertEq(treasury.totalFlushed(), 10e18);
        assertEq(address(staking).balance, 5e18, "staking funded in USDC");

        vm.warp(block.timestamp + 7 days);
        assertApproxEqRel(staking.earned(alice), 5e18, 0.01e18);
    }

    function test_claimFeesPullsFromEscrow() public {
        vm.deal(address(this), 3e18);
        escrow.credit{value: 3e18}(address(treasury));
        assertEq(treasury.claimableFees(), 3e18);
        vm.prank(alice); // permissionless
        uint256 got = treasury.claimFees();
        assertEq(got, 3e18);
        assertEq(address(treasury).balance, 3e18);
        assertEq(treasury.claimableFees(), 0);
    }

    function test_claimTokenFeesAndRescue() public {
        MockRadian eurc = new MockRadian();
        eurc.mint(address(escrow), 9e6);
        escrow.creditToken(address(treasury), address(eurc), 9e6);
        treasury.claimTokenFees(address(eurc));
        assertEq(eurc.balanceOf(address(treasury)), 9e6);
        vm.prank(owner);
        treasury.rescueERC20(address(eurc), bob, 9e6);
        assertEq(eurc.balanceOf(bob), 9e6);
        // $RADIAN can never be rescued — it exists here only to be burned
        vm.prank(owner);
        vm.expectRevert("radian is burn-only");
        treasury.rescueERC20(address(radian), bob, 1);
    }

    function test_flushRequiresQuoteAndDeadline() public {
        _stake(alice, 1e18);
        _fund(2e18);
        vm.prank(owner);
        vm.expectRevert("quote required");
        treasury.flush(0, block.timestamp + FAR);
        vm.prank(owner);
        vm.expectRevert("expired");
        treasury.flush(1, block.timestamp - 1);
        // an honest keeper quote that the curve cannot meet reverts inside buy()
        vm.prank(keeper);
        vm.expectRevert("slippage");
        treasury.flush(100e18, block.timestamp + FAR);
    }

    function test_flushCapsBuybackToReserveShare() public {
        _stake(alice, 1e18);
        curve.setQuoteReserve(100e18); // cap = 5% = 5 USDC per flush
        _fund(40e18); // wants a 20 USDC buyback

        (uint256 burned, uint256 toStakers) = _flush(1);
        assertEq(burned, 5e18, "buyback capped to 5% of reserve");
        assertEq(toStakers, 20e18, "staker share unchanged");
        assertEq(address(treasury).balance, 15e18, "excess buyback waits for the next flush");
        assertEq(treasury.totalFlushed(), 25e18);
    }

    function test_flushRateLimited() public {
        _stake(alice, 1e18);
        _fund(2e18);
        _flush(1);
        _fund(2e18);
        vm.prank(keeper);
        vm.expectRevert("too soon");
        treasury.flush(1, block.timestamp + FAR);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        treasury.flush(1, block.timestamp + FAR);
    }

    function test_flushOnlyOwnerOrKeeper() public {
        _fund(1e18);
        vm.prank(alice);
        vm.expectRevert("not keeper");
        treasury.flush(1, block.timestamp + FAR);
    }

    function test_graduatedCurveRoutesAllToStakers() public {
        _stake(alice, 100e18);
        curve.setGraduated(true);
        _fund(4e18);
        (uint256 burned, uint256 toStakers) = _flush(0); // no quote needed: no buyback
        assertEq(burned, 0);
        assertEq(toStakers, 4e18);
    }

    function test_setStakingValidatesToken() public {
        OtherStaking other = new OtherStaking();
        vm.prank(owner);
        vm.expectRevert("wrong staking token");
        treasury.setStaking(address(other));
        vm.prank(owner);
        vm.expectRevert(bytes("zero")); // 4-char literal would also match bytes4
        treasury.setStaking(address(0));
    }

    function test_treasuryTwoStepOwnership() public {
        vm.prank(owner);
        treasury.transferOwnership(bob);
        assertEq(treasury.owner(), owner);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        treasury.setKeeper(bob);
        vm.prank(bob);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), bob);
        vm.prank(bob);
        treasury.setKeeper(bob);
        assertEq(treasury.keeper(), bob);
        vm.prank(bob);
        vm.expectRevert("renounce disabled");
        treasury.renounceOwnership();
    }
}
