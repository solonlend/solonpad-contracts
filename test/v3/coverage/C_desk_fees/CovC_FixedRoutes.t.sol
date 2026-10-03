// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {FixedV4BuybackRoute} from "../../../../src/v3/FixedV4BuybackRoute.sol";
import {FixedV4FeeSellRoute} from "../../../../src/v3/FixedV4FeeSellRoute.sol";
import {CovCToken, CovCNoReceive} from "./CovCMocks.sol";

contract CovCFeeRouter {
    CovCToken token;

    constructor(CovCToken t) {
        token = t;
    }

    function v4Swap(PoolKey calldata, bool, uint256, uint256, bool) external payable returns (uint256) {
        token.mint(msg.sender, 100 ether);
        return 100 ether;
    }

    function poke(address payable to) external payable {
        (bool ok,) = to.call{value: msg.value}("");
        require(ok, "poke failed");
    }
}

/// @notice PoolSwapTest-shaped router with a programmable result.
contract CovCSwapRouter {
    address public manager;
    CovCToken token;
    bool public pullStock = true;
    uint256 public nativeOut;
    int128 public d0;
    int128 public d1;

    constructor(address manager_, CovCToken t) {
        manager = manager_;
        token = t;
    }

    function configure(bool pull, uint256 out, int128 a0, int128 a1) external {
        pullStock = pull;
        nativeOut = out;
        d0 = a0;
        d1 = a1;
    }

    function swap(PoolKey memory, SwapParams memory params, PoolSwapTest.TestSettings memory, bytes memory)
        external
        payable
        returns (BalanceDelta)
    {
        if (pullStock) token.transferFrom(msg.sender, address(this), uint256(-params.amountSpecified));
        if (nativeOut != 0) {
            (bool ok,) = msg.sender.call{value: nativeOut}("");
            require(ok, "router pay");
        }
        return toBalanceDelta(d0, d1);
    }

    function poke(address payable to) external payable {
        (bool ok,) = to.call{value: msg.value}("");
        require(ok, "poke failed");
    }

    receive() external payable {}
}

contract CovCFixedBuybackRouteTest is Test {
    CovCToken token;
    CovCFeeRouter router;
    FixedV4BuybackRoute route;
    bytes32 path;

    function setUp() public {
        token = new CovCToken();
        router = new CovCFeeRouter(token);
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 10000, 100, IHooks(address(0)));
        route = new FixedV4BuybackRoute(address(this), address(router), key);
        path = keccak256(abi.encode(key));
        vm.deal(address(this), 100 ether);
    }

    /// L38 both arms: only the fixed fee router may push native.
    function test_ReceiveRouterOnly() public {
        (bool ok,) = address(route).call{value: 1}("");
        assertFalse(ok);
        router.poke{value: 1}(payable(address(route)));
        assertEq(address(route).balance, 1);
    }

    /// L61 false arm: a fee-on-transfer forward to the executor fails the exact-output guard.
    function test_InexactOutputReverts() public {
        token.setShortFrom(address(route));
        vm.expectRevert(bytes("Inexact output"));
        route.buy{value: 1 ether}(address(token), path, address(this), 1);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(address(this).balance, 100 ether);
        token.setShortFrom(address(0));
        assertEq(route.buy{value: 1 ether}(address(token), path, address(this), 1), 100 ether);
        assertEq(token.balanceOf(address(this)), 100 ether);
        assertEq(token.balanceOf(address(route)), 0);
    }
}

contract CovCFixedFeeSellRouteTest is Test {
    CovCToken token;
    CovCSwapRouter router;
    FixedV4FeeSellRoute route;
    PoolKey key;
    bytes32 path;
    bool rejectNative;

    function setUp() public {
        token = new CovCToken();
        address mgr = address(new CovCNoReceive());
        router = new CovCSwapRouter(mgr, token);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 10000, 100, IHooks(address(0)));
        route = new FixedV4FeeSellRoute(address(this), address(router), key);
        path = keccak256(abi.encode(key));
        token.mint(address(this), 100 ether);
        token.approve(address(route), type(uint256).max);
        vm.deal(address(router), 100 ether);
    }

    receive() external payable {
        require(!rejectNative, "reject");
    }

    /// L36 both arms: the router's PoolManager must have code.
    function test_ConstructorManagerMustHaveCode() public {
        CovCSwapRouter eoaManager = new CovCSwapRouter(address(0x1234), token);
        vm.expectRevert();
        new FixedV4FeeSellRoute(address(this), address(eoaManager), key);
        FixedV4FeeSellRoute ok = new FixedV4FeeSellRoute(address(this), address(router), key);
        assertEq(ok.manager(), router.manager());
        assertEq(ok.asset(), address(token));
        assertEq(ok.feePpm(), 10000);
    }

    /// L43: receive accepts the manager and the swap router, rejects anyone else.
    function test_ReceiveManagerOrRouterOnly() public {
        vm.deal(address(this), 3);
        (bool ok,) = address(route).call{value: 1}("");
        assertFalse(ok);
        router.poke{value: 1}(payable(address(route)));
        vm.deal(router.manager(), 1);
        vm.prank(router.manager());
        (ok,) = address(route).call{value: 1}("");
        assertTrue(ok);
        assertEq(address(route).balance, 2);
    }

    /// L61 false arm: fee-on-transfer pull from the converter is rejected before any swap.
    function test_PullMustBeExact() public {
        token.setShortFrom(address(this));
        vm.expectRevert();
        route.sell(address(token), 1 ether, 1, address(this), path);
        assertEq(token.balanceOf(address(this)), 100 ether);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function _sellExpectIncomplete(bool pull, uint256 out, int128 a0, int128 a1, uint256 minOut) internal {
        router.configure(pull, out, a0, a1);
        uint256 nativeBefore = address(this).balance;
        vm.expectRevert(bytes("Incomplete fixed sale"));
        route.sell(address(token), 1 ether, minOut, address(this), path);
        assertEq(address(this).balance, nativeBefore);
        assertEq(token.balanceOf(address(this)), 100 ether);
    }

    /// L71 false arm: every conjunct of the sale-completeness guard.
    function test_IncompleteSaleConjuncts() public {
        // partial fill: amount1 != -raw
        _sellExpectIncomplete(true, 1 ether, 1 ether, -0.5 ether, 1);
        // amount0 not positive
        _sellExpectIncomplete(true, 0, 0, -1 ether, 1);
        // reported amount0 differs from the actual native received
        _sellExpectIncomplete(true, 1 ether, 2 ether, -1 ether, 1);
        // below the signed floor
        _sellExpectIncomplete(true, 1 ether, 1 ether, -1 ether, 1 ether + 1);
        // stock not actually taken
        _sellExpectIncomplete(false, 1 ether, 1 ether, -1 ether, 1);
        // honest result passes and forwards native to the converter
        router.configure(true, 1 ether, 1 ether, -1 ether);
        uint256 nativeBefore = address(this).balance;
        assertEq(route.sell(address(token), 1 ether, 1 ether, address(this), path), 1 ether);
        assertEq(address(this).balance, nativeBefore + 1 ether);
        assertEq(token.allowance(address(route), address(router)), 0);
    }

    /// L78: recipient (converter) refusing native reverts the sale.
    function test_InexactReceiptWhenConverterRejects() public {
        router.configure(true, 1 ether, 1 ether, -1 ether);
        rejectNative = true;
        vm.expectRevert(bytes("Inexact receipt"));
        route.sell(address(token), 1 ether, 1, address(this), path);
        assertEq(token.balanceOf(address(this)), 100 ether);
    }
}
