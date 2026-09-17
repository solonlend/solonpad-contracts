// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchToken} from "./LaunchToken.sol";
import {CurvePool} from "./CurvePool.sol";

/// @title LaunchpadFactory
/// @notice Pons-style launchpad for Circle's Arc chain. One transaction deploys
///         a fixed-supply token plus its locked bonding-curve pool, quoted in
///         Arc's native USDC. Parameter changes only affect FUTURE launches —
///         every live pool's economics are immutable, so the owner cannot rug
///         existing tokens.
contract LaunchpadFactory {
    address public owner;
    address public treasury;

    // launch-time parameters (18-dec native USDC units)
    uint256 public launchFee = 1e18; // 1 USDC to create a token
    uint256 public virtualUsdc = 6_000e18; // bootstrap reserve → initial FDV ≈ $6k
    uint256 public graduationReserve = 20_000e18; // real USDC that triggers graduation
    uint16 public feeBps = 100; // 1% per trade
    uint16 public creatorShareBps = 5_000; // creator gets 50% of trade fees

    uint256 public pendingLaunchFees; // accrued launch fees, pull-claimed by treasury

    address[] public allTokens;
    mapping(address token => address pool) public poolOf;

    event TokenLaunched(
        address indexed token,
        address indexed pool,
        address indexed creator,
        string name,
        string symbol,
        string metadataURI
    );
    event ParamsUpdated(
        uint256 launchFee, uint256 virtualUsdc, uint256 graduationReserve, uint16 feeBps, uint16 creatorShareBps
    );
    event TreasuryUpdated(address treasury);
    event OwnershipTransferred(address indexed from, address indexed to);
    event LaunchFeesCollected(address indexed treasury, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    constructor(address treasury_) {
        require(treasury_ != address(0), "treasury zero");
        owner = msg.sender;
        treasury = treasury_;
    }

    /// @notice Launch a token: deploys the pool and the token, mints the full
    ///         1B supply into the pool, and opens trading — all in one tx.
    function createToken(string calldata name, string calldata symbol, string calldata metadataURI)
        external
        payable
        returns (address token, address pool)
    {
        require(msg.value == launchFee, "wrong launch fee");
        pendingLaunchFees += msg.value;

        CurvePool p = new CurvePool(msg.sender, virtualUsdc, graduationReserve, feeBps, creatorShareBps);
        LaunchToken t = new LaunchToken(name, symbol, metadataURI, address(p));
        p.initialize(address(t));

        token = address(t);
        pool = address(p);
        poolOf[token] = pool;
        allTokens.push(token);
        emit TokenLaunched(token, pool, msg.sender, name, symbol, metadataURI);
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    // ---- admin ----

    function collectLaunchFees() external {
        require(msg.sender == treasury, "only treasury");
        uint256 amount = pendingLaunchFees;
        require(amount > 0, "nothing to collect");
        pendingLaunchFees = 0;
        (bool ok,) = treasury.call{value: amount}("");
        require(ok, "send failed");
        emit LaunchFeesCollected(treasury, amount);
    }

    function setParams(
        uint256 launchFee_,
        uint256 virtualUsdc_,
        uint256 graduationReserve_,
        uint16 feeBps_,
        uint16 creatorShareBps_
    ) external onlyOwner {
        require(virtualUsdc_ > 0, "virtual reserve = 0");
        require(feeBps_ <= 1000, "fee > 10%");
        require(creatorShareBps_ <= 10_000, "creator share > 100%");
        launchFee = launchFee_;
        virtualUsdc = virtualUsdc_;
        graduationReserve = graduationReserve_;
        feeBps = feeBps_;
        creatorShareBps = creatorShareBps_;
        emit ParamsUpdated(launchFee_, virtualUsdc_, graduationReserve_, feeBps_, creatorShareBps_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        require(treasury_ != address(0), "treasury zero");
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "owner zero");
        owner = newOwner;
        emit OwnershipTransferred(msg.sender, newOwner);
    }
}
