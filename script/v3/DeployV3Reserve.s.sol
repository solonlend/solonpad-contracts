// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Script, console2} from "forge-std/Script.sol";
import {ReserveVault} from "../../src/v3/stock/robinhood/ReserveVault.sol";
import {RestrictedVenue} from "../../src/v3/stock/robinhood/RestrictedVenue.sol";
import {RelayFundingRoute} from "../../src/v3/stock/RelayFundingRoute.sol";
import {V3LzConfig, IV3LzEndpointConfig} from "./V3LzConfig.sol";
import {ChainlinkStockSource} from "../../src/v3/oracle/ChainlinkStockSource.sol";
import {StockPriceSender} from "../../src/v3/oracle/StockPriceSender.sol";

/// @notice Robinhood Chain side of the Solon stock layer (ReserveVault + RestrictedVenue + the USDG return
/// route), used by `DeployV3Reserve` on RH and by `DeployV3` on the local devnet (both sides on one
/// chain). The deployer configures, then hands the OApp delegate and ownership to `owner` (the RH
/// timelock; ReserveVault ownership is two-step and must be accepted by it).
interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
}

abstract contract V3ReserveDeployer is Script {
    struct ReserveCfg {
        address deployer;
        address endpoint; // RH LayerZero EndpointV2
        uint32 arcEid;
        address hub; // Arc SolonStockHub (precomputed on Arc)
        uint256 arcChainId;
        address usdg; // RH settlement token
        address stock; // RH stock token (underlying)
        string ticker;
        address v3Router; // RH Uniswap V3 SwapRouter behind RestrictedVenue
        uint24 venuePoolFee;
        address arbSys;
        address bridger; // Ethereum bridger (L1)
        address owner; // RH timelock
        address guardian;
        address keeper;
        address treasury;
        address floatA;
        address floatB;
        address relayDepository; // Relay deposit receiver on RH
        address fundingSigner;
        address sendLib;
        address receiveLib;
        uint64 confirmations; // RH send side
        uint64 arcConfirmations; // r9: Arc send side = every receive-from-Arc config (DVNs attest with it)
        address[] extraStocks; // r7: further RH underlyings (AAPL, TSLA) listed next to `stock`
        string[] extraTickers;
        uint24[] extraPoolFees;
        // r13 (path 2a, 2026-10-01): launch with the acceleration float on and seeded by the deployer
        bool floatEnabled;
        uint256 floatSeed; // USDG (6 dp) the deployer transfers into the vault as free settlement (the float)
    }

    struct ReserveOut {
        address vault;
        address venue;
        address returnRoute;
    }

    /// @dev Runs inside the caller's broadcast. Returns the three RH contracts.
    function _deployReserve(ReserveCfg memory c) internal returns (ReserveOut memory o) {
        // Decimals M5: on path 2a Relay pays the vault by plain USDG transfer (no fund(ref)) and its 6-dp output may
        // undershoot the 18-dp principal; only the float executes those buys. Without it every RH buy waits forever.
        require(block.chainid != 4663 || c.floatEnabled, "RH mainnet (path 2a) needs RH_FLOAT_ENABLED");
        RestrictedVenue venue = new RestrictedVenue(c.v3Router, c.usdg, c.usdg, address(0), c.deployer);
        venue.setPool(c.stock, c.venuePoolFee);
        require(
            c.extraStocks.length == c.extraTickers.length && c.extraStocks.length == c.extraPoolFees.length, "extras"
        );
        for (uint256 i; i < c.extraStocks.length; ++i) {
            venue.setPool(c.extraStocks[i], c.extraPoolFees[i]);
        }
        ReserveVault vault = new ReserveVault(
            c.endpoint,
            c.arcEid,
            c.usdg,
            address(venue),
            c.arbSys,
            c.bridger,
            c.deployer,
            c.treasury,
            [c.floatA, c.floatB]
        );
        venue.setVault(address(vault));
        RelayFundingRoute ret = new RelayFundingRoute(
            RelayFundingRoute.Config({
                caller: address(vault),
                asset: c.usdg,
                destination: c.hub,
                destinationChainId: c.arcChainId,
                depository: c.relayDepository,
                signer: c.fundingSigner,
                returnExecutor: address(0),
                nativeToken: address(0)
            })
        );
        vault.setReturnRoute(address(ret));
        vault.setPeer(c.arcEid, bytes32(uint256(uint160(c.hub))));
        vault.listStock(c.stock, c.ticker);
        for (uint256 i; i < c.extraStocks.length; ++i) {
            vault.listStock(c.extraStocks[i], c.extraTickers[i]);
        }
        vault.setKeeper(c.keeper);
        vault.setGuardian(c.guardian);
        // r12 (review M2): pin ULN302 on both sides toward Arc (never the endpoint default library).
        IV3LzEndpointConfig(c.endpoint).setSendLibrary(address(vault), c.arcEid, c.sendLib);
        IV3LzEndpointConfig(c.endpoint).setReceiveLibrary(address(vault), c.arcEid, c.receiveLib, 0);
        IV3LzEndpointConfig(c.endpoint).setConfig(
            address(vault), c.sendLib, V3LzConfig.params(c.arcEid, V3LzConfig.defaults(c.confirmations))
        );
        IV3LzEndpointConfig(c.endpoint).setConfig(
            address(vault), c.receiveLib, V3LzConfig.params(c.arcEid, V3LzConfig.defaults(c.arcConfirmations))
        );
        if (c.floatEnabled) vault.setFloatEnabled(true);
        if (c.floatSeed != 0) {
            require(c.floatEnabled, "RH float seed needs RH_FLOAT_ENABLED");
            require(IERC20Like(c.usdg).transfer(address(vault), c.floatSeed), "RH float seed");
        }
        vault.setDelegate(c.owner);
        vault.transferOwnership(c.owner);
        venue.transferOwnership(c.owner);
        o = ReserveOut(address(vault), address(venue), address(ret));
    }
}

