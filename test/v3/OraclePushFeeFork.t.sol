// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Script, console2} from "forge-std/Script.sol";
import {IAggregatorV3} from "../../src/v3/oracle/ChainlinkStockFeed.sol";
import {ChainlinkStockSource} from "../../src/v3/oracle/ChainlinkStockSource.sol";
import {StockPriceSender} from "../../src/v3/oracle/StockPriceSender.sol";

/// Shared RH mainnet (4663) addresses for the r8 oracle-push fee measurement (docs/ORACLE-PUSH-r8.md).
/// Feeds / pools as in StockOracleFork.t.sol and DeployV3PriceSender; ETH/USD proxy from the Chainlink reference
/// directory feeds-robinhood-mainnet.json ("ETH / USD", 8 dp), re-checked on chain (description, aggregator).
library RhOraclePush {
    address constant LZ_ENDPOINT = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B; // eid() == 30416
    uint32 constant RH_EID = 30416;
    uint32 constant ARC_EID = 30417;
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address constant NVDA_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address constant AAPL_POOL = 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D;
    address constant TSLA_POOL = 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3;

    /// Same construction as DeployV3PriceSender (branch A, 30-min TWAP, 4d / 26h staleness, 300k lzReceive gas).
    function deploy(address owner) internal returns (ChainlinkStockSource src, StockPriceSender sender) {
        ChainlinkStockSource.FeedInit[] memory init = new ChainlinkStockSource.FeedInit[](3);
        init[0] = ChainlinkStockSource.FeedInit(NVDA, NVDA_FEED, true, NVDA, NVDA_POOL, 30 minutes);
        init[1] = ChainlinkStockSource.FeedInit(AAPL, AAPL_FEED, true, AAPL, AAPL_POOL, 30 minutes);
        init[2] = ChainlinkStockSource.FeedInit(TSLA, TSLA_FEED, true, TSLA, TSLA_POOL, 30 minutes);
        src = new ChainlinkStockSource(owner, USDG_FEED, 4 days, 26 hours, init);
        bytes memory options = abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(300_000));
        sender = new StockPriceSender(LZ_ENDPOINT, owner, src, ARC_EID, options);
        // Placeholder Arc peer (any non-zero bytes32: the fee does not depend on it). DVNs: see setDvns (the RH
        // default for eid 30417 is LZDeadDVN; V3LzConfig's own DVN list is still a TODO-verify placeholder).
        sender.setPeer(ARC_EID, bytes32(uint256(0xA2C)));
    }

    // LayerZero metadata API /v1/metadata/dvns, key "robinhood" (fetched 2026-10-01): the endpoint's default DVN for
    // eid 30417 is LZDeadDVN 0x6788…E842, so an explicit DVN set is mandatory. Same shape as V3LzConfig.defaults:
    // 1 required (LayerZero Labs) + 2 optional (Nethermind, Horizen), threshold 1 => 2 signatures out of 3 DVNs.
    address constant SEND_LIB = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7; // endpoint.defaultSendLibrary(30417)
    address constant DVN_LZ_LABS = 0xd01ae6905d48315f7bE10C7330aeCF8360Ef5b12;
    address constant DVN_NETHERMIND = 0x0Ffe02DF012299A370D5dd69298A5826EAcaFdF8;
    address constant DVN_HORIZEN = 0x1258A278519c7f4bd997a9c3BFd4Aa802a028D89;

    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    struct SetConfigParam {
        uint32 eid;
        uint32 configType;
        bytes config;
    }

    /// `optional` == 0: LayerZero Labs only (1-of-1, lower bound); otherwise 1 required + 2 optional, threshold 1.
    function setDvns(address oapp, bool withOptional) internal {
        UlnConfig memory c;
        c.confirmations = 20; // DeployV3PriceSender RH_CONFIRMATIONS default
        c.requiredDVNCount = 1;
        c.requiredDVNs = new address[](1);
        c.requiredDVNs[0] = DVN_LZ_LABS;
        if (withOptional) {
            c.optionalDVNCount = 2;
            c.optionalDVNThreshold = 1;
            c.optionalDVNs = new address[](2);
            (c.optionalDVNs[0], c.optionalDVNs[1]) = (DVN_NETHERMIND, DVN_HORIZEN); // ascending
        }
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] = SetConfigParam(ARC_EID, 2, abi.encode(c));
        IEndpointSetConfig(LZ_ENDPOINT).setConfig(oapp, SEND_LIB, p);
    }

    function all() internal pure returns (address[] memory u) {
        u = new address[](3);
        (u[0], u[1], u[2]) = (NVDA, AAPL, TSLA);
    }

    function one() internal pure returns (address[] memory u) {
        u = new address[](1);
        u[0] = NVDA;
    }
}

