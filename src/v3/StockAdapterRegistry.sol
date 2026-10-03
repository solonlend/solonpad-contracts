// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Append-only routes. Governance is the external timelock, never a keeper.
contract StockAdapterRegistry {
    struct Route {
        address asset;
        address underlying;
        address hub;
        address adapter;
        bytes32 path;
        uint256 chainId;
        bool enabled;
        uint256 fixedCost18;
    }
    address public immutable governance;
    mapping(bytes32 => mapping(uint32 => Route)) private routes;
    error InvalidRoute();
    event RouteRegistered(bytes32 indexed assetId, uint32 indexed version, address adapter, bytes32 path);

    constructor(address governance_) {
        require(governance_ != address(0));
        governance = governance_;
    }

    function register(bytes32 assetId, uint32 version, Route calldata r) external {
        if (
            msg.sender != governance || assetId == 0 || version == 0 || routes[assetId][version].asset != address(0)
                || r.asset.code.length == 0 || r.underlying == address(0) || r.hub.code.length == 0
                || r.adapter.code.length == 0 || r.path == 0 || r.chainId == 0
        ) revert InvalidRoute();
        routes[assetId][version] = r;
        emit RouteRegistered(assetId, version, r.adapter, r.path);
    }

    function resolve(bytes32 assetId, uint32 version) external view returns (Route memory) {
        return routes[assetId][version];
    }
}