/// @notice Read-only checks of the RH side (VerifyV3 on the local devnet; VerifyV3Reserve on RH).
abstract contract V3ReserveVerifier is Script {
    uint256 public reserveChecks;
    /// @dev r13 (path 2a): expected float mode / minimum seeded free settlement (USDG 6 dp), set by the caller.
    bool internal expectRhFloat;
    uint256 internal expectRhSeed;
    /// @dev Relay depository v2, same address on Arc 5042 and RH 4663 (api.relay.link/chains, checked on-chain r12).
    address internal constant RELAY_DEPOSITORY_V2 = 0x4cD00E387622C35bDDB9b4c962C136462338BC31;
    /// @dev r14: Arc native USDC's ERC-20 view (6 dp) — the currency Relay prices Arc USDC deposits in.
    address internal constant ARC_USDC_VIEW = 0x3600000000000000000000000000000000000000;

    function _rtrue(bool ok, string memory what) internal {
        require(ok, what);
        ++reserveChecks;
    }

    function _verifyReserve(
        ReserveVault vault,
        RestrictedVenue venue,
        RelayFundingRoute ret,
        address hub,
        uint32 arcEid,
        address stock,
        address owner,
        address sendLib,
        address receiveLib,
        address[] memory extraStocks
    ) internal {
        address usdg = address(vault.settlement());
        for (uint256 i; i < extraStocks.length; ++i) {
            _rtrue(venue.isSupported(extraStocks[i]), "venue extra stock");
            _rtrue(
                vault.getListing(extraStocks[i]).underlying == extraStocks[i] && vault.getListing(extraStocks[i]).enabled,
                "reserve extra listing"
            );
        }
        _rtrue(address(vault.venue()) == address(venue) && venue.vault() == address(vault), "reserve venue");
        _rtrue(venue.settlementToken() == usdg && venue.isSupported(stock), "venue settlement/stock");
        _rtrue(vault.getListing(stock).underlying == stock && vault.getListing(stock).enabled, "reserve listing");
        _rtrue(vault.hubEid() == arcEid && vault.peers(arcEid) == bytes32(uint256(uint160(hub))), "reserve peer");
        _rtrue(address(vault.returnRoute()) == address(ret), "reserve return route");
        _rtrue(
            ret.caller() == address(vault) && ret.asset() == usdg && ret.destination() == hub, "return route binding"
        );
        _rtrue(
            vault.floatEnabled() == expectRhFloat && (block.chainid != 4663 || expectRhFloat) && !vault.paused(),
            "reserve float mode (r13; on on RH mainnet), not paused"
        );
        _rtrue(vault.freeSettlement() >= expectRhSeed && vault.settlementLiabilities() == 0, "reserve float seed");
        // r12 (review L6): the two-step handover counts only once accepted — while it is pending the deployer EOA is
        // still the owner. The single-chain local devnet (31337) cannot sign for the stand-in owner, so it alone may
        // stop at pendingOwner.
        _rtrue(
            vault.owner() == owner || (block.chainid == 31337 && vault.pendingOwner() == owner),
            "reserve owner = timelock (two-step accepted)"
        );
        if (block.chainid == V3LzConfig.RH_CHAIN_ID) {
            // r12 (F1): the return route deposits into the live Relay depository v2 (depositErc20 entry point).
            _rtrue(ret.depository() == RELAY_DEPOSITORY_V2 && RELAY_DEPOSITORY_V2.code.length != 0, "Relay depository v2");
        }
        if (V3LzConfig.live(block.chainid)) {
            _rtrue(
                sendLib == V3LzConfig.sendLib(block.chainid) && receiveLib == V3LzConfig.receiveLib(block.chainid),
                "reserve libraries = ULN302"
            );
        }
        _rtrue(venue.owner() == owner, "venue owner");
        IV3LzEndpointConfig ep = IV3LzEndpointConfig(address(vault.endpoint()));
        _rtrue(ep.delegates(address(vault)) == owner, "reserve LayerZero delegate");
        _checkUln(ep, address(vault), sendLib, arcEid, "reserve send DVNs");
        _checkUln(ep, address(vault), receiveLib, arcEid, "reserve receive DVNs");
        _checkPinned(ep, address(vault), arcEid, sendLib, receiveLib, "reserve vault");
    }

    /// @dev r12 (review M2): libraries explicitly set to the expected ULN302 (not the endpoint default) toward `eid`;
    ///      `receiveLib` = 0 for a send-only OApp.
    function _checkPinned(
        IV3LzEndpointConfig ep,
        address oapp,
        uint32 eid,
        address sendLib,
        address receiveLib,
        string memory what
    ) internal {
        _rtrue(
            !ep.isDefaultSendLibrary(oapp, eid) && ep.getSendLibrary(oapp, eid) == sendLib,
            string.concat(what, ": send library pinned to ULN302 (not default)")
        );
        if (receiveLib == address(0)) return;
        (address lib, bool isDefault) = ep.getReceiveLibrary(oapp, eid);
        _rtrue(!isDefault && lib == receiveLib, string.concat(what, ": receive library pinned to ULN302 (not default)"));
    }

    /// @dev At least 2 DVN signatures out of at least 3 DVNs; placeholders only on the local devnet; never the Dead
    ///      DVN; on RH exactly the V3LzConfig RH set.
    function _checkUln(IV3LzEndpointConfig ep, address oapp, address lib, uint32 eid, string memory what) internal {
        bytes memory raw = ep.getConfig(oapp, lib, eid, V3LzConfig.ULN_CONFIG_TYPE);
        _rtrue(raw.length != 0, what);
        V3LzConfig.UlnConfig memory c = abi.decode(raw, (V3LzConfig.UlnConfig));
        _rtrue(V3LzConfig.adequate(c), what);
        _rtrue(block.chainid == 31337 || !V3LzConfig.placeholder(c), string.concat(what, ": TODO-verify placeholders"));
        _rtrue(!V3LzConfig.dead(c), string.concat(what, ": Dead DVN"));
        if (V3LzConfig.live(block.chainid)) {
            _rtrue(V3LzConfig.matchesChain(c, block.chainid), string.concat(what, ": V3LzConfig DVN set"));
        }
    }
}