/// FORK: LayerZero fee and gas of one StockPriceSender.poke on Robinhood Chain mainnet. Skipped unless RH_RPC_URL is
/// set (the default suite stays offline). Optional RH_FORK_BLOCK pins the block.
contract OraclePushFeeForkTest is Test {
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blk = vm.envOr("RH_FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
        forked = true;
    }

    function testPokeFeeAndGas() public {
        vm.skip(!forked, "RH_RPC_URL not set");
        (, StockPriceSender sender) = RhOraclePush.deploy(address(this));
        RhOraclePush.setDvns(address(sender), false);
        uint256 lzOnly3 = sender.quote(RhOraclePush.all());
        RhOraclePush.setDvns(address(sender), true);
        assertEq(IEid(RhOraclePush.LZ_ENDPOINT).eid(), RhOraclePush.RH_EID, "RH LayerZero endpoint eid");
        (, int256 ethUsd,, uint256 ethAt,) = IAggregatorV3(RhOraclePush.ETH_USD).latestRoundData();
        emit log_named_uint("fork block", block.number);
        emit log_named_uint("fork timestamp", block.timestamp);
        emit log_named_uint("basefee (wei)", block.basefee);
        emit log_named_decimal_int("ETH/USD (Chainlink RH)", ethUsd, 8);
        emit log_named_uint("ETH/USD updatedAt", ethAt);

        address[] memory u1 = RhOraclePush.one();
        address[] memory u3 = RhOraclePush.all();
        (bytes memory p1,) = sender.collect(u1);
        (bytes memory p3, uint256 n3) = sender.collect(u3);
        uint256 fee1 = sender.quote(u1);
        uint256 fee3 = sender.quote(u3);
        emit log_named_uint("payload bytes 1 stock", p1.length);
        emit log_named_uint("payload bytes 3 stocks", p3.length);
        emit log_named_uint("stocks readable", n3);
        emit log_named_decimal_uint("LZ fee 1 stock (ETH)", fee1, 18);
        emit log_named_decimal_uint("LZ fee 3 stocks (ETH)", fee3, 18);
        emit log_named_decimal_uint("LZ fee 3 stocks, LayerZero Labs DVN only (ETH)", lzOnly3, 18);
        emit log_named_decimal_uint("LZ fee 1 stock (USD)", fee1 * uint256(ethUsd) / 1e8, 18);
        emit log_named_decimal_uint("LZ fee 3 stocks (USD)", fee3 * uint256(ethUsd) / 1e8, 18);
        assertGt(fee3, 0);

        vm.deal(address(this), 1 ether);
        uint256 g = gasleft();
        sender.poke{value: fee1}(u1);
        emit log_named_uint("poke 1 stock execution gas (excl. intrinsic/calldata)", g - gasleft());
        g = gasleft();
        sender.poke{value: fee3}(u3);
        emit log_named_uint("poke 3 stocks execution gas (excl. intrinsic/calldata)", g - gasleft());
    }

    receive() external payable {}
}

interface IEid {
    function eid() external view returns (uint32);
}

interface IEndpointSetConfig {
    function setConfig(address oapp, address lib, RhOraclePush.SetConfigParam[] calldata params) external;
}

/// Deploys the pair to a LOCAL anvil fork of RH (never a live chain) so `cast send poke` yields a real receipt:
///   forge script test/v3/OraclePushFeeFork.t.sol:OraclePushFeeAnvil --rpc-url http://127.0.0.1:8545 --broadcast
/// (env ANVIL_KEY = an anvil dev account key). Refuses to run unless the RPC's chainid is 4663 and the block is
/// served by anvil (anvil_nodeInfo is not checked from Solidity: the operator passes the local URL).
contract OraclePushFeeAnvil is Script {
    function run() external {
        require(block.chainid == 4663, "expects an RH fork");
        uint256 pk = vm.envUint("ANVIL_KEY");
        vm.startBroadcast(pk);
        (ChainlinkStockSource src, StockPriceSender sender) = RhOraclePush.deploy(vm.addr(pk));
        RhOraclePush.setDvns(address(sender), true);
        vm.stopBroadcast();
        console2.log("ChainlinkStockSource", address(src));
        console2.log("StockPriceSender", address(sender));
    }
}
