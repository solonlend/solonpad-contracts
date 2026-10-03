// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V2FeeConverter} from "../../../../src/v3/V2FeeConverter.sol";
import {CovCToken} from "./CovCMocks.sol";
import {CovCV2Route} from "./CovC_V2.t.sol";

/// @notice SUSPICIOUS (low severity, design): V2FeeConverter.feeBalance[id] (and StockFeeConverter.feeBalance
/// [orderId], same pattern) is only ever decreased by the signed q.fees18. Any pre-funded excess
/// (feeBalance - fees18) stays in the converter forever: depositFees reverts once converted[id] is set and there is
/// no refund/sweep path. OpsVault funds depositFees with a separately signed amount, so a mismatch between the
/// ops expense amount and the later quote's fees18 strands native USDC. This test asserts CURRENT behaviour.
contract CovCBugReproStrandedFeeBalance is Test {
    function test_ExcessPrefundedFeesAreStranded() public {
        CovCToken token = new CovCToken();
        CovCV2Route route = new CovCV2Route(address(token));
        V2FeeConverter conv =
            new V2FeeConverter(address(this), address(route), vm.addr(777), address(0x0B5), bytes32(uint256(1)), 1);
        vm.deal(address(route), 100 ether);
        token.mint(address(this), 1 ether);
        token.approve(address(conv), type(uint256).max);
        bytes32 id = keccak256("lot");
        conv.depositFees{value: 1 ether}(id);
        V2FeeConverter.Quote memory q = V2FeeConverter.Quote(
            id, address(token), 1 ether, 9.9 ether, 10 ether, vm.getBlockTimestamp(), vm.getBlockTimestamp() + 60, 1, 0.2 ether
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(777, conv.quoteDigest(q));
        conv.convert(id, address(token), 1 ether, abi.encode(q, abi.encodePacked(r, s, v)));
        assertTrue(conv.converted(id));
        assertEq(conv.feeBalance(id), 0.8 ether);
        assertEq(address(conv).balance, 0.8 ether); // stranded: no function moves it
        vm.expectRevert();
        conv.depositFees{value: 1}(id);
    }

    receive() external payable {}
}