/// @notice Live RH deployment of the reserve side. Env: RH_LZ_ENDPOINT, ARC_EID (30417), ARC_HUB,
///   ARC_CHAIN_ID (5042), RH_USDG, RH_STOCK, STOCK_TICKER, RH_V3_ROUTER, RH_VENUE_POOL_FEE, RH_ARBSYS
///   (0x64), ETH_BRIDGER, RH_OWNER (timelock), RH_GUARDIAN, RH_KEEPER, RH_TREASURY, RH_FLOAT_A/B,
///   RH_RELAY_DEPOSITORY, FUNDING_SIGNER, RH_SEND_LIB, RH_RECEIVE_LIB, RH_CONFIRMATIONS; r7 multi-stock:
///   RH_EXTRA_STOCKS / EXTRA_STOCK_TICKERS / RH_EXTRA_POOL_FEES (comma lists, same order). The DVN set is
///   V3LzConfig.defaults (real RH DVNs since r9); ARC_CONFIRMATIONS (1) is used for the receive-from-Arc config.
contract DeployV3Reserve is V3ReserveDeployer {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        ReserveCfg memory c = ReserveCfg({
            deployer: deployer,
            endpoint: vm.envAddress("RH_LZ_ENDPOINT"),
            arcEid: uint32(vm.envOr("ARC_EID", uint256(30417))),
            hub: vm.envAddress("ARC_HUB"),
            arcChainId: vm.envOr("ARC_CHAIN_ID", uint256(5042)),
            usdg: vm.envAddress("RH_USDG"),
            stock: vm.envAddress("RH_STOCK"),
            ticker: vm.envOr("STOCK_TICKER", string("NVDA")),
            v3Router: vm.envAddress("RH_V3_ROUTER"),
            venuePoolFee: uint24(vm.envUint("RH_VENUE_POOL_FEE")),
            arbSys: vm.envOr("RH_ARBSYS", address(0x64)),
            bridger: vm.envAddress("ETH_BRIDGER"),
            owner: vm.envAddress("RH_OWNER"),
            guardian: vm.envAddress("RH_GUARDIAN"),
            keeper: vm.envAddress("RH_KEEPER"),
            treasury: vm.envAddress("RH_TREASURY"),
            floatA: vm.envAddress("RH_FLOAT_A"),
            floatB: vm.envAddress("RH_FLOAT_B"),
            relayDepository: vm.envAddress("RH_RELAY_DEPOSITORY"),
            fundingSigner: vm.envAddress("FUNDING_SIGNER"),
            sendLib: vm.envOr("RH_SEND_LIB", V3LzConfig.sendLib(block.chainid)),
            receiveLib: vm.envOr("RH_RECEIVE_LIB", V3LzConfig.receiveLib(block.chainid)),
            confirmations: uint64(vm.envOr("RH_CONFIRMATIONS", uint256(20))),
            arcConfirmations: uint64(vm.envOr("ARC_CONFIRMATIONS", uint256(1))),
            extraStocks: vm.envOr("RH_EXTRA_STOCKS", ",", new address[](0)),
            extraTickers: vm.envOr("EXTRA_STOCK_TICKERS", ",", new string[](0)),
            extraPoolFees: _fees(vm.envOr("RH_EXTRA_POOL_FEES", ",", new uint256[](0))),
            floatEnabled: vm.envOr("RH_FLOAT_ENABLED", false),
            floatSeed: vm.envOr("RH_FLOAT_SEED_USDG", uint256(0)) * 1e6
        });
        vm.startBroadcast(pk);
        ReserveOut memory o = _deployReserve(c);
        vm.stopBroadcast();
        console2.log("ReserveVault", o.vault);
        console2.log("RestrictedVenue", o.venue);
        console2.log("ReserveReturnRoute", o.returnRoute);
    }

    function _fees(uint256[] memory f) internal pure returns (uint24[] memory o) {
        o = new uint24[](f.length);
        for (uint256 i; i < f.length; ++i) {
            o[i] = uint24(f[i]);
        }
    }
}

