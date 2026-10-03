// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IV3SwapRouter} from "../../../src/v3/stock/interfaces/IV3SwapRouter.sol";

/// TESTNET ONLY (Solon V3 drill, 2026-10-01). Every contract here is a named mock standing in for an external
/// dependency that does not exist on the testnets: Robinhood stock tokens, Chainlink equity feeds (none on the RH
/// testnet), the RH stock/USDG Uniswap V3 pools (TWAP) and router, and SOLON + its legacy fee router on Arc.
/// Owner-controlled prices make stale / jump / closed-market / TWAP-divergence scenarios reproducible.

/// @notice Mock stock token ("Mock NVDA (Solon testnet)"): 18 dp, minted by its owner (seeding) or the mock router.
contract TestnetMockStock is ERC20 {
    address public immutable owner;
    address public minter;
    uint256 public uiMultiplier = 1e18; // branch A feeds include it; reported only

    constructor(string memory n, string memory s, address owner_) ERC20(n, s) {
        owner = owner_;
    }

    function setMinter(address m) external {
        require(msg.sender == owner && minter == address(0), "minter");
        minter = m;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner || msg.sender == minter, "mint");
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @notice Mock Chainlink AggregatorV3 for an equity (8 dp) or USDG/USD. Emits the OCR `AnswerUpdated` the oracle
///         keeper subscribes to. `setPrice` = a fresh round now; `setRound` = any updatedAt (stale / closed market).
contract TestnetMockFeed {
    uint8 public constant decimals = 8;
    string public description;
    address public immutable owner;
    uint80 public roundId;
    int256 public answer;
    uint256 public updatedAt;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event NewRound(uint256 indexed roundId, address indexed startedBy, uint256 startedAt);

    constructor(string memory d, address owner_, int256 initial) {
        description = d;
        owner = owner_;
        _set(initial, block.timestamp);
    }

    function setPrice(int256 a) external {
        require(msg.sender == owner, "owner");
        _set(a, block.timestamp);
    }

    function setRound(int256 a, uint256 at) external {
        require(msg.sender == owner && at <= block.timestamp, "owner/at");
        _set(a, at);
    }

    function _set(int256 a, uint256 at) private {
        roundId++;
        answer = a;
        updatedAt = at;
        emit NewRound(roundId, msg.sender, at);
        emit AnswerUpdated(a, roundId, at);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }

    function latestAnswer() external view returns (int256) {
        return answer;
    }
}

/// @notice Mock RH stock/USDG Uniswap V3 pool for the ChainlinkStockSource TWAP cross-check. By default its mean tick
///         follows the mock feed (TWAP == Chainlink); `setTickOverride` forces a divergence. Emits nothing (no swaps).
contract TestnetMockTwapPool {
    address public immutable token0;
    address public immutable token1;
    address public immutable stock;
    TestnetMockFeed public immutable feed;
    address public immutable owner;
    uint8 public immutable stableDecimals;
    bool public overridden;
    int24 public tickOverride;

    constructor(address stock_, address stable_, uint8 stableDecimals_, TestnetMockFeed feed_, address owner_) {
        (token0, token1) = stock_ < stable_ ? (stock_, stable_) : (stable_, stock_);
        stock = stock_;
        stableDecimals = stableDecimals_;
        feed = feed_;
        owner = owner_;
    }

    function setTickOverride(bool on, int24 t) external {
        require(msg.sender == owner, "owner");
        overridden = on;
        tickOverride = t;
    }

    /// @notice Pool tick of the feed price: stable raw per 1e18 raw stock = answer(8dp) * 10^stableDecimals / 1e8.
    function feedTick() public view returns (int24) {
        uint256 a = uint256(feed.answer());
        // ratio token1/token0 in raw units, as sqrtPriceX96 = sqrt(ratio * 2^192)
        uint256 num = a * 10 ** stableDecimals; // stable raw per 1e18 stock raw, times 1e8
        uint256 sq;
        if (token0 == stock) {
            sq = Math.sqrt(Math.mulDiv(num, 1 << 192, 1e26)); // / (1e8 * 1e18)
        } else {
            sq = Math.sqrt(Math.mulDiv(1e26, 1 << 192, num));
        }
        return TickMath.getTickAtSqrtPrice(uint160(sq));
    }

    function observe(uint32[] calldata ago) external view returns (int56[] memory c, uint160[] memory l) {
        int24 t = overridden ? tickOverride : feedTick();
        c = new int56[](ago.length);
        l = new uint160[](ago.length);
        for (uint256 i; i < ago.length; ++i) {
            c[i] = int56(t) * -int56(uint56(ago[i])) + 1_000_000_000;
        }
    }
}

/// @notice Mock RH Uniswap V3 SwapRouter behind RestrictedVenue: fills at the mock feed price (less the pool fee) by
///         minting / burning the mock stock; USDG paid for sells comes from the USDG it received for buys plus any
///         inventory the owner sends. `setHalted` simulates a venue failure (RestrictedVenue -> Failed result).
contract TestnetMockStockRouter is IV3SwapRouter {
    IERC20 public immutable usdg;
    address public immutable owner;
    mapping(address stock => TestnetMockFeed) public feedOf;
    mapping(address stock => bool) public halted;

    event MockFill(address indexed stock, bool buy, uint256 amountIn, uint256 amountOut, int256 price8);

    constructor(IERC20 usdg_, address owner_) {
        usdg = usdg_;
        owner = owner_;
    }

    function setFeed(address stock, TestnetMockFeed feed) external {
        require(msg.sender == owner, "owner");
        feedOf[stock] = feed;
    }

    function setHalted(address stock, bool h) external {
        require(msg.sender == owner, "owner");
        halted[stock] = h;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        bool buy = p.tokenIn == address(usdg);
        address stock = buy ? p.tokenOut : p.tokenIn;
        TestnetMockFeed f = feedOf[stock];
        require(address(f) != address(0) && !halted[stock], "mock venue: halted/unknown");
        int256 a = f.answer();
        require(a > 0, "mock venue: price");
        uint256 net = p.amountIn - p.amountIn * p.fee / 1e6;
        if (buy) {
            require(usdg.transferFrom(msg.sender, address(this), p.amountIn), "pull usdg");
            out = net * 1e12 * 1e8 / uint256(a); // USDG 6 dp -> 18 dp shares at answer (8 dp)
            TestnetMockStock(stock).mint(p.recipient, out);
        } else {
            require(IERC20(stock).transferFrom(msg.sender, address(this), p.amountIn), "pull stock");
            TestnetMockStock(stock).burn(p.amountIn);
            out = net * uint256(a) / 1e8 / 1e12;
            require(usdg.transfer(p.recipient, out), "pay usdg");
        }
        require(out >= p.amountOutMinimum, "Too little received");
        emit MockFill(stock, buy, p.amountIn, out, a);
    }
}

/// @notice Mock SOLON on Arc testnet (the real SOLON lives on Arc mainnet only).
contract TestnetMockSolon is ERC20 {
    constructor(address to) ERC20("Mock SOLON (Solon testnet)", "mSOLON") {
        _mint(to, 1_000_000_000e18);
    }
}

/// @notice Mock of the legacy SolonFeeRouter (buyback route target). Not exercised in the drill: any call reverts.
contract TestnetMockSolonFeeRouter {
    fallback() external payable {
        revert("testnet mock fee router");
    }
}

/// @notice r13 (path 2a) testnet stand-in for the Relay depository v2 (Relay supports neither Arc testnet nor the RH
///         stand-in). Same entry points and events as relay-depository's RelayDepository (depositNative /
///         depositErc20 with a bytes32 id), and like it, it KEEPS the deposit (RelayFundingRoute checks the depository's
///         balance increase). The mock Relay operator (keepers/v3/testnet/mock-relay.mjs, owner) watches the events, pays
///         the other chain from its own balance as a plain transfer (a Relay fill without txs) and sweeps deposits back.
contract TestnetMockRelayDepository {
    address public immutable owner;

    event RelayNativeDeposit(address from, uint256 amount, bytes32 id);
    event RelayErc20Deposit(address from, address token, uint256 amount, bytes32 id);

    constructor(address owner_) {
        owner = owner_;
    }

    function depositNative(address depositor, bytes32 id) external payable {
        emit RelayNativeDeposit(depositor, msg.value, id);
    }

    function depositErc20(address depositor, address token, uint256 amount, bytes32 id) external {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit RelayErc20Deposit(depositor, token, amount, id);
    }

    function sweep(address token, address to, uint256 amount) external {
        require(msg.sender == owner, "owner");
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "native");
        } else {
            require(IERC20(token).transfer(to, amount), "erc20");
        }
    }
}

/// @notice r13 testnet stand-in for relay-periphery RelayRouter.multicall (permissionless, as on mainnet: N3). It is the
///         Arc route's return executor so the refund keeper's float credit (router.multicall -> receiveReturnFor) runs on
///         testnet exactly like on mainnet. Leftover native goes to `refundTo`.
contract TestnetMockRelayRouter {
    struct Call3Value {
        address target;
        bool allowFailure;
        uint256 value;
        bytes callData;
    }

    function multicall(Call3Value[] calldata calls, address refundTo, address, bytes calldata)
        external
        payable
        returns (bytes[] memory out)
    {
        out = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].target.call{value: calls[i].value}(calls[i].callData);
            if (!ok && !calls[i].allowFailure) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            out[i] = ret;
        }
        if (address(this).balance != 0 && refundTo != address(0)) {
            (bool ok,) = refundTo.call{value: address(this).balance}("");
            require(ok, "refund");
        }
    }
}
