// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Local-anvil stand-ins for the phase-five pieces the keepers drive. Test fixture only —
// never deployment parameters. The real phase 1-4 contracts are deployed from src/v3.
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract KeeperMockStock is ERC20 {
    constructor() ERC20("Mock NVDA.sol", "mNVDA") {}

    function mint(address to, uint256 n) external {
        _mint(to, n);
    }
}

/// @dev ISolonFundingHub stand-in. `bridge` plays the Relay solver (USDG arrival on RH)
/// and the RH executor/LZ result. Nothing here verifies proofs; it is a fixture.
contract KeeperMockFundingHub {
    KeeperMockStock public immutable stock;
    address public immutable bridge;
    struct Order {
        uint256 budget;
        uint256 value;
        uint256 minRaw;
        address adapter;
        uint256 received;
        bool submitted;
        uint8 status;
        uint256 raw;
        bool cancelRequested;
    }
    mapping(bytes32 => Order) public orders;
    event FundingBegun(bytes32 indexed orderId, uint256 budget, uint256 value);
    event FundingArrived(bytes32 indexed orderId, uint256 amount);
    event BuySubmitted(bytes32 indexed orderId);

    constructor(KeeperMockStock s, address bridge_) {
        stock = s;
        bridge = bridge_;
    }

    function beginFunding(bytes32 orderId, address, uint256 budget18, uint256 minRawOut, address, bytes32)
        external
        payable
    {
        require(orders[orderId].adapter == address(0), "dup");
        orders[orderId] = Order(budget18, msg.value, minRawOut, msg.sender, 0, false, 0, 0, false);
        emit FundingBegun(orderId, budget18, msg.value);
    }

    // SolonStockHub views for the keeper cost model (25 bps buy fee, flat LZ order fee).
    function fees() external pure returns (uint16, uint16, uint16) {
        return (25, 25, 0);
    }

    function quoteOrder(address) external pure returns (uint256) {
        return 0.05 ether;
    }

    function mockArrive(bytes32 orderId, uint256 amount) external {
        require(msg.sender == bridge && orders[orderId].adapter != address(0), "bridge");
        orders[orderId].received += amount;
        emit FundingArrived(orderId, amount);
    }

    function mockSettle(bytes32 orderId, uint8 status, uint256 raw) external {
        require(msg.sender == bridge, "bridge");
        orders[orderId].status = status;
        orders[orderId].raw = raw;
    }

    function fundingReceived(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].received;
    }

    function submitFundedBuy(bytes32 orderId) external {
        require(msg.sender == orders[orderId].adapter, "adapter");
        orders[orderId].submitted = true;
        emit BuySubmitted(orderId);
    }

    function requestCancel(bytes32 orderId) external {
        require(msg.sender == orders[orderId].adapter, "adapter");
        orders[orderId].cancelRequested = true;
    }

    function claimResult(bytes32 orderId, bytes calldata) external returns (uint8, uint256, uint256) {
        Order storage o = orders[orderId];
        require(msg.sender == o.adapter, "adapter");
        if (o.status == 1) {
            o.status = 9;
            stock.mint(msg.sender, o.raw);
            return (1, o.raw, 0);
        }
        if (o.status == 2) {
            o.status = 9;
            (bool ok,) = payable(msg.sender).call{value: o.budget}("");
            require(ok);
            return (2, 0, o.budget);
        }
        return (0, 0, 0);
    }
}

contract KeeperMockCapacity {
    mapping(bytes32 => uint256) public reserved;

    /// @dev r11: CapacityController only has the asset-carrying entry (RoundManager calls `reserveFor`).
    function reserveFor(bytes32 orderId, address, uint256 budget18) external {
        reserved[orderId] = budget18;
    }

    mapping(bytes32 => bool) public finalized;

    function releaseUnsent(bytes32 orderId) external {
        delete reserved[orderId];
    }

    /// @dev Since 03d87c2 RewardRoundManager releases capacity on Settled/Refunded too.
    function releaseFinalized(bytes32 orderId) external {
        delete reserved[orderId];
        finalized[orderId] = true;
    }

    /// @dev CapacityController.lRun default since 2026-09-30 (RoundManager.runLimit reads it).
    function lRun() external pure returns (uint256) {
        return 10_000 ether;
    }
}

contract KeeperMockOracle {
    mapping(address => uint256) public price;

    function setPrice(address asset, uint256 p) external {
        price[asset] = p;
    }

    function priceUSD18(address asset) external view returns (uint256, uint256) {
        return (price[asset], block.timestamp);
    }

    // SolonStockOracle surface used by SolonStockAdapter (r7 floor) and the keepers' market gate.
    function rawFor(address asset, uint256 usd18) external view returns (uint256) {
        return usd18 * 1e18 / price[asset];
    }

    struct Observation {
        uint256 price18;
        uint256 multiplier;
        uint256 quoteUsd18;
        uint256 twapPrice18;
        uint64 sourceUpdatedAt;
        uint80 roundId;
        uint64 observedAt;
        uint64 sourceBlock;
    }

    function latest(address asset) external view returns (Observation memory o, uint8 s) {
        o.price18 = price[asset];
        o.sourceUpdatedAt = uint64(block.timestamp);
        o.observedAt = uint64(block.timestamp);
        s = 1;
    }

    struct Params {
        uint32 maxAge;
        uint16 maxMoveBps;
        uint16 confirmBps;
        uint16 maxDepegBps;
        uint32 maxSourceAge;
        uint16 maxTwapBps;
    }

    struct Asset {
        address token;
        address source;
        Params params;
        bool paused;
    }

    // SolonStockOracle.assetOf: the keepers read the on-chain maxAge (mainnet 15 min) instead of a constant.
    function assetOf(address asset) external pure returns (Asset memory a) {
        a.token = asset;
        a.params = Params(900, 1000, 200, 50, 93600, 0);
    }
}

contract KeeperMockBucket {
    function onFeeCredit(bytes32, address, uint8, uint256) external {}
    receive() external payable {}
}

interface IKeeperPayoutRegistration {
    function registerSource(address source) external;
}

/// @dev RewardPayoutVault.configureFactory requires a contract; this fixture relays registerSource.
contract KeeperMockFactory {
    function registerPayoutSource(address payout, address source) external {
        IKeeperPayoutRegistration(payout).registerSource(source);
    }
}