/// @dev r10 (testnet drill 2026-10-01): the first RH->Arc price message (3 stocks, cold storage) cost 477,031 gas on
///      Arc for the whole lzReceive tx (tx 0x8f57f9b8b88958a7b514dfe44a3da397a6271c884c44d6c5a2d992bb47403e44, Arc
///      testnet); the old 300k default failed in the executor. Floor = measured + 20% (rounded up); default 600k
///      (+26%). Raise both when more stocks are relayed in one message.
uint128 constant PRICE_LZ_RECEIVE_GAS_DEFAULT = 600_000;
uint128 constant PRICE_LZ_RECEIVE_GAS_MIN = 575_000;

/// @dev LayerZero type-3 executor option lzReceive(gas, 0), exactly as DeployV3PriceSender encodes it.
function priceLzReceiveOptions(uint128 gas) pure returns (bytes memory) {
    return abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), gas);
}

/// @notice r7 (design §12.2): the RH side of the stock oracle — a ChainlinkStockSource configured at deployment
///   with the RH equity feeds and their stock/USDG V3 pools (TWAP cross-check), owned by the RH timelock, and the
///   StockPriceSender OApp that relays its reads to the Arc RelayedStockSource. Env: RH_LZ_ENDPOINT, ARC_EID,
///   RH_OWNER, RH_USDG_FEED, ORACLE_STOCKS / ORACLE_FEEDS / ORACLE_POOLS (comma lists, same order; a zero pool =
///   no TWAP), ORACLE_TWAP_WINDOW (1800), ARC_PRICE_SOURCE (the Arc RelayedStockSource; optional, else the peer
///   is set later by the timelock), PRICE_LZ_RECEIVE_GAS (600000, >= PRICE_LZ_RECEIVE_GAS_MIN), RH_SEND_LIB,
///   RH_CONFIRMATIONS.
///   Ownership: the source is owned by RH_OWNER from construction; the sender is configured by the deployer and
///   handed over (delegate + two-step ownership, to be accepted by the timelock).
contract DeployV3PriceSender is Script {
    uint256 internal constant STOCK_MAX_STALENESS = 4 days; // a long weekend plus a holiday (stocklend rule)
    uint256 internal constant USDG_MAX_STALENESS = 26 hours; // USDG/USD: 24h heartbeat

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("RH_OWNER");
        address endpoint = vm.envAddress("RH_LZ_ENDPOINT");
        uint32 arcEid = uint32(vm.envOr("ARC_EID", uint256(30417)));
        address[] memory stocks = vm.envAddress("ORACLE_STOCKS", ",");
        address[] memory feeds = vm.envAddress("ORACLE_FEEDS", ",");
        address[] memory pools = vm.envAddress("ORACLE_POOLS", ",");
        require(stocks.length == feeds.length && stocks.length == pools.length && stocks.length != 0, "lists");
        uint32 window = uint32(vm.envOr("ORACLE_TWAP_WINDOW", uint256(30 minutes)));
        ChainlinkStockSource.FeedInit[] memory init = new ChainlinkStockSource.FeedInit[](stocks.length);
        for (uint256 i; i < stocks.length; ++i) {
            // Branch A: the RH equity feeds already include the stock token's uiMultiplier (design §8.4).
            init[i] = ChainlinkStockSource.FeedInit(
                stocks[i], feeds[i], true, stocks[i], pools[i], pools[i] == address(0) ? 0 : window
            );
        }
        uint128 gas = uint128(vm.envOr("PRICE_LZ_RECEIVE_GAS", uint256(PRICE_LZ_RECEIVE_GAS_DEFAULT)));
        require(gas >= PRICE_LZ_RECEIVE_GAS_MIN, "PRICE_LZ_RECEIVE_GAS below the measured Arc lzReceive + 20%");
        bytes memory options = priceLzReceiveOptions(gas);
        vm.startBroadcast(pk);
        ChainlinkStockSource src = new ChainlinkStockSource(
            owner, vm.envAddress("RH_USDG_FEED"), STOCK_MAX_STALENESS, USDG_MAX_STALENESS, init
        );
        StockPriceSender sender = new StockPriceSender(endpoint, vm.addr(pk), src, arcEid, options);
        address arcSource = vm.envOr("ARC_PRICE_SOURCE", address(0));
        if (arcSource != address(0)) sender.setPeer(arcEid, bytes32(uint256(uint160(arcSource))));
        V3LzConfig.UlnConfig memory uln = V3LzConfig.defaults(uint64(vm.envOr("RH_CONFIRMATIONS", uint256(20))));
        address sendLib = vm.envOr("RH_SEND_LIB", V3LzConfig.sendLib(block.chainid));
        IV3LzEndpointConfig(endpoint).setSendLibrary(address(sender), arcEid, sendLib); // r12 (M2): send-only OApp
        IV3LzEndpointConfig(endpoint).setConfig(address(sender), sendLib, V3LzConfig.params(arcEid, uln));
        sender.setDelegate(owner);
        sender.transferOwnership(owner);
        vm.stopBroadcast();
        console2.log("ChainlinkStockSource", address(src));
        console2.log("StockPriceSender", address(sender));
    }
}

