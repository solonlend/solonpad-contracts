// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {V3HookMiner} from "../../../script/v3/MineV3Hook.s.sol";
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {V3QuoteFeeHook, IV3HookFeeLedger} from "../../../src/v3/V3QuoteFeeHook.sol";
import {V3FeeLedger} from "../../../src/v3/V3FeeLedger.sol";
import {HookToken, HookPositionManager, HookFeeReceiver} from "./HookHarness.sol";

abstract contract HookFixture is Test {
    PoolManager internal manager;
    HookPositionManager internal positions;
    PoolSwapTest internal router;
    V3QuoteFeeHook internal hook;
    V3FeeLedger internal ledger;
    mapping(bytes32 => bytes32) public initialPositionContext;
    PoolKey[3] internal keys;
    address[3] internal quotes;
    address[3] internal memes;
    receive() external payable {}

    function _setUp() internal {
        vm.deal(address(this), 1e32);
        manager = new PoolManager(address(this));
        positions = new HookPositionManager(manager);
        router = new PoolSwapTest(manager);
        ledger = new V3FeeLedger(address(this), address(0x360000));
        bytes memory init =
            abi.encodePacked(type(V3QuoteFeeHook).creationCode, abi.encode(manager, address(this), ledger));
        bytes32 hash = keccak256(init);
        (, bytes32 salt) = V3HookMiner.find(address(this), hash, 0, 1_000_000);
        hook = new V3QuoteFeeHook{salt: salt}(manager, address(this), IV3HookFeeLedger(address(ledger)));
        for (uint256 i; i < 3; ++i) {
            HookToken a = new HookToken();
            HookToken b = new HookToken();
            address low = address(a) < address(b) ? address(a) : address(b);
            address high = address(a) < address(b) ? address(b) : address(a);
            quotes[i] = i == 0 ? address(0) : i == 1 ? low : high;
            memes[i] = i == 2 ? low : high;
            keys[i] =
                PoolKey(Currency.wrap(i == 0 ? address(0) : low), Currency.wrap(high), 0, 100, IHooks(address(hook)));
            a.mint(address(this), 1e32);
            b.mint(address(this), 1e32);
            a.approve(address(positions), type(uint256).max);
            b.approve(address(positions), type(uint256).max);
            a.approve(address(router), type(uint256).max);
            b.approve(address(router), type(uint256).max);
        }
    }

    function _params() internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(-10000, 10000, 1e24, bytes32(uint256(1)));
    }

    function _paramsFor(uint256) internal pure virtual returns (ModifyLiquidityParams memory) {
        return _params();
    }

    function _registration(uint256 i) internal view returns (V3QuoteFeeHook.PoolRegistration memory r) {
        r = V3QuoteFeeHook.PoolRegistration({
            token: memes[i],
            quoteAsset: quotes[i],
            quoteKind: i == 0 ? 0 : 1,
            tokenCodeHash: memes[i].codehash,
            strategy: address(this),
            positionManager: address(positions),
            initialSqrtPriceX96: uint160(1 << 96),
            initialPositionHash: keccak256(abi.encode(_paramsFor(i)))
        });
    }

    function _register(uint256 i) internal {
        hook.registerPool(keys[i], _registration(i));
        address receiver = address(new HookFeeReceiver());
        address[6] memory recipients = [receiver, address(12), receiver, receiver, address(15), address(16)];
        ledger.registerPool(PoolId.unwrap(keys[i].toId()), quotes[i], i == 0 ? 0 : 1, address(hook), recipients);
    }

    function _launch(uint256 i) internal {
        _register(i);
        manager.initialize(keys[i], uint160(1 << 96));
        initialPositionContext[PoolId.unwrap(keys[i].toId())] = keccak256(abi.encode(_paramsFor(i)));
        positions.add{value: i == 0 ? 1e25 : 0}(keys[i], _paramsFor(i));
        delete initialPositionContext[PoolId.unwrap(keys[i].toId())];
    }
}
