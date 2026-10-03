// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StockHubBase} from "../../StockHub.t.sol";
import {SolonStockHub} from "../../../../src/v3/stock/SolonStockHub.sol";
import {HubSettlement} from "../../../../src/v3/stock/HubSettlement.sol";
import {HubExits} from "../../../../src/v3/stock/HubExits.sol";
import {Messages} from "../../../../src/v3/stock/libs/Messages.sol";
import {CovDGateStub} from "./CovD_Hub.t.sol";

/// @dev A buyer contract that can be told to refuse native (e.g. a wallet that later gains a receive path).
contract CovDToggleUser {
    bool public accept;

    function setAccept(bool a) external {
        accept = a;
    }

    function buy(SolonStockHub hub, address u, uint256 usdcIn, uint256 extra) external returns (uint256) {
        return hub.requestBuy{value: usdcIn + extra}(u, usdcIn, 1);
    }

    function escalateFunds(SolonStockHub hub, uint256 id, address to) external {
        hub.escalateFunds{value: 1 ether}(id, to);
    }

    function claim(SolonStockHub hub, uint256 id) external {
        hub.claim(id);
    }

    receive() external payable {
        require(accept, "no native");
    }
}

/// @notice HubExits L231-238 `_pay` fallback (reached from escalateFunds L152): a refund the user's address
///         refuses becomes that order's `owed` + `claimableTotal`, and is claimable exactly once.
contract CovDHubOwedTest is StockHubBase {
    CovDGateStub stub;
    CovDToggleUser buyer;
    address rhUser = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        stub = new CovDGateStub();
        vm.prank(owner);
        hub.setCanonicalGate(address(stub));
        buyer = new CovDToggleUser();
        vm.deal(address(buyer), 2_000 ether);
    }

    function testCovD_EscalateFundsRefundRefusedBecomesOwedThenClaimedOnce() public {
        uint256 id = buyer.buy(hub, NVDA, 1_000e18, 1 ether);
        _launch(id, 0.5 ether); // principal out, order dispatched from its reserve (0.01 LZ fee)
        _result(id, Messages.Outcome.Failed, 997_500_000, 0); // Returning: principal stuck on the reserve chain
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Returning));
        assertEq(hub.escrowed(), 2.99e18, "fee 2.5 + unused reserve 0.49");
        vm.warp(block.timestamp + 6 hours);

        uint256 back = 2.5e18 + 0.49e18;
        uint256 hubBefore = address(hub).balance;
        vm.expectEmit(true, true, false, true, address(hub));
        emit HubExits.OrderOwed(id, address(buyer), back);
        vm.expectEmit(true, false, false, true, address(hub));
        emit HubExits.Claimable(address(buyer), back);
        buyer.escalateFunds(hub, id, rhUser);

        HubSettlement.Order memory o = hub.getOrder(id);
        assertEq(uint8(o.status), uint8(HubSettlement.Status.Escalated));
        assertEq(o.owed, back, "refused refund waits on the order");
        assertEq(o.fee, 0);
        assertEq(o.extra, 0);
        assertEq(hub.claimableTotal(), back);
        assertEq(hub.escrowed(), 0, "moved from escrow to claimable, not lost");
        assertEq(address(hub).balance, hubBefore, "kept in the hub (the 1 USDC hook went to the gate)");
        assertEq(address(stub).balance, 1 ether);
        assertEq(hub.available(), 0, "owed money is never float");
        assertEq(stub.lastRef(), bytes32(id));

        // still refusing: claim reverts, owed untouched
        vm.expectRevert(HubSettlement.TransferFailed.selector);
        buyer.claim(hub, id);
        assertEq(hub.getOrder(id).owed, back);

        buyer.setAccept(true);
        uint256 buyerBefore = address(buyer).balance;
        buyer.claim(hub, id);
        assertEq(address(buyer).balance, buyerBefore + back);
        assertEq(hub.getOrder(id).owed, 0);
        assertEq(hub.claimableTotal(), 0);
        assertEq(address(hub).balance, hubBefore - back);

        vm.expectRevert(abi.encodeWithSelector(HubSettlement.NotClaimable.selector, id, 0));
        buyer.claim(hub, id);
        assertEq(address(buyer).balance, buyerBefore + back, "exactly once");
    }
}