/// @notice Read-only verification of a live RH reserve deployment. Env: RESERVE_VAULT, RESERVE_VENUE,
///   RESERVE_RETURN_ROUTE, ARC_HUB, ARC_EID, RH_STOCK, RH_OWNER, RH_SEND_LIB, RH_RECEIVE_LIB, RH_EXTRA_STOCKS;
///   r13: RH_FLOAT_ENABLED (expected float mode) and RH_FLOAT_SEED_USDG (minimum free settlement, whole USDG).
contract VerifyV3Reserve is V3ReserveVerifier {
    function run() external {
        expectRhFloat = vm.envOr("RH_FLOAT_ENABLED", false);
        expectRhSeed = vm.envOr("RH_FLOAT_SEED_USDG", uint256(0)) * 1e6;
        _verifyReserve(
            ReserveVault(payable(vm.envAddress("RESERVE_VAULT"))),
            RestrictedVenue(vm.envAddress("RESERVE_VENUE")),
            RelayFundingRoute(vm.envAddress("RESERVE_RETURN_ROUTE")),
            vm.envAddress("ARC_HUB"),
            uint32(vm.envOr("ARC_EID", uint256(30417))),
            vm.envAddress("RH_STOCK"),
            vm.envAddress("RH_OWNER"),
            vm.envOr("RH_SEND_LIB", V3LzConfig.sendLib(block.chainid)),
            vm.envOr("RH_RECEIVE_LIB", V3LzConfig.receiveLib(block.chainid)),
            vm.envOr("RH_EXTRA_STOCKS", ",", new address[](0))
        );
        console2.log("VerifyV3Reserve checks passed", reserveChecks);
    }
}

