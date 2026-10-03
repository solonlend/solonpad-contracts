// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {HookToken} from "./helpers/HookHarness.sol";
import {V3LPLocker} from "../../src/v3/V3LPLocker.sol";

contract V3LPLockerTest is Test {
    PoolManager manager;
    PositionManager positions;
    V3LPLocker locker;
    PoolKey key;
    bytes32 poolId;
    address constant FACTORY = address(0xFAC);
    address constant STRATEGY = address(0x57);

    function setUp() public {
        manager = new PoolManager(address(this));
        positions = new PositionManager(
            IPoolManager(address(manager)),
            IAllowanceTransfer(address(0)),
            300_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0))
        );
        locker = new V3LPLocker(FACTORY, IPositionManager(address(positions)));
        HookToken token = new HookToken();
        token.mint(address(positions), 1e24);
        vm.deal(STRATEGY, 1e24);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 0, 100, IHooks(address(0)));
        poolId = PoolId.unwrap(key.toId());
        manager.initialize(key, uint160(1 << 96));
    }

    function _mint(PoolKey memory pool, address recipient, uint256 liquidity) internal returns (uint256 id) {
        id = positions.nextTokenId();
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            pool, int24(-100), int24(100), liquidity, type(uint128).max, type(uint128).max, recipient, bytes("")
        );
        params[1] = abi.encode(pool.currency0, uint256(0), false);
        params[2] = abi.encode(pool.currency1, uint256(0), false);
        params[3] = abi.encode(pool.currency0, STRATEGY);
        vm.prank(STRATEGY);
        positions.modifyLiquidities{value: 1e20}(abi.encode(actions, params), block.timestamp);
    }

    function _register(uint256 id) internal {
        vm.prank(FACTORY);
        locker.registerPosition(poolId, id, STRATEGY);
    }

    function testAuthenticRegisteredInitialPositionIsPermanentlyCustodied() public {
        uint256 id = positions.nextTokenId();
        _register(id);
        assertEq(_mint(key, STRATEGY, 1e20), id);
        vm.prank(STRATEGY);
        positions.safeTransferFrom(STRATEGY, address(locker), id);
        assertEq(positions.ownerOf(id), address(locker));
        assertTrue(locker.locked(id));
        assertEq(locker.positionOfPool(poolId), id);
        assertEq(locker.poolOfPosition(id), poolId);
        assertEq(locker.strategyOfPosition(id), STRATEGY);
    }

    function testFactoryRegistrationIsExclusiveImmutableAndNonzero() public {
        vm.expectRevert();
        locker.registerPosition(poolId, 1, STRATEGY);
        vm.startPrank(FACTORY);
        vm.expectRevert();
        locker.registerPosition(bytes32(0), 1, STRATEGY);
        vm.expectRevert();
        locker.registerPosition(poolId, 0, STRATEGY);
        vm.expectRevert();
        locker.registerPosition(poolId, 1, address(0));
        locker.registerPosition(poolId, 1, STRATEGY);
        vm.expectRevert();
        locker.registerPosition(poolId, 2, STRATEGY);
        vm.expectRevert();
        locker.registerPosition(bytes32(uint256(42)), 1, STRATEGY);
        vm.stopPrank();
        assertEq(locker.positionOfPool(poolId), 1);
    }

    function testOnlyCanonicalRegisteredTransferFromStrategyCanLock() public {
        uint256 id = _mint(key, STRATEGY, 1e20);
        vm.expectRevert();
        vm.prank(STRATEGY);
        positions.safeTransferFrom(STRATEGY, address(locker), id);
        assertEq(positions.ownerOf(id), STRATEGY);
        _register(id);
        vm.expectRevert();
        locker.onERC721Received(STRATEGY, STRATEGY, id, "");
        vm.expectRevert();
        vm.prank(address(positions));
        locker.onERC721Received(STRATEGY, STRATEGY, id, "");
        address outsider = address(0xBAD);
        vm.prank(STRATEGY);
        positions.transferFrom(STRATEGY, outsider, id);
        vm.expectRevert();
        vm.prank(outsider);
        positions.safeTransferFrom(outsider, address(locker), id);
        assertEq(positions.ownerOf(id), outsider);
        vm.prank(outsider);
        positions.transferFrom(outsider, STRATEGY, id);
        vm.prank(STRATEGY);
        positions.safeTransferFrom(STRATEGY, address(locker), id);
        assertTrue(locker.locked(id));
        vm.expectRevert();
        vm.prank(address(positions));
        locker.onERC721Received(STRATEGY, STRATEGY, id, "");
        uint256 extra = _mint(key, STRATEGY, 1e20);
        vm.expectRevert();
        vm.prank(STRATEGY);
        positions.safeTransferFrom(STRATEGY, address(locker), extra);
        assertEq(positions.ownerOf(extra), STRATEGY);
    }

    function testAuthenticPositionMustMatchRegisteredPool() public {
        uint256 id = _mint(key, STRATEGY, 1e20);
        vm.prank(FACTORY);
        locker.registerPosition(bytes32(uint256(0xDEAD)), id, STRATEGY);
        vm.expectRevert();
        vm.prank(STRATEGY);
        positions.safeTransferFrom(STRATEGY, address(locker), id);
        assertEq(positions.ownerOf(id), STRATEGY);
        assertFalse(locker.locked(id));
    }

    function testAuthenticPositionWithWithdrawnLiquidityIsRejected() public {
        uint256 id = _mint(key, STRATEGY, 1e20);
        _register(id);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(id, uint256(1e20), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, STRATEGY);
        vm.prank(STRATEGY);
        positions.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params),
            block.timestamp
        );
        assertEq(positions.getPositionLiquidity(id), 0);
        vm.expectRevert();
        vm.prank(STRATEGY);
        positions.safeTransferFrom(STRATEGY, address(locker), id);
        assertEq(positions.ownerOf(id), STRATEGY);
        assertFalse(locker.locked(id));
    }

    function testFuzzNoCallerCanTransferApproveOrModifyLockedPosition(address caller) public {
        vm.assume(caller != address(locker) && caller != address(0));
        uint256 id = _mint(key, STRATEGY, 1e20);
        _register(id);
        vm.startPrank(STRATEGY);
        positions.approve(caller, id);
        positions.safeTransferFrom(STRATEGY, address(locker), id);
        vm.stopPrank();
        assertEq(positions.getApproved(id), address(0));
        vm.startPrank(caller);
        vm.expectRevert();
        positions.transferFrom(address(locker), caller, id);
        vm.expectRevert();
        positions.approve(caller, id);
        uint8[3] memory actions =
            [uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.BURN_POSITION)];
        for (uint256 i; i < actions.length; ++i) {
            bytes[] memory params = new bytes[](1);
            params[0] = i == 2
                ? abi.encode(id, uint128(0), uint128(0), bytes(""))
                : abi.encode(id, uint256(1), uint128(0), uint128(0), bytes(""));
            vm.expectRevert();
            positions.modifyLiquidities(abi.encode(abi.encodePacked(actions[i]), params), block.timestamp);
        }
        vm.stopPrank();
        assertEq(positions.ownerOf(id), address(locker));
        assertEq(positions.getPositionLiquidity(id), 1e20);
    }

    function testLockerHasNoWithdrawalApprovalAdministrativeOrLiquidityEntryPoints() public {
        uint256 id = _mint(key, STRATEGY, 1e20);
        _register(id);
        vm.prank(STRATEGY);
        positions.safeTransferFrom(STRATEGY, address(locker), id);
        bytes[] memory forbidden = new bytes[](9);
        forbidden[0] = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(locker), FACTORY, id);
        forbidden[1] = abi.encodeWithSignature("approve(address,uint256)", FACTORY, id);
        forbidden[2] = abi.encodeWithSignature("setApprovalForAll(address,bool)", FACTORY, true);
        forbidden[3] = abi.encodeWithSignature("withdraw(uint256)", id);
        forbidden[4] = abi.encodeWithSignature("removeLiquidity(uint256,uint256)", id, uint256(1));
        forbidden[5] = abi.encodeWithSignature("upgradeTo(address)", FACTORY);
        forbidden[6] = abi.encodeWithSignature("setFactory(address)", FACTORY);
        forbidden[7] = abi.encodeWithSignature("collectFees(uint256[])", new uint256[](1));
        forbidden[8] = abi.encodeWithSignature(
            "increaseLiquidity(uint256,uint256,uint128,uint128,bytes)",
            id,
            uint256(1),
            uint128(0),
            uint128(0),
            bytes("")
        );
        for (uint256 i; i < forbidden.length; ++i) {
            vm.prank(FACTORY);
            (bool success,) = address(locker).call(forbidden[i]);
            assertFalse(success);
        }
        assertEq(positions.ownerOf(id), address(locker));
        assertEq(positions.getPositionLiquidity(id), 1e20);
    }
}
