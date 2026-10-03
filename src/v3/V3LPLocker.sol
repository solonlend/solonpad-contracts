// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice Immutable custody for each registered launch's sole initial v4 LP NFT.
/// @dev Adapted from liquidity-launcher FeeSplitter's perpetual custody. Fee collection
/// and increases are deliberately absent: v3 uses fee=0 and forbids additional LP.
/// There is no owner, arbitrary call, approval, withdrawal, or upgrade authority.
/// As with any ERC721 receiver, unsafe transferFrom can force foreign NFTs here;
/// such unsolicited tokens never become registered or acknowledged locked positions.
contract V3LPLocker {
    error Unauthorized();
    error InvalidPosition();
    error InvalidRegistration();
    error AlreadyRegistered();
    address public immutable factory;
    IPositionManager public immutable positionManager;
    mapping(bytes32 => uint256) public positionOfPool;
    mapping(uint256 => bytes32) public poolOfPosition;
    mapping(uint256 => address) public strategyOfPosition;
    mapping(uint256 => bool) public locked;

    constructor(address factory_, IPositionManager positionManager_) {
        factory = factory_;
        positionManager = positionManager_;
    }

    /// @notice The fixed factory reserves an expected position before the launch mint.
    /// @dev Factory and hook authenticate ticks and initial mint context; the receiver
    /// verifies the actual complete PoolKey and nonzero position liquidity below.
    function registerPosition(bytes32 poolId, uint256 tokenId, address strategy) external {
        if (msg.sender != factory) revert Unauthorized();
        if (poolId == bytes32(0) || tokenId == 0 || strategy == address(0)) revert InvalidRegistration();
        if (positionOfPool[poolId] != 0 || strategyOfPosition[tokenId] != address(0)) revert AlreadyRegistered();
        positionOfPool[poolId] = tokenId;
        poolOfPosition[tokenId] = poolId;
        strategyOfPosition[tokenId] = strategy;
    }

    /// @notice Accept only the expected canonical position transferred by its strategy.
    /// @dev ERC721 transfers clear token approvals. This contract never grants new ones.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(positionManager)) revert Unauthorized();
        if (strategyOfPosition[tokenId] == address(0) || from != strategyOfPosition[tokenId] || locked[tokenId]) {
            revert InvalidPosition();
        }
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) revert InvalidPosition();
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);
        if (PoolId.unwrap(key.toId()) != poolOfPosition[tokenId] || positionManager.getPositionLiquidity(tokenId) == 0)
        {
            revert InvalidPosition();
        }
        locked[tokenId] = true;
        return this.onERC721Received.selector;
    }
}