/// @notice r9: read-only verification of the RH price sender (DeployV3PriceSender). Env: PRICE_SENDER, RH_OWNER,
///   ARC_EID (30417), RH_SEND_LIB (ULN302 on RH), RH_CONFIRMATIONS (20), ARC_PRICE_SOURCE (optional peer).
///   Checks: endpoint = LayerZero EndpointV2 (on RH), send library DVNs = V3LzConfig RH set (never the Dead DVN),
///   confirmations, executor options (type-3 lzReceive, gas >= PRICE_LZ_RECEIVE_GAS_MIN), a TWAP pool for every
///   relayed stock (r12: exactly the stocks the Arc oracle TWAP-checks, ARC_NO_TWAP_STOCKS = the others), pinned ULN302
///   send library, delegate/ownership accepted by the RH timelock, and the peer.
contract VerifyV3PriceSender is V3ReserveVerifier {
    function run() external {
        StockPriceSender sender = StockPriceSender(payable(vm.envAddress("PRICE_SENDER")));
        address owner = vm.envAddress("RH_OWNER");
        uint32 arcEid = uint32(vm.envOr("ARC_EID", uint256(30417)));
        IV3LzEndpointConfig ep = IV3LzEndpointConfig(address(sender.endpoint()));
        if (V3LzConfig.live(block.chainid)) _rtrue(address(ep) == V3LzConfig.endpoint(block.chainid), "LayerZero EndpointV2");
        _rtrue(sender.arcEid() == arcEid, "sender arcEid");
        bytes memory opts = sender.options();
        _rtrue(opts.length == 22 && bytes6(opts) == bytes6(priceLzReceiveOptions(0)), "price options = type-3 lzReceive");
        _rtrue(_optionGas(opts) >= PRICE_LZ_RECEIVE_GAS_MIN, "price lzReceive gas >= measured + 20%");
        // r10: the Arc oracle runs with a 150 bps TWAP check and treats a missing TWAP as Divergent, so a stock relayed
        // without a pool would never be Live on Arc (DeployV3PriceSender accepts a zero pool).
        ChainlinkStockSource src = ChainlinkStockSource(address(sender.source()));
        address[] memory u = src.underlyings();
        _rtrue(u.length != 0, "price source has stocks");
        // r12 (review M4): pool <=> the Arc oracle's TWAP check is on. ARC_NO_TWAP_STOCKS lists the stocks whose Arc
        // maxTwapBps is 0 (default none: every relayed stock needs a pool, as in r10).
        address[] memory noTwap = vm.envOr("ARC_NO_TWAP_STOCKS", ",", new address[](0));
        for (uint256 i; i < u.length; ++i) {
            bool off;
            for (uint256 j; j < noTwap.length; ++j) {
                if (noTwap[j] == u[i]) off = true;
            }
            _rtrue(
                (src.twapPoolOf(u[i]).pool != address(0)) == !off, "TWAP pool <=> Arc TWAP check (ARC_NO_TWAP_STOCKS)"
            );
        }
        address lib = vm.envOr("RH_SEND_LIB", V3LzConfig.sendLib(block.chainid));
        if (V3LzConfig.live(block.chainid)) _rtrue(lib == V3LzConfig.sendLib(block.chainid), "price send library = ULN302");
        _checkUln(ep, address(sender), lib, arcEid, "price send DVNs");
        _checkPinned(ep, address(sender), arcEid, lib, address(0), "price sender");
        V3LzConfig.UlnConfig memory c = abi.decode(
            ep.getConfig(address(sender), lib, arcEid, V3LzConfig.ULN_CONFIG_TYPE), (V3LzConfig.UlnConfig)
        );
        _rtrue(c.confirmations == uint64(vm.envOr("RH_CONFIRMATIONS", uint256(20))), "price send confirmations");
        _rtrue(ep.delegates(address(sender)) == owner, "sender LayerZero delegate = RH timelock");
        _rtrue(sender.owner() == owner, "sender owner = RH timelock (two-step accepted, r12 L6)");
        address arcSource = vm.envOr("ARC_PRICE_SOURCE", address(0));
        if (arcSource != address(0)) {
            _rtrue(sender.peers(arcEid) == bytes32(uint256(uint160(arcSource))), "sender peer = Arc source");
        }
        console2.log("VerifyV3PriceSender checks passed", reserveChecks);
    }

    /// @dev The lzReceive gas: the last 16 bytes of the type-3 option.
    function _optionGas(bytes memory b) internal pure returns (uint128) {
        uint256 w;
        assembly {
            w := mload(add(b, mload(b)))
        }
        return uint128(w);
    }
}
