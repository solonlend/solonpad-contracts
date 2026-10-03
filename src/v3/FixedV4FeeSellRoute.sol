// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Fixed v4 fee-token/native exit using the existing PoolSwapTest ABI.
/// Bypasses the optional FeeRouter 0.5% interface charge; LP fees/slippage are
/// included in signed net minOut. Gas remains separately funded through Ops.
/// Deployment must verify the immutable router and PoolManager bytecode/manifest.
contract FixedV4FeeSellRoute is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable converter;
    PoolSwapTest public immutable swapRouter;
    address public immutable manager;
    address public immutable asset;
    bytes32 public immutable path;
    PoolKey private pool;
    event Sold(uint256 raw, uint256 actualUSDC18);

    constructor(address converter_, address router_, PoolKey memory key) {
        require(
            converter_ != address(0) && router_.code.length != 0 && Currency.unwrap(key.currency0) == address(0)
                && Currency.unwrap(key.currency1).code.length != 0 && address(key.hooks) == address(0)
                && key.fee < 1_000_000
        );
        converter = converter_;
        swapRouter = PoolSwapTest(router_);
        manager = address(PoolSwapTest(router_).manager());
        require(manager.code.length != 0);
        asset = Currency.unwrap(key.currency1);
        pool = key;
        path = keccak256(abi.encode(key));
    }

    receive() external payable {
        require(msg.sender == manager || msg.sender == address(swapRouter));
    }

    function sell(address token, uint256 raw, uint256 minOut, address recipient, bytes32 path_)
        external
        payable
        nonReentrant
        returns (uint256 received)
    {
        require(
            msg.sender == converter && recipient == converter && token == asset && path_ == path && raw != 0
                && raw <= uint256(uint128(type(int128).max)) && minOut != 0 && msg.value == 0
        );
        IERC20 stock = IERC20(asset);
        uint256 beforeRaw = stock.balanceOf(address(this));
        uint256 beforeNative = address(this).balance;
        uint256 beforeRecipient = recipient.balance;
        stock.safeTransferFrom(converter, address(this), raw);
        require(stock.balanceOf(address(this)) == beforeRaw + raw);
        stock.forceApprove(address(swapRouter), raw);
        BalanceDelta delta = swapRouter.swap(
            pool,
            SwapParams(false, -int256(raw), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        stock.forceApprove(address(swapRouter), 0);
        received = address(this).balance - beforeNative;
        require(
            delta.amount1() == -int128(uint128(raw)) && delta.amount0() > 0
                && uint256(uint128(delta.amount0())) == received && received >= minOut
                && stock.balanceOf(address(this)) == beforeRaw,
            "Incomplete fixed sale"
        );
        (bool ok,) = recipient.call{value: received}("");
        require(
            ok && address(this).balance == beforeNative && recipient.balance == beforeRecipient + received,
            "Inexact receipt"
        );
        emit Sold(raw, received);
    }

    function feePpm() external view returns (uint24) {
        return pool.fee;
    }
}
