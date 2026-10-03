// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice InstantLaunchStrategy single-position settlement with permanent custody.
/// @dev No arbitrary actions, approvals or withdrawals. Minted supply is the only input.
contract V3LaunchStrategy is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable factory;
    IPositionManager public immutable positionManager;
    mapping(bytes32 => bytes32) public initialPositionContext;
    error Unauthorized();
    error InvalidQuote();

    constructor(address f, IPositionManager p) {
        require(f != address(0) && address(p).code.length != 0);
        factory = f;
        positionManager = p;
    }

    function initialize(
        PoolKey calldata key,
        uint160 price,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        address token,
        address locker
    ) external nonReentrant returns (uint256 dust) {
        if (msg.sender != factory) revert Unauthorized();
        uint256 id = positionManager.nextTokenId();
        bytes32 pool = PoolId.unwrap(key.toId());
        initialPositionContext[pool] =
            keccak256(abi.encode(ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(id))));
        positionManager.poolManager().initialize(key, price);
        IERC20(token).safeTransfer(address(positionManager), 1_000_000_000 ether);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        bool token0 = Currency.unwrap(key.currency0) == token;
        params[0] = abi.encode(
            key,
            lower,
            upper,
            uint256(liquidity),
            uint128(token0 ? 1e27 : 0),
            uint128(token0 ? 0 : 1e27),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(Currency.wrap(token), ActionConstants.OPEN_DELTA, false);
        params[2] = abi.encode(Currency.wrap(token), address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        delete initialPositionContext[pool];
        dust = IERC20(token).balanceOf(address(this));
        if (dust != 0) IERC20(token).safeTransfer(address(0xdead), dust);
        IERC721(address(positionManager)).safeTransferFrom(address(this), locker, id);
    }

    /// @dev TickMath binary search avoids floating point and rounds meme USD price down.
    function stockTick(uint256 priceUsd18) external pure returns (int24) {
        uint160 base = TickMath.getSqrtPriceAtTick(123800);
        uint256 target = FullMath.mulDiv(FullMath.mulDiv(base, base, 1 << 64), priceUsd18, 1e18);
        if (target == 0) revert InvalidQuote();
        int24 lo = TickMath.MIN_TICK;
        int24 hi = TickMath.MAX_TICK;
        while (lo < hi) {
            int24 mid = int24(int256(lo) + (int256(hi) - lo) / 2);
            uint160 root = TickMath.getSqrtPriceAtTick(mid);
            if (FullMath.mulDiv(root, root, 1 << 64) >= target) hi = mid;
            else lo = mid + 1;
        }
        int24 aligned = (lo / 100) * 100;
        if (aligned < lo) aligned += 100;
        if (aligned > 887200 || aligned < -603300) revert InvalidQuote();
        return aligned;
    }
}
