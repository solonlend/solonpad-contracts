// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BuybackToken} from "./Buyback.t.sol";
import {FixedV4BuybackRoute} from "../../src/v3/FixedV4BuybackRoute.sol";

contract ExistingFeeRouterFixture {
    BuybackToken token;
    bool public refund;

    constructor(BuybackToken t) {
        token = t;
    }

    function setRefund(bool value) external {
        refund = value;
    }

    function v4Swap(PoolKey calldata key, bool zeroForOne, uint256 amount, uint256 minOut, bool feeOnOutput)
        external
        payable
        returns (uint256)
    {
        require(Currency.unwrap(key.currency1) == address(token) && zeroForOne && !feeOnOutput && amount == msg.value);
        require(minOut <= 100 ether);
        token.mint(msg.sender, 100 ether);
        if (refund) {
            (bool ok,) = msg.sender.call{value: 1}("");
            require(ok);
        }
        return 100 ether;
    }
}

contract FixedV4BuybackRouteTest is Test {
    function testFixedAdapterCallsExistingFeeRouterAndRejectsPartialNativeRefund() public {
        BuybackToken token = new BuybackToken();
        ExistingFeeRouterFixture router = new ExistingFeeRouterFixture(token);
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 10000, 100, IHooks(address(0)));
        FixedV4BuybackRoute route = new FixedV4BuybackRoute(address(this), address(router), key);
        bytes32 path = keccak256(abi.encode(key));
        vm.deal(address(this), 200 ether);
        assertEq(route.buy{value: 100 ether}(address(token), path, address(this), 90 ether), 100 ether);
        assertEq(token.balanceOf(address(this)), 100 ether);
        router.setRefund(true);
        vm.expectRevert();
        route.buy{value: 100 ether}(address(token), path, address(this), 90 ether);
        assertEq(token.balanceOf(address(this)), 100 ether);
    }
}
