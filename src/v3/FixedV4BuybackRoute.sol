// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IExistingFeeRouter {
    function v4Swap(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut, bool feeOnOutput)
        external
        payable
        returns (uint256);
}

/// @notice Concrete adapter to the existing SolonFeeRouter v4Swap path used by the old daemon.
/// The pool is immutable and output is forwarded only to the fixed buyback executor.
contract FixedV4BuybackRoute is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable executor;
    address public immutable feeRouter;
    bytes32 public immutable path;
    PoolKey private pool;

    constructor(address executor_, address router_, PoolKey memory key) {
        require(
            executor_ != address(0) && router_.code.length != 0 && Currency.unwrap(key.currency0) == address(0)
                && Currency.unwrap(key.currency1).code.length != 0 && address(key.hooks) == address(0),
            "Invalid fixed route"
        );
        executor = executor_;
        feeRouter = router_;
        pool = key;
        path = keccak256(abi.encode(key));
    }

    receive() external payable {
        require(msg.sender == feeRouter, "Router only");
    }

    function buy(address token, bytes32 path_, address recipient, uint256 minOut)
        external
        payable
        nonReentrant
        returns (uint256 received)
    {
        require(
            msg.sender == executor && recipient == executor && token == Currency.unwrap(pool.currency1) && path_ == path
                && msg.value != 0 && minOut != 0,
            "Fixed route only"
        );
        uint256 beforeToken = IERC20(token).balanceOf(address(this));
        uint256 beforeRecipient = IERC20(token).balanceOf(recipient);
        uint256 beforeNative = address(this).balance - msg.value;
        uint256 reported = IExistingFeeRouter(feeRouter).v4Swap{value: msg.value}(pool, true, msg.value, minOut, false);
        received = IERC20(token).balanceOf(address(this)) - beforeToken;
        require(
            received >= minOut && reported == received && address(this).balance == beforeNative, "Incomplete buyback"
        );
        IERC20(token).safeTransfer(recipient, received);
        require(
            IERC20(token).balanceOf(address(this)) == beforeToken
                && IERC20(token).balanceOf(recipient) == beforeRecipient + received,
            "Inexact output"
        );
    }
}
