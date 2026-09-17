// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PonsV2IntegrationTest} from "./PonsV2Integration.t.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {RadianExecutor} from "../src/radian/RadianExecutor.sol";
import {MockStock} from "../src/mock/MockStock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RadianExecutorTest is PonsV2IntegrationTest {
    RadianExecutor ex;
    MockStock stock;
    address kp = makeAddr("keeper");
    uint256 userPk = 0xA11CE;
    address user;

    function setUp() public override {
        super.setUp();
        user = vm.addr(userPk);
        ex = new RadianExecutor(factory);
        vm.prank(owner);
        ex.setKeeper(kp);
        vm.deal(user, 100e18);
        vm.prank(user);
        ex.deposit{value: 50e18}();
        vm.txGasPrice(1 gwei);
        stock = new MockStock("Nvidia (test stand-in)", "NVDAx");
        vm.startPrank(owner);
        factory.setPairTokenEconomics(address(stock), 20e18, 50e18, 18);
        factory.setPairTokenApproved(address(stock), true);
        vm.stopPrank();
    }

    function _auth(address tok, uint256 perBuyMax, uint32 count, uint32 interval, uint64 deadline, uint256 nonce)
        internal
        view
        returns (RadianExecutor.BuyAuth memory)
    {
        return RadianExecutor.BuyAuth({
            user: user, token: tok, perBuyMax: perBuyMax, maxGasPrice: 2 gwei, totalCount: count, minInterval: interval, deadline: deadline, nonce: nonce
        });
    }

    function _sign(RadianExecutor.BuyAuth memory a, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ex.hashAuth(a));
        return abi.encodePacked(r, s, v);
    }

    function test_exec_buysForUserWithinBounds() public {
        vm.warp(vm.getBlockTimestamp() + 20); // past the snipe window
        RadianExecutor.BuyAuth memory a = _auth(token, 1e18, 3, 3600, uint64(vm.getBlockTimestamp() + 1 days), 0);
        bytes memory sig = _sign(a, userPk);
        uint256 stipend = ex.GAS_STIPEND() * 1 gwei; // tx.gasprice 1 gwei < cap 2 gwei
        vm.prank(kp);
        uint256 out = ex.executeBuy(a, sig, 1e18, 0);
        assertGt(out, 0);
        assertEq(IERC20(token).balanceOf(user), out, "tokens go to the user, never the keeper");
        uint256 fee = (1e18 * ex.FEE_BPS()) / 10_000;
        assertEq(ex.balanceOf(user, address(0)), 50e18 - 1e18 - fee - stipend);
        assertEq(ex.feePool(address(0)), fee);
        assertEq(ex.gasCredit(kp), stipend);
        (uint32 count, uint64 lastAt) = ex.execs(ex.authId(a));
        assertEq(count, 1);
        assertEq(lastAt, uint64(vm.getBlockTimestamp()));

        vm.prank(kp);
        vm.expectRevert(RadianExecutor.TooSoon.selector);
        ex.executeBuy(a, sig, 1e18, 0);
        vm.warp(vm.getBlockTimestamp() + 3600);
        vm.prank(kp);
        ex.executeBuy(a, sig, 0.5e18, 0);
        vm.warp(vm.getBlockTimestamp() + 3600);
        vm.prank(kp);
        ex.executeBuy(a, sig, 0.5e18, 0);
        vm.warp(vm.getBlockTimestamp() + 3600);
        vm.prank(kp);
        vm.expectRevert(RadianExecutor.AuthExhausted.selector);
        ex.executeBuy(a, sig, 0.5e18, 0);

        vm.prank(kp);
        ex.claimGas();
        assertEq(kp.balance, stipend * 3);
    }

    function test_exec_rejectsBadAuthority() public {
        vm.warp(vm.getBlockTimestamp() + 20); // past the snipe window
        RadianExecutor.BuyAuth memory a = _auth(token, 1e18, 3, 0, uint64(vm.getBlockTimestamp() + 1 days), 0);
        bytes memory sig = _sign(a, userPk);
        vm.prank(alice);
        vm.expectRevert(RadianExecutor.NotKeeper.selector);
        ex.executeBuy(a, sig, 1e18, 0);
        vm.prank(kp);
        vm.expectRevert(RadianExecutor.OverCap.selector);
        ex.executeBuy(a, sig, 2e18, 0);
        bytes memory forged = _sign(a, 0xB0B);
        vm.prank(kp);
        vm.expectRevert(RadianExecutor.BadSignature.selector);
        ex.executeBuy(a, forged, 1e18, 0);
        RadianExecutor.BuyAuth memory expired = _auth(token, 1e18, 3, 0, uint64(vm.getBlockTimestamp() - 1), 0);
        bytes memory sigE = _sign(expired, userPk);
        vm.prank(kp);
        vm.expectRevert(RadianExecutor.AuthExpired.selector);
        ex.executeBuy(expired, sigE, 1e18, 0);
        RadianExecutor.BuyAuth memory unknown = _auth(address(0xdead), 1e18, 3, 0, uint64(vm.getBlockTimestamp() + 1 days), 0);
        bytes memory sigU = _sign(unknown, userPk);
        vm.prank(kp);
        vm.expectRevert(RadianExecutor.UnknownToken.selector);
        ex.executeBuy(unknown, sigU, 1e18, 0);
    }

    function test_exec_cancelAuthVoidsEverything() public {
        vm.warp(vm.getBlockTimestamp() + 20); // past the snipe window
        RadianExecutor.BuyAuth memory a = _auth(token, 1e18, 3, 0, uint64(vm.getBlockTimestamp() + 1 days), 0);
        bytes memory sig = _sign(a, userPk);
        vm.prank(user);
        ex.cancelAuth();
        vm.prank(kp);
        vm.expectRevert(RadianExecutor.BadSignature.selector);
        ex.executeBuy(a, sig, 1e18, 0);
        // a fresh auth under the new nonce works
        RadianExecutor.BuyAuth memory b = _auth(token, 1e18, 3, 0, uint64(vm.getBlockTimestamp() + 1 days), 1);
        bytes memory sigB = _sign(b, userPk);
        vm.prank(kp);
        ex.executeBuy(b, sigB, 1e18, 0);
    }

    function test_exec_withdrawNeedsNobody() public {
        vm.warp(vm.getBlockTimestamp() + 20); // past the snipe window
        address other = makeAddr("other");
        vm.prank(user);
        ex.withdraw(address(0), 20e18, other);
        assertEq(other.balance, 20e18);
        assertEq(ex.balanceOf(user, address(0)), 30e18);
        vm.prank(user);
        vm.expectRevert(RadianExecutor.Insufficient.selector);
        ex.withdraw(address(0), 31e18, other);
    }

    function test_exec_clampedFillCreditsRefundAndFeesOnSpentOnly() public {
        vm.warp(vm.getBlockTimestamp() + 20); // past the snipe window
        RadianExecutor.BuyAuth memory a = _auth(token, 45e18, 1, 0, uint64(vm.getBlockTimestamp() + 1 days), 0);
        bytes memory sig = _sign(a, userPk);
        uint256 stipend = ex.GAS_STIPEND() * 1 gwei;
        vm.prank(kp);
        ex.executeBuy(a, sig, 45e18, 0); // far past graduation: the curve clamps and refunds
        uint256 feePool = ex.feePool(address(0));
        uint256 spent = (feePool * 10_000) / ex.FEE_BPS();
        assertLt(spent, 45e18, "only the filled part was spent");
        assertApproxEqAbs(ex.balanceOf(user, address(0)), 50e18 - spent - feePool - stipend, 1e6, "unspent quote credited back");
        assertEq(address(ex).balance, ex.balanceOf(user, address(0)) + feePool + stipend, "ledger matches balance");
    }

    function test_exec_feesOnlyToPlatformOwner() public {
        vm.warp(vm.getBlockTimestamp() + 20); // past the snipe window
        RadianExecutor.BuyAuth memory a = _auth(token, 1e18, 1, 0, uint64(vm.getBlockTimestamp() + 1 days), 0);
        bytes memory sig = _sign(a, userPk);
        vm.prank(kp);
        ex.executeBuy(a, sig, 1e18, 0);
        vm.prank(alice);
        vm.expectRevert(RadianExecutor.NotOwner.selector);
        ex.withdrawFees(address(0), alice);
        uint256 f = ex.feePool(address(0));
        vm.prank(owner);
        ex.withdrawFees(address(0), owner);
        assertEq(owner.balance, f);
    }

    function test_exec_erc20QuoteUsesTokenLedgerAndNativeForGas() public {
        vm.warp(vm.getBlockTimestamp() + 20); // past the snipe window
        // a stock-quoted launch by the creator
        stock.mint(creator, 100e18);
        vm.prank(creator);
        (address t,) = factory.launchToken{value: LAUNCH_FEE}(_params(bytes32(uint256(77))), 0, address(stock));
        vm.warp(vm.getBlockTimestamp() + 20);
        stock.mint(user, 10e18);
        vm.startPrank(user);
        stock.approve(address(ex), 10e18);
        ex.depositToken(address(stock), 10e18);
        vm.stopPrank();
        RadianExecutor.BuyAuth memory a = _auth(t, 2e18, 1, 0, uint64(vm.getBlockTimestamp() + 1 days), 0);
        uint256 stipend = ex.GAS_STIPEND() * 1 gwei;
        bytes memory sig = _sign(a, userPk);
        vm.prank(kp);
        uint256 out = ex.executeBuy(a, sig, 2e18, 0);
        assertGt(out, 0);
        assertEq(IERC20(t).balanceOf(user), out);
        uint256 fee = (2e18 * ex.FEE_BPS()) / 10_000;
        assertEq(ex.balanceOf(user, address(stock)), 10e18 - 2e18 - fee, "principal + fee from the stock ledger");
        assertEq(ex.balanceOf(user, address(0)), 50e18 - stipend, "gas from the native ledger");
        assertEq(ex.feePool(address(stock)), fee);
    }
}
