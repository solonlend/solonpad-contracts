// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

contract HookToken is ERC20 {
    address public blockedRecipient;
    address public taxedSender;
    address public taxedRecipient;

    function setTaxRoute(address from, address to) external {
        taxedSender = from;
        taxedRecipient = to;
    }
    constructor() ERC20("Fixture asset", "FIX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function blockRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(to != blockedRecipient || to == address(0), "frozen recipient");
        if (from == taxedSender && to == taxedRecipient && amount > 0) {
            super._update(from, address(0), 1);
            amount -= 1;
        }
        super._update(from, to, amount);
    }
}

/// @dev Minimal authenticated position/router fixture using the real v4 accounting path.
/// Like canonical PositionManager, msgSender is the locker and the payer.
contract HookPositionManager is IUnlockCallback {
    using CurrencySettler for Currency;
    IPoolManager public immutable manager;
    address public msgSender;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }
    receive() external payable {}

    function add(PoolKey memory key, ModifyLiquidityParams memory params) external payable {
        require(msgSender == address(0));
        msgSender = msg.sender;
        manager.unlock(abi.encode(key, params));
        msgSender = address(0);
        if (address(this).balance > 0) payable(msg.sender).transfer(address(this).balance);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, ModifyLiquidityParams memory params) = abi.decode(data, (PoolKey, ModifyLiquidityParams));
        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");
        if (delta.amount0() < 0) key.currency0.settle(manager, msgSender, uint256(-int256(delta.amount0())), false);
        if (delta.amount1() < 0) key.currency1.settle(manager, msgSender, uint256(-int256(delta.amount1())), false);
        return "";
    }
}

contract HookFeeReceiver {
    function onFeeCredit(bytes32, address, uint8, uint256) external {}
}

contract HookBatchRouter is IUnlockCallback {
    using CurrencySettler for Currency;
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }
    receive() external payable {}

    function swapTwice(PoolKey memory key, SwapParams memory params) external payable returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta));
        if (address(this).balance != 0) payable(msg.sender).transfer(address(this).balance);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address payer, PoolKey memory key, SwapParams memory params) = abi.decode(raw, (address, PoolKey, SwapParams));
        BalanceDelta first = manager.swap(key, params, "");
        BalanceDelta second = manager.swap(key, params, "");
        BalanceDelta delta = first + second;
        if (delta.amount0() < 0) key.currency0.settle(manager, payer, uint256(-int256(delta.amount0())), false);
        if (delta.amount1() < 0) key.currency1.settle(manager, payer, uint256(-int256(delta.amount1())), false);
        if (delta.amount0() > 0) manager.take(key.currency0, payer, uint256(int256(delta.amount0())));
        if (delta.amount1() > 0) manager.take(key.currency1, payer, uint256(int256(delta.amount1())));
        return abi.encode(delta);
    }
}

/// @dev Pairs callbacks inside one transaction even with Foundry's isolate=true.
contract HookCallbackDriver {
    function pair(address hook, bytes calldata beforeCall, bytes calldata afterCall)
        external
        returns (bool success, bytes memory data)
    {
        (bool first, bytes memory errorData) = hook.call(beforeCall);
        if (!first) {
            assembly ("memory-safe") { revert(add(errorData, 32), mload(errorData)) }
        }
        return hook.call(afterCall);
    }
}
