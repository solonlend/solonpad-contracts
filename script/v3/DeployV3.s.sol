// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Script, console2} from "forge-std/Script.sol";
import {V3HookMiner} from "./MineV3Hook.s.sol";
import {V3StandInToken, V3StandInAggregator, V3StandInFeeRouter, V3StandInLzEndpoint} from "./V3LocalStandIns.sol";
import {V3LzConfig, IV3LzEndpointConfig} from "./V3LzConfig.sol";
import {rhTwapPoolListed} from "./V3OracleConfig.sol";
import {V3ReserveDeployer} from "./DeployV3Reserve.s.sol";
import {V3Governance} from "../../src/v3/governance/V3Governance.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {V3QuoteFeeHook, IV3HookFeeLedger} from "../../src/v3/V3QuoteFeeHook.sol";
import {V3LaunchStrategy} from "../../src/v3/V3LaunchStrategy.sol";
import {V3LPLocker} from "../../src/v3/V3LPLocker.sol";
import {CreatorRightsNFT} from "../../src/v3/CreatorRightsNFT.sol";
import {V3LaunchFactory} from "../../src/v3/V3LaunchFactory.sol";
import {V3Router, IV3TradeEligibility} from "../../src/v3/V3Router.sol";
import {V3Quoter} from "../../src/v3/V3Quoter.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {EligibilityRegistry} from "../../src/v3/EligibilityRegistry.sol";
import {RewardPayoutVault} from "../../src/v3/RewardPayoutVault.sol";
import {StockAdapterRegistry} from "../../src/v3/StockAdapterRegistry.sol";
import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";
import {RewardBatcher} from "../../src/v3/RewardBatcher.sol";
import {RewardDistributor} from "../../src/v3/RewardDistributor.sol";
import {RewardAssetSchedule} from "../../src/v3/RewardAssetSchedule.sol";
import {BurnSink} from "../../src/v3/BurnSink.sol";
import {DeskRewards} from "../../src/v3/DeskRewards.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {ProtocolVault} from "../../src/v3/ProtocolVault.sol";
import {OpsVault} from "../../src/v3/OpsVault.sol";
import {FixedV4BuybackRoute} from "../../src/v3/FixedV4BuybackRoute.sol";
import {BuybackBurnExecutor} from "../../src/v3/BuybackBurnExecutor.sol";
import {ProtocolDeskVault} from "../../src/v3/ProtocolDeskVault.sol";
import {SolonStakingV2} from "../../src/v3/SolonStakingV2.sol";
import {FixedV4FeeSellRoute} from "../../src/v3/FixedV4FeeSellRoute.sol";
import {StockFeeConverter} from "../../src/v3/StockFeeConverter.sol";
import {V2FeeIngress} from "../../src/v3/V2FeeIngress.sol";
import {V2PlatformRouter} from "../../src/v3/V2PlatformRouter.sol";
import {V2FeeConverter} from "../../src/v3/V2FeeConverter.sol";
import {SolonStockHub} from "../../src/v3/stock/SolonStockHub.sol";
import {Guarded} from "../../src/v3/stock/libs/Guarded.sol";
import {CapacityController} from "../../src/v3/stock/CapacityController.sol";
import {OrderScheduler} from "../../src/v3/stock/OrderScheduler.sol";
import {CanonicalGate} from "../../src/v3/stock/CanonicalGate.sol";
import {RelayFundingRoute} from "../../src/v3/stock/RelayFundingRoute.sol";
import {SolonStockSellRoute} from "../../src/v3/stock/SolonStockSellRoute.sol";
import {StockPoolVault} from "../../src/v3/stock/StockPoolVault.sol";
import {SolonStockAdapter} from "../../src/v3/adapters/SolonStockAdapter.sol";
import {SolonStockOracle} from "../../src/v3/oracle/SolonStockOracle.sol";
import {ChainlinkStockSource} from "../../src/v3/oracle/ChainlinkStockSource.sol";
import {RelayedStockSource} from "../../src/v3/oracle/RelayedStockSource.sol";
import {OracleRefTickSigner} from "../../src/v3/oracle/OracleRefTickSigner.sol";
import {IStockPriceSource} from "../../src/v3/oracle/IStockPriceSource.sol";
import {LaunchPayoutChoice} from "../../src/v3/LaunchPayoutChoice.sol";
import {V3MultiHopRouter, IV3HopEligibility} from "../../src/v3/V3MultiHopRouter.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deterministic deployment + wiring of Solon v3 phases 1-5 (Arc side), handed to V3Governance.
///
/// Determinism: V3Governance is CREATEd by the deployer EOA; every other v3 contract is
/// CREATEd by the governance contract during its one-shot bootstrap window, so all
/// addresses follow from (deployer, deployer nonce) and a fixed creation order; each is
/// asserted against the precomputed address. The hook is CREATE2-mined through the standard
/// CREATE2 deployer with the existing V3HookMiner (flags 0x28cc). Every contract role
/// (governance / governor / configurator / infrastructureConfigurator) therefore equals the
/// governance address; bootstrap is closed at the end, leaving only the 48h timelock.
///
/// Phase 5 (stock layer, Arc side) is created first by governance, so the reward asset (NVDA.sol, the
/// hub's first CREATE) and the factory's `stockStatus` (the hub) exist before anything binds them. The
/// Robinhood Chain side is `DeployV3Reserve` on RH (its vault address is `RESERVE_VAULT` here, the hub
/// address is precomputed for it); on the local devnet both sides are deployed here on one chain.
///
/// Env (required unless LOCAL_STANDINS=true on chain 31337, which fills local defaults):
///   MULTISIG, GUARDIAN, TREASURY, OPS_VERIFIER, PRICE_SIGNER, BUYBACK_SIGNER,
///   STOCK_FEE_SIGNER, V2_SIGNER, V2_AUDITOR_0..2, V2_FUNDER, V2_CUTOVER_BLOCK,
///   POOL_MANAGER, POSITION_MANAGER, SELL_SWAP_ROUTER (PoolSwapTest ABI), SOLON_FEE_ROUTER, SOLON,
///   SOL_USD18, USDC_USD18,
///   stock layer: LZ_ENDPOINT, RESERVE_VAULT, STOCK_QUOTE_UNDERLYING (RH stock), RELAY_DEPOSITORY,
///   RELAY_RETURN_EXECUTOR, FUNDING_SIGNER, REWARD_QUOTE_SIGNER, STOCK_KEEPER, RESERVE_RECIPIENT (RH),
///   CCTP_TOKEN_MESSENGER, CCTP_MESSAGE_TRANSMITTER, ARC_USDC, ETH_TOKEN_MESSENGER, GATE_FUNDS,
///   HUB_FLOAT_A/B, ARC_SEND_LIB, ARC_RECEIVE_LIB (TODO-verify; placeholders refused off-devnet).
/// Optional: NATIVE_USDC_VIEW, PRICE_ORACLE, REWARD_ASSET_ID, REWARD_ADAPTER_VERSION, REWARD_PRICE_POLICY,
///   STOCK_POOL_FEE/TICK_SPACING, SOLON_POOL_FEE/TICK_SPACING, STOCK_FEE_BPS, HOOK_SALT_START,
///   BOOTSTRAP_WINDOW, MANIFEST_PATH, ARC_EID (30417), RH_EID (30416), RH_CHAIN_ID (4663), ETH_DOMAIN (0),
///   ETH_BRIDGER, STOCK_TICKER (NVDA), STOCK_MINT_FLOOR (shares/day floor), REWARD_FIXED_COST18,
///   ARC_CONFIRMATIONS.
/// r9 pool A (NVDA only, design §9.5/§12.8; 2026-10-01): starting structure in whole dollars
///   POOL_A_POOL_USD (USDC side of the range, 1000), POOL_A_STOCK_USD (NVDA.sol side, 1000), POOL_A_RESERVE_USD
///   (idle USDC kept in the vault for the restock keeper, 1000). The deployer sends pool + reserve + stock as native
///   USDC ($3,000 by default): on a first deployment NVDA.sol only exists after a real RH purchase, so the keeper
///   buys the stock side with restockMint. POOL_A_SEED_STOCK_RAW (NVDA.sol the deployer already holds) replaces the
///   USDC for the stock side. POOL_A_FUND=false deploys the vault empty. POOL_A_SEED_USD (r8) is retired.
///   LayerZero: ARC_SEND_LIB / ARC_RECEIVE_LIB default to the real ULN302 on Arc (5042); ARC_CONFIRMATIONS (1) is
///   the Arc send side, RH_CONFIRMATIONS (20) the RH send side, used for every receive-from-RH config.
/// The manifest is printed as one `V3_MANIFEST_JSON=` log line (see script/v3/run-local.sh).
contract DeployV3 is V3ReserveDeployer {
    struct Config {
        bool local;
        address deployer;
        address multisig;
        address guardian;
        address treasury;
        address opsVerifier;
        address buybackSigner;
        address stockFeeSigner;
        address v2Signer;
        address[3] auditors;
        address v2Funder;
        uint64 v2Cutover;
        address poolManager;
        address positionManager;
        address sellSwapRouter;
        address solonFeeRouter;
        address solon;
        address rewardAsset;
        address nativeUsdcView;
        address priceOracle;
        address stockStatus;
        address stockUnderlying;
        address capacity;
        bytes32 rewardAssetId;
        uint32 rewardVersion;
        bytes32 rewardPricePolicy;
        uint24 stockPoolFee;
        int24 stockPoolSpacing;
        uint24 solonPoolFee;
        int24 solonPoolSpacing;
        uint16 stockFeeBps;
        uint256 solUsd18;
        uint256 usdcUsd18;
        uint256 bootstrapWindow;
        uint256 hookSaltStart;
        uint256 deployTime;
        // ---- phase 5
        address lzEndpoint;
        uint32 arcEid;
        uint32 rhEid;
        uint256 rhChainId;
        address reserveVault;
        address relayDepository;
        address relayReturnExecutor;
        address fundingSigner;
        address rewardQuoteSigner;
        address stockKeeper;
        address reserveRecipient;
        address cctpMessenger;
        address cctpTransmitter;
        address arcUsdc;
        uint32 ethDomain;
        address ethTokenMessenger;
        address ethBridger;
        address gateFunds;
        address hubFloatA;
        address hubFloatB;
        // ---- r13: launch in float mode (path 2a, 2026-10-01): both acceleration floats on, L_run lowered
        bool hubFloatEnabled;
        uint256 hubFloatSeedUsd; // whole dollars of native USDC the deployer puts into the hub float (fundFloat)
        uint256 hubPayFloorUsd; // whole dollars: daily floor of float-advanced payouts (setPayLimit floor)
        uint256 lRunUsd; // whole dollars: single-order limit (CapacityController.lowerLimits; raise = 48h)
        string stockTicker;
        uint128 mintFloor;
        uint256 rewardFixedCost18;
        address sendLib;
        address receiveLib;
        uint64 confirmations;
        uint64 rhConfirmations; // r9: RH send side; every receive-from-RH config must use it
        // ---- r7: oracle, three stocks, per-asset caps, payout choice
        address oracleSource; // RelayedStockSource (live) / ChainlinkStockSource on stand-in feeds (local)
        address refTickSigner; // OracleRefTickSigner: pool A's price signer
        address priceSender; // RH StockPriceSender (peer of the relayed source); 0 = set later by the timelock
        address[] extraUnderlyings; // RH AAPL, TSLA
        string[] extraTickers;
        address[] extraTokens; // their Arc SolonStockTokens
        uint256[] assetCapsUsd; // whole dollars, [primary, extras...]
        // ---- r8: pool A + V3MultiHopRouter (2026-10-01: no InstantStockDesk)
        uint256 poolASeedUsd; // whole dollars of native USDC sent to StockPoolVault at deployment (0 = none)
        uint256 poolAPoolUsd; // r9: USDC side of the range
        uint256 poolAStockUsd; // r9: NVDA.sol side of the range (bought by the keeper unless poolASeedStockRaw)
        uint256 poolAReserveUsd; // r9: idle USDC reserve for anchoring / restockMint
        uint256 poolASeedStockRaw; // NVDA.sol the deployer sends along (0 = none; the keeper mints the stock half)
        bool poolAInitialized; // initialized at the oracle price inside the bootstrap (needs a Live price)
        int24 poolAInitTick;
    }

    /// @dev Sanity bound on the deployment seed (whole dollars); larger funding goes through the treasury later.
    uint256 internal constant POOL_A_SEED_MAX = 100_000;

    bytes32 internal constant RELAY_PATH = keccak256("RELAY");

    Config internal cfg;
    V3Governance internal gov;
    uint256 internal govNonce;
    string[] internal names;
    mapping(string => address) public deployed;
    string[] internal standIns;
    string[] internal opsTodo;
    ReserveOut internal reserve;
    string internal manifestJson; // r10: the emitted manifest, for VerifyV3 run in-process by tests

    function run() external {
        _loadConfig();
        vm.startBroadcast(cfg.deployer);
        _externals();
        gov = new V3Governance(cfg.multisig, cfg.guardian, cfg.deployer, cfg.deployTime + cfg.bootstrapWindow);
        _record("V3Governance", address(gov));
        govNonce = vm.getNonce(address(gov));
        if (cfg.local) _deployLocalReserve();
        _deployOracle();
        _deployStockLayer();
        _deployPhase3And4();
        _deployCore();
        _deployR7();
        _wire();
        // Testnet drill only: the relayed oracle price can only arrive after this script (real LayerZero), so pool A's
        // initialize at the Live oracle tick is done by FinishV3Testnet inside the same bootstrap window, which then
        // closes it. Refused on any other chain: production closes the bootstrap here.
        if (vm.envOr("TESTNET_KEEP_BOOTSTRAP_OPEN", false)) {
            require(block.chainid == V3LzConfig.ARC_TESTNET_CHAIN_ID, "TESTNET_KEEP_BOOTSTRAP_OPEN: Arc testnet only");
        } else {
            gov.closeBootstrap();
        }
        vm.stopBroadcast();
        _writeManifest();
    }

    // ---------------------------------------------------------------- config

    function _loadConfig() internal {
        cfg.local = vm.envOr("LOCAL_STANDINS", false);
        require(!cfg.local || block.chainid == 31337, "stand-ins are anvil-only");
        uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        cfg.deployer = pk != 0 ? vm.addr(pk) : vm.envOr("DEPLOYER", msg.sender);
        if (pk != 0) vm.rememberKey(pk);
        cfg.multisig = _addr("MULTISIG", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        cfg.guardian = _addr("GUARDIAN", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));
        cfg.treasury = _addr("TREASURY", address(0x90F79bf6EB2c4f870365E785982E1f101E93b906));
        cfg.opsVerifier = _addr("OPS_VERIFIER", address(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65));
        cfg.buybackSigner = _addr("BUYBACK_SIGNER", address(0x976EA74026E726554dB657fA54763abd0C3a0aa9));
        cfg.stockFeeSigner = _addr("STOCK_FEE_SIGNER", address(0x14dC79964da2C08b23698B3D3cc7Ca32193d9955));
        cfg.v2Signer = _addr("V2_SIGNER", address(0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f));
        cfg.auditors = [
            _addr("V2_AUDITOR_0", address(0xa0Ee7A142d267C1f36714E4a8F75612F20a79720)),
            _addr("V2_AUDITOR_1", address(0xBcd4042DE499D14e55001CcbB24a551F3b954096)),
            _addr("V2_AUDITOR_2", address(0x71bE63f3384f5fb98995898A86B02Fb2426c5788))
        ];
        cfg.v2Funder = _addr("V2_FUNDER", address(0xFABB0ac9d68B0B445fB7357272Ff202C5651694a));
        cfg.v2Cutover = uint64(vm.envOr("V2_CUTOVER_BLOCK", uint256(cfg.local ? 1 : 0)));
        require(cfg.v2Cutover != 0, "V2_CUTOVER_BLOCK");
        cfg.poolManager = vm.envOr("POOL_MANAGER", address(0));
        cfg.positionManager = vm.envOr("POSITION_MANAGER", address(0));
        cfg.sellSwapRouter = vm.envOr("SELL_SWAP_ROUTER", address(0));
        cfg.solonFeeRouter = vm.envOr("SOLON_FEE_ROUTER", address(0));
        cfg.solon = vm.envOr("SOLON", address(0));
        cfg.nativeUsdcView = vm.envOr("NATIVE_USDC_VIEW", address(0));
        cfg.stockUnderlying = vm.envOr("STOCK_QUOTE_UNDERLYING", address(0));
        cfg.rewardAssetId = vm.envOr("REWARD_ASSET_ID", keccak256("NVDA"));
        cfg.rewardVersion = uint32(vm.envOr("REWARD_ADAPTER_VERSION", uint256(1)));
        cfg.rewardPricePolicy = vm.envOr("REWARD_PRICE_POLICY", keccak256("solon.v3.reward.price.v1"));
        cfg.stockPoolFee = uint24(vm.envOr("STOCK_POOL_FEE", uint256(10000)));
        cfg.stockPoolSpacing = int24(int256(vm.envOr("STOCK_POOL_TICK_SPACING", uint256(200))));
        cfg.solonPoolFee = uint24(vm.envOr("SOLON_POOL_FEE", uint256(10000)));
        cfg.solonPoolSpacing = int24(int256(vm.envOr("SOLON_POOL_TICK_SPACING", uint256(100))));
        cfg.stockFeeBps = uint16(vm.envOr("STOCK_FEE_BPS", uint256(25)));
        cfg.solUsd18 = vm.envOr("SOL_USD18", uint256(cfg.local ? 150e18 : 0));
        cfg.usdcUsd18 = vm.envOr("USDC_USD18", uint256(cfg.local ? 1e18 : 0));
        cfg.bootstrapWindow = vm.envOr("BOOTSTRAP_WINDOW", uint256(1 days));
        cfg.hookSaltStart = vm.envOr("HOOK_SALT_START", uint256(0));
        // Timestamp-derived constructor args are pinned so simulated and mined code are identical.
        cfg.deployTime = vm.envOr("DEPLOY_TIMESTAMP", block.timestamp);
        require(cfg.deployTime <= block.timestamp, "DEPLOY_TIMESTAMP");
        _loadStockConfig();
    }

    function _loadStockConfig() internal {
        cfg.lzEndpoint = vm.envOr("LZ_ENDPOINT", address(0));
        cfg.arcEid = uint32(vm.envOr("ARC_EID", uint256(30417)));
        cfg.rhEid = uint32(vm.envOr("RH_EID", uint256(30416)));
        cfg.rhChainId = vm.envOr("RH_CHAIN_ID", uint256(4663));
        cfg.reserveVault = vm.envOr("RESERVE_VAULT", address(0)); // local: deployed below
        cfg.relayDepository = _addr("RELAY_DEPOSITORY", address(0x4E1A));
        cfg.relayReturnExecutor = _addr("RELAY_RETURN_EXECUTOR", address(0x4E1B));
        cfg.fundingSigner = _addr("FUNDING_SIGNER", address(0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc));
        cfg.rewardQuoteSigner = _addr("REWARD_QUOTE_SIGNER", address(0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc));
        cfg.stockKeeper = _addr("STOCK_KEEPER", address(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65));
        cfg.reserveRecipient = _addr("RESERVE_RECIPIENT", address(0x90F79bf6EB2c4f870365E785982E1f101E93b906));
        cfg.cctpMessenger = _addr("CCTP_TOKEN_MESSENGER", address(0xCC70));
        cfg.cctpTransmitter = _addr("CCTP_MESSAGE_TRANSMITTER", address(0xCC71));
        cfg.arcUsdc = _addr("ARC_USDC", address(0xCC72));
        cfg.ethDomain = uint32(vm.envOr("ETH_DOMAIN", uint256(0)));
        cfg.ethTokenMessenger = _addr("ETH_TOKEN_MESSENGER", address(0xCC73));
        cfg.ethBridger = vm.envOr("ETH_BRIDGER", cfg.local ? address(0xB41D) : address(0));
        cfg.gateFunds = _addr("GATE_FUNDS", cfg.treasury);
        cfg.hubFloatA = _addr("HUB_FLOAT_A", cfg.treasury);
        cfg.hubFloatB = _addr("HUB_FLOAT_B", address(0x976EA74026E726554dB657fA54763abd0C3a0aa9));
        // r13 (path 2a): defaults = the zero-float r12 behaviour; mainnet.env sets the launch values.
        cfg.hubFloatEnabled = vm.envOr("HUB_FLOAT_ENABLED", false);
        cfg.hubFloatSeedUsd = vm.envOr("HUB_FLOAT_SEED_USD", uint256(0));
        cfg.hubPayFloorUsd = vm.envOr("HUB_PAY_FLOOR_USD", uint256(10_000));
        cfg.lRunUsd = vm.envOr("L_RUN_USD", uint256(10_000));
        require(cfg.hubFloatEnabled || cfg.hubFloatSeedUsd == 0, "HUB_FLOAT_SEED_USD needs HUB_FLOAT_ENABLED");
        require(cfg.hubFloatSeedUsd <= POOL_A_SEED_MAX, "HUB_FLOAT_SEED_USD <= 100000");
        require(cfg.lRunUsd >= 20 && cfg.lRunUsd <= 10_000, "L_RUN_USD in [20, 10000] (min order .. default)");
        require(cfg.hubPayFloorUsd <= 10_000, "HUB_PAY_FLOOR_USD <= 10000 (contract default)");
        cfg.stockTicker = vm.envOr("STOCK_TICKER", string("NVDA"));
        cfg.mintFloor = uint128(vm.envOr("STOCK_MINT_FLOOR", uint256(10_000e18)));
        cfg.rewardFixedCost18 = vm.envOr("REWARD_FIXED_COST18", uint256(0.5 ether));
        cfg.sendLib = vm.envOr("ARC_SEND_LIB", V3LzConfig.sendLib(block.chainid));
        cfg.receiveLib = vm.envOr("ARC_RECEIVE_LIB", V3LzConfig.receiveLib(block.chainid));
        cfg.confirmations = uint64(vm.envOr("ARC_CONFIRMATIONS", uint256(1)));
        cfg.rhConfirmations = uint64(vm.envOr("RH_CONFIRMATIONS", uint256(20)));
        // r7 (2026-10-01): NVDA + AAPL + TSLA, caps $400k / $300k / $300k; stock-quote coins NVDA only.
        string[] memory tickers = new string[](cfg.local ? 2 : 0);
        if (cfg.local) (tickers[0], tickers[1]) = ("AAPL", "TSLA");
        cfg.extraTickers = vm.envOr("EXTRA_STOCK_TICKERS", ",", tickers);
        cfg.extraUnderlyings = vm.envOr("EXTRA_STOCK_UNDERLYINGS", ",", new address[](0));
        uint256[] memory caps = new uint256[](3);
        (caps[0], caps[1], caps[2]) = (400_000, 300_000, 300_000);
        cfg.assetCapsUsd = vm.envOr("ASSET_CAPS_USD", ",", caps);
        require(cfg.assetCapsUsd.length == 1 + cfg.extraTickers.length, "ASSET_CAPS_USD");
        cfg.priceSender = vm.envOr("PRICE_SENDER", address(0));
        if (!cfg.local) {
            require(cfg.extraUnderlyings.length == cfg.extraTickers.length, "EXTRA_STOCK_UNDERLYINGS");
            require(cfg.lzEndpoint != address(0), "LZ_ENDPOINT");
            require(cfg.reserveVault != address(0), "RESERVE_VAULT");
            require(cfg.stockUnderlying != address(0), "STOCK_QUOTE_UNDERLYING");
        }
        _loadPoolAConfig();
    }

    /// @dev r9: pool A's starting structure ($1,000 NVDA.sol + $1,000 USDC in range, $1,000 USDC idle reserve).
    function _loadPoolAConfig() internal virtual {
        require(vm.envOr("POOL_A_SEED_USD", uint256(0)) == 0, "POOL_A_SEED_USD retired: POOL_A_POOL/STOCK/RESERVE_USD");
        bool fund = vm.envOr("POOL_A_FUND", true);
        cfg.poolAPoolUsd = fund ? vm.envOr("POOL_A_POOL_USD", uint256(1000)) : 0;
        cfg.poolAStockUsd = fund ? vm.envOr("POOL_A_STOCK_USD", uint256(1000)) : 0;
        cfg.poolAReserveUsd = fund ? vm.envOr("POOL_A_RESERVE_USD", uint256(1000)) : 0;
        cfg.poolASeedStockRaw = vm.envOr("POOL_A_SEED_STOCK_RAW", uint256(0));
        require(fund || cfg.poolASeedStockRaw == 0, "POOL_A_SEED_STOCK_RAW needs POOL_A_FUND");
        require(
            !fund || (cfg.poolAPoolUsd != 0 && cfg.poolAStockUsd != 0), "POOL_A_POOL_USD and POOL_A_STOCK_USD > 0"
        );
        cfg.poolASeedUsd = cfg.poolAPoolUsd + cfg.poolAReserveUsd + (cfg.poolASeedStockRaw == 0 ? cfg.poolAStockUsd : 0);
        require(cfg.poolASeedUsd <= POOL_A_SEED_MAX, "pool A seed <= 100000 (more goes through the treasury later)");
    }

    function _addr(string memory key, address localDefault) internal view returns (address a) {
        a = vm.envOr(key, cfg.local ? localDefault : address(0));
        require(a != address(0), key);
    }

    /// @dev External dependencies: real v4 core/periphery locally, stand-ins only when allowed.
    function _externals() internal {
        if (cfg.poolManager == address(0)) {
            require(cfg.local, "POOL_MANAGER");
            cfg.poolManager = address(new PoolManager(cfg.multisig));
            _record("local_PoolManager", cfg.poolManager);
        }
        if (cfg.positionManager == address(0)) {
            require(cfg.local, "POSITION_MANAGER");
            cfg.positionManager = address(
                new PositionManager(
                    IPoolManager(cfg.poolManager),
                    IAllowanceTransfer(address(0)),
                    100000,
                    IPositionDescriptor(address(0)),
                    IWETH9(address(0))
                )
            );
            _record("local_PositionManager", cfg.positionManager);
        }
        if (cfg.sellSwapRouter == address(0)) {
            require(cfg.local, "SELL_SWAP_ROUTER");
            cfg.sellSwapRouter = address(new PoolSwapTest(IPoolManager(cfg.poolManager)));
            _record("local_PoolSwapTest", cfg.sellSwapRouter);
        }
        if (cfg.solon == address(0)) {
            cfg.solon = _standIn("standin_SOLON", address(new V3StandInToken("SOLON", "SOLON")));
        }
        if (cfg.solonFeeRouter == address(0)) {
            cfg.solonFeeRouter = _standIn("standin_SolonFeeRouter", address(new V3StandInFeeRouter()));
        }
        if (cfg.lzEndpoint == address(0)) {
            require(cfg.local, "LZ_ENDPOINT");
            cfg.lzEndpoint = _standIn("local_ArcLzEndpoint", address(new V3StandInLzEndpoint(cfg.arcEid)));
        }
        if (cfg.stockUnderlying == address(0)) {
            cfg.stockUnderlying = _standIn("standin_RHStock", address(new V3StandInToken("RH NVDA", "NVDA")));
        }
        if (cfg.local && cfg.extraUnderlyings.length == 0) {
            for (uint256 i; i < cfg.extraTickers.length; ++i) {
                string memory t = cfg.extraTickers[i];
                cfg.extraUnderlyings.push(
                    _standIn(string.concat("standin_RH", t), address(new V3StandInToken(string.concat("RH ", t), t)))
                );
            }
        }
        opsTodo.push("RH: DeployV3PriceSender (ChainlinkStockSource + StockPriceSender), then peers both ways (48h)");
        opsTodo.push("oracle-keeper (keepers/v3/oracle): event-driven StockPriceSender.poke, 0.5% move / 2h heartbeat");
        opsTodo.push("InstantStockDesk: not deployed (r8 rejected: duplicates pool A + restock bot)");
        opsTodo.push("Pool A / V3MultiHopRouter: NVDA only; AAPL/TSLA are reward assets without Arc pools");
        opsTodo.push("OpsVault expense kinds 0-5: target mapping is a product decision (one-time, immutable)");
        opsTodo.push("restock-keeper: buy the $1k NVDA.sol side (restockMint), first range, $1k USDC stays idle reserve");
        opsTodo.push("NVDA stock-quote launches: UI/API stay closed until the pool-A gate passes (design 12.8)");
        opsTodo.push("CanonicalGate float: fund 1 USDC hooks; ReserveVault.acceptOwnership by the RH timelock");
        opsTodo.push("LayerZero: RH StockPriceSender/ReserveVault use V3LzConfig RH DVNs; RH_CONFIRMATIONS = Arc receive");
        opsTodo.push("DeskNFT: timelock setGuardianAction(DeskNFT, tightenMintCapPerAddress, true) (48h self-op)");
        require(cfg.solUsd18 != 0 && cfg.usdcUsd18 != 0, "SOL_USD18/USDC_USD18");
    }

    function _standIn(string memory name, address a) internal returns (address) {
        require(cfg.local, name);
        _record(name, a);
        standIns.push(name);
        return a;
    }

    // ---------------------------------------------------------------- deployment

    /// @dev Address of the k-th governance CREATE (fixed order below).
    function _at(uint256 k) internal view returns (address) {
        return vm.computeCreateAddress(address(gov), govNonce + k);
    }

    // Phase 5 first: the reward asset and the factory's stock status must exist before phase 1-4 bind them.
    uint256 internal constant K_CAPACITY = 0;
    uint256 internal constant K_HUB = 1;
    uint256 internal constant K_SCHEDULER = 2;
    uint256 internal constant K_GATE = 3;
    uint256 internal constant K_ARC_ROUTE = 4;
    uint256 internal constant K_STOCK_ADAPTER = 5;
    uint256 internal constant K_POOL_VAULT = 6;
    uint256 internal constant K_LEDGER = 7;
    uint256 internal constant K_CONTROLLER = 8;
    uint256 internal constant K_ELIGIBILITY_REGISTRY = 9;
    uint256 internal constant K_PAYOUT = 10;
    uint256 internal constant K_ADAPTER_REGISTRY = 11;
    uint256 internal constant K_ROUNDS = 12;
    uint256 internal constant K_BATCHER = 13;
    uint256 internal constant K_DISTRIBUTOR = 14;
    uint256 internal constant K_CALENDAR = 15;
    uint256 internal constant K_SINK = 16;
    uint256 internal constant K_DESK_REWARDS = 17;
    uint256 internal constant K_PROTOCOL = 18;
    uint256 internal constant K_OPS = 19;
    uint256 internal constant K_DESK = 20;
    uint256 internal constant K_BUYBACK_ROUTE = 21;
    uint256 internal constant K_BUYBACK = 22;
    uint256 internal constant K_PROTOCOL_DESK = 23;
    uint256 internal constant K_STAKING = 24;
    uint256 internal constant K_STOCK_SELL_ROUTE = 25;
    uint256 internal constant K_STOCK_CONVERTER = 26;
    uint256 internal constant K_V2_INGRESS = 27;
    uint256 internal constant K_V2_ROUTER = 28;
    uint256 internal constant K_V2_SELL_ROUTE = 29;
    uint256 internal constant K_V2_CONVERTER = 30;
    uint256 internal constant K_RIGHTS = 31;
    uint256 internal constant K_STRATEGY = 32;
    uint256 internal constant K_LOCKER = 33;
    uint256 internal constant K_FACTORY = 34;
    uint256 internal constant K_ROUTER = 35;
    uint256 internal constant K_QUOTER = 36;
    uint256 internal constant K_R7 = 37; // extra-stock adapters, then LaunchPayoutChoice, then V3MultiHopRouter (r8)

    function _create(uint256 k, string memory name, bytes memory init) internal returns (address a) {
        require(vm.getNonce(address(gov)) == govNonce + k, "creation order");
        a = gov.bootstrapCreate(init);
        require(a == _at(k), name);
        _record(name, a);
    }

    function _solonKey() internal view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(cfg.solon),
            cfg.solonPoolFee,
            cfg.solonPoolSpacing,
            IHooks(address(0))
        );
    }

    /// @dev r12 (review M2): explicit setSendLibrary / setReceiveLibrary (grace 0) toward RH, through the governance
    ///      bootstrap (the OApp's LayerZero delegate), so a later LayerZero default-library change cannot move it.
    function _pinLibraries(address oapp, bool send) internal {
        if (send) {
            gov.bootstrapCall(
                cfg.lzEndpoint,
                abi.encodeCall(IV3LzEndpointConfig.setSendLibrary, (oapp, cfg.rhEid, cfg.sendLib))
            );
        }
        gov.bootstrapCall(
            cfg.lzEndpoint,
            abi.encodeCall(IV3LzEndpointConfig.setReceiveLibrary, (oapp, cfg.rhEid, cfg.receiveLib, 0))
        );
    }

    function _stockKey() internal view returns (PoolKey memory) {
        // DESIGN §9.5 pool A: native USDC / NVDA.sol, 1%, spacing 200, no hook (StockPoolVault.poolKey()).
        return PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(cfg.rewardAsset),
            cfg.stockPoolFee,
            cfg.stockPoolSpacing,
            IHooks(address(0))
        );
    }

    /// @dev Local devnet only: the Robinhood Chain side on the same chain, before the hub exists (its
    ///      address is precomputed), so the Arc route and peer can bind the real vault address.
    function _deployLocalReserve() internal {
        address rhEp = _standIn("local_RhLzEndpoint", address(new V3StandInLzEndpoint(cfg.rhEid)));
        address usdg = _standIn("standin_RHUSDG", address(new V3StandInToken("Global Dollar", "USDG")));
        reserve = _deployReserve(
            ReserveCfg({
                deployer: cfg.deployer,
                endpoint: rhEp,
                arcEid: cfg.arcEid,
                hub: _at(K_HUB),
                arcChainId: block.chainid,
                usdg: usdg,
                stock: cfg.stockUnderlying,
                ticker: cfg.stockTicker,
                v3Router: address(0x3333), // stand-in: no local RH DEX; any venue trade reverts
                venuePoolFee: 3000,
                arbSys: address(0x64),
                bridger: cfg.ethBridger,
                owner: cfg.multisig,
                guardian: cfg.guardian,
                keeper: cfg.stockKeeper,
                treasury: cfg.treasury,
                floatA: cfg.hubFloatA,
                floatB: cfg.hubFloatB,
                relayDepository: cfg.relayDepository,
                fundingSigner: cfg.fundingSigner,
                sendLib: V3LzConfig.SEND_LIB_PLACEHOLDER,
                receiveLib: V3LzConfig.RECEIVE_LIB_PLACEHOLDER,
                confirmations: 1,
                arcConfirmations: 1,
                extraStocks: cfg.extraUnderlyings,
                extraTickers: cfg.extraTickers,
                extraPoolFees: _localFees(cfg.extraUnderlyings.length),
                floatEnabled: cfg.hubFloatEnabled, // local devnet: both sides follow the hub setting
                floatSeed: 0
            })
        );
        _record("ReserveVault", reserve.vault);
        _record("RestrictedVenue", reserve.venue);
        _record("ReserveReturnRoute", reserve.returnRoute);
        cfg.reserveVault = reserve.vault;
    }

    /// @dev r7 (design §12.2): the stock oracle, created by the deployer (not governance) so the governance
    ///      CREATE order is unchanged; every owner is governance. Live: prices relayed from RH; local: a direct
    ///      Chainlink source over stand-in feeds.
    function _deployOracle() internal {
        address g = address(gov);
        if (cfg.local) {
            address[] memory u = _underlyings();
            ChainlinkStockSource.FeedInit[] memory init = new ChainlinkStockSource.FeedInit[](u.length);
            for (uint256 i; i < u.length; ++i) {
                int256 px = i == 0 ? int256(180e8) : i == 1 ? int256(230e8) : int256(250e8);
                address f = _standIn(string.concat("standin_Feed_", _ticker(i)), address(new V3StandInAggregator(px)));
                init[i] = ChainlinkStockSource.FeedInit(u[i], f, true, address(0), address(0), 0);
            }
            cfg.oracleSource = address(new ChainlinkStockSource(g, address(0), 4 days, 0, init));
        } else {
            cfg.oracleSource = address(new RelayedStockSource(cfg.lzEndpoint, g, cfg.rhEid));
        }
        _record("StockPriceSource", cfg.oracleSource);
        cfg.priceOracle = address(new SolonStockOracle(g, cfg.guardian));
        _record("SolonStockOracle", cfg.priceOracle);
        cfg.refTickSigner = address(new OracleRefTickSigner(SolonStockOracle(cfg.priceOracle)));
        _record("OracleRefTickSigner", cfg.refTickSigner);
    }

    /// @dev Design §12.2 thresholds: 15 min observation, 10% jump needs a second round within 2%, USDG 50 bps,
    ///      Chainlink update <= 26h (closed market), TWAP 150 bps (relayed RH reads carry the pool TWAP).
    ///      r12 (review M4): TWAP check on iff the RH ChainlinkStockSource has a TWAP pool for the stock — with the 150 bps
    ///      check on and no pool the relayed TWAP is 0 and the stock is Divergent for good. The RH deployment inputs
    ///      ORACLE_STOCKS / ORACLE_POOLS (same lists as DeployV3PriceSender) decide; absent = every stock has a pool.
    function _oracleParams(address underlying) internal view returns (SolonStockOracle.Params memory) {
        return SolonStockOracle.Params(
            15 minutes, 1_000, 200, 50, 26 hours, cfg.local || !rhTwapPoolListed(vm, underlying) ? 0 : 150
        );
    }

    function _underlyings() internal view returns (address[] memory u) {
        u = new address[](1 + cfg.extraUnderlyings.length);
        u[0] = cfg.stockUnderlying;
        for (uint256 i; i < cfg.extraUnderlyings.length; ++i) {
            u[i + 1] = cfg.extraUnderlyings[i];
        }
    }

    function _ticker(uint256 i) internal view returns (string memory) {
        return i == 0 ? cfg.stockTicker : cfg.extraTickers[i - 1];
    }

    function _tokenOf(uint256 i) internal view returns (address) {
        return i == 0 ? cfg.rewardAsset : cfg.extraTokens[i - 1];
    }

    /// @dev The extra stocks' listings, then every stock's oracle asset and cap (bootstrap window).
    function _listExtrasAndConfigure(address hub) internal {
        for (uint256 i; i < cfg.extraUnderlyings.length; ++i) {
            address t = vm.computeCreateAddress(hub, vm.getNonce(hub));
            _call(
                "SolonStockHub",
                abi.encodeCall(
                    SolonStockHub.listStock,
                    (
                        cfg.extraUnderlyings[i],
                        cfg.extraTickers[i],
                        cfg.rhEid,
                        cfg.rhChainId,
                        cfg.mintFloor,
                        _at(K_ARC_ROUTE),
                        RELAY_PATH
                    )
                )
            );
            require(address(SolonStockHub(payable(hub)).getListing(cfg.extraUnderlyings[i]).arc) == t, "extra token");
            cfg.extraTokens.push(t);
            _record(string.concat("StockToken_", cfg.extraTickers[i]), t);
        }
        address[] memory u = _underlyings();
        for (uint256 i; i < u.length; ++i) {
            gov.bootstrapCall(
                cfg.priceOracle,
                abi.encodeCall(
                    SolonStockOracle.configureAsset,
                    (u[i], _tokenOf(i), IStockPriceSource(cfg.oracleSource), _oracleParams(u[i]))
                )
            );
            _call("CapacityController", abi.encodeCall(CapacityController.setAssetCap, (u[i], cfg.assetCapsUsd[i] * 1e18)));
            if (cfg.local) SolonStockOracle(cfg.priceOracle).poke(_tokenOf(i)); // first accepted price
        }
        if (!cfg.local) {
            V3LzConfig.UlnConfig memory uln = V3LzConfig.defaults(cfg.rhConfirmations); // receive from RH
            _pinLibraries(cfg.oracleSource, false); // r12 (M2): receive-only OApp
            gov.bootstrapCall(
                cfg.lzEndpoint,
                abi.encodeCall(
                    IV3LzEndpointConfig.setConfig, (cfg.oracleSource, cfg.receiveLib, V3LzConfig.params(cfg.rhEid, uln))
                )
            );
            if (cfg.priceSender != address(0)) {
                gov.bootstrapCall(
                    cfg.oracleSource,
                    abi.encodeCall(RelayedStockSource.setPeer, (cfg.rhEid, bytes32(uint256(uint160(cfg.priceSender)))))
                );
            } else {
                opsTodo.push("RelayedStockSource.setPeer(rhEid, StockPriceSender) by the timelock");
            }
        }
    }

    function _adapterInit(address token, address underlying) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(SolonStockAdapter).creationCode,
            abi.encode(
                SolonStockAdapter.Config(
                    _at(K_ROUNDS),
                    vm.computeCreateAddress(_at(K_ROUNDS), 1), // RewardVault, created by the RoundManager
                    token,
                    underlying,
                    _at(K_HUB),
                    cfg.rewardQuoteSigner,
                    RELAY_PATH,
                    cfg.rhChainId,
                    _at(K_OPS),
                    cfg.priceOracle
                )
            )
        );
    }

    /// @dev r7 governance CREATEs, appended after the core (earlier addresses unchanged): one reward adapter per
    ///      extra stock, then the creator payout-stock registry.
    function _deployR7() internal {
        for (uint256 i; i < cfg.extraTokens.length; ++i) {
            _create(
                K_R7 + i,
                string.concat("SolonStockAdapter_", cfg.extraTickers[i]),
                _adapterInit(cfg.extraTokens[i], cfg.extraUnderlyings[i])
            );
        }
        _create(
            K_R7 + cfg.extraTokens.length,
            "LaunchPayoutChoice",
            abi.encodePacked(type(LaunchPayoutChoice).creationCode, abi.encode(address(gov), _at(K_HUB)))
        );
        // r8: the one-step USDC -> NVDA.sol -> meme router over pool A (NVDA only; one router per pool-A asset).
        _create(
            K_R7 + cfg.extraTokens.length + 1,
            "V3MultiHopRouter",
            abi.encodePacked(
                type(V3MultiHopRouter).creationCode,
                abi.encode(
                    cfg.poolManager,
                    deployed["V3QuoteFeeHook"],
                    StockPoolVault(payable(deployed["StockPoolVault"])).poolKey(),
                    deployed["EligibilityController"]
                )
            )
        );
    }

    /// @dev r7 wiring: extra reward routes, payout choices (1 = NVDA, then extras), factory binding.
    function _wireR7(address factory) internal {
        address hub = deployed["SolonStockHub"];
        for (uint256 i; i < cfg.extraTokens.length; ++i) {
            address adapter = deployed[string.concat("SolonStockAdapter_", cfg.extraTickers[i])];
            _call("SolonStockHub", abi.encodeCall(SolonStockHub.setRewardAdapter, (adapter, true)));
            _call(
                "StockAdapterRegistry",
                abi.encodeCall(
                    StockAdapterRegistry.register,
                    (
                        keccak256(bytes(cfg.extraTickers[i])),
                        cfg.rewardVersion,
                        StockAdapterRegistry.Route(
                            cfg.extraTokens[i],
                            cfg.extraUnderlyings[i],
                            hub,
                            adapter,
                            RELAY_PATH,
                            cfg.rhChainId,
                            true,
                            cfg.rewardFixedCost18
                        )
                    )
                )
            );
        }
        // Testnet drill finding (2026-10-01): a creator payout choice must be a bound eligibility asset, else
        // V3RewardToken._addAssetMask reverts "unbound eligibility asset" at launch (payoutChoiceId 2/3). NVDA.sol is
        // bound as id 0 in _wire; the extra stocks take ids 1.. (EligibilityController ids are immutable once bound).
        for (uint256 i; i < cfg.extraTokens.length; ++i) {
            _call("EligibilityController", abi.encodeCall(EligibilityController.bindAsset, (cfg.extraTokens[i], uint8(i + 1))));
        }
        _call("LaunchPayoutChoice", abi.encodeCall(LaunchPayoutChoice.bindFactory, (factory)));
        _call(
            "LaunchPayoutChoice",
            abi.encodeCall(
                LaunchPayoutChoice.approve,
                (cfg.rewardAsset, cfg.rewardAssetId, cfg.rewardVersion, cfg.rewardPricePolicy)
            )
        );
        for (uint256 i; i < cfg.extraTokens.length; ++i) {
            _call(
                "LaunchPayoutChoice",
                abi.encodeCall(
                    LaunchPayoutChoice.approve,
                    (cfg.extraTokens[i], keccak256(bytes(cfg.extraTickers[i])), cfg.rewardVersion, cfg.rewardPricePolicy)
                )
            );
        }
        _call(
            "V3LaunchFactory",
            abi.encodeCall(V3LaunchFactory.configurePayoutChoice, (deployed["LaunchPayoutChoice"]))
        );
        _wirePoolA();
    }

    /// @dev r8 pool A: initialize at the oracle tick when the price is Live inside the bootstrap (local; on a live
    ///      deployment the relayed price arrives later, so it becomes a timelock op), then the optional seed. The
    ///      first range is the keeper's (rebalanceRange is keeper-only and needs both sides in the vault).
    function _wirePoolA() internal {
        StockPoolVault v = StockPoolVault(payable(deployed["StockPoolVault"]));
        try OracleRefTickSigner(cfg.refTickSigner).refTickOf(cfg.rewardAsset) returns (int24 t) {
            cfg.poolAInitTick = t;
            cfg.poolAInitialized = true;
            _call("StockPoolVault", abi.encodeCall(StockPoolVault.initialize, (TickMath.getSqrtPriceAtTick(t))));
        } catch {
            opsTodo.push("StockPoolVault.initialize(sqrtPriceX96 at the Live oracle tick): timelock op (48h)");
        }
        if (cfg.poolASeedUsd == 0) {
            opsTodo.push("Pool A unfunded (POOL_A_FUND=false): treasury sends $1k+$1k+$1k reserve native USDC to it");
            return;
        }
        (bool ok,) = address(v).call{value: cfg.poolASeedUsd * 1e18}("");
        require(ok, "pool A seed");
        if (cfg.poolASeedStockRaw != 0) {
            require(IERC20(cfg.rewardAsset).transfer(address(v), cfg.poolASeedStockRaw), "pool A stock seed");
        }
    }

    /// @dev r13 (path 2a, 2026-10-01): launch with the hub's acceleration float on. A lower single-order
    ///      limit is the guardian/owner "lower at once" path (raising it later is the 48h proposal); the daily
    ///      float-advance floor follows the float size; the deployer seeds the float. RH side: DeployV3Reserve.
    function _floatMode(address hub) internal {
        CapacityController cap = CapacityController(_at(K_CAPACITY));
        if (cfg.lRunUsd * 1e18 < cap.lRun()) {
            _call(
                "CapacityController",
                abi.encodeCall(CapacityController.lowerLimits, (cfg.lRunUsd * 1e18, cap.uRun(), cap.totalCap()))
            );
        }
        if (!cfg.hubFloatEnabled) return;
        _call("SolonStockHub", abi.encodeCall(SolonStockHub.setFloatEnabled, (true)));
        _call("SolonStockHub", abi.encodeCall(SolonStockHub.setPayLimit, (cfg.hubPayFloorUsd * 1e18, 2_000)));
        if (cfg.hubFloatSeedUsd != 0) SolonStockHub(payable(hub)).fundFloat{value: cfg.hubFloatSeedUsd * 1e18}();
        opsTodo.push("float mode (2a): launcher + vault-worker + refund + canonical + float-watch keepers must run");
    }

    /// @dev Phase 5, Arc side: capacity, hub (owner = governance), scheduler, canonical gate, the fixed
    ///      Relay route, the NVDA.sol listing (the hub's first CREATE), DVN config, the reward adapter and
    ///      pool A's vault. Caps are the controller defaults ($10k / $1M / $1M, public $800k).
    function _deployStockLayer() internal {
        address g = address(gov);
        address hub = _at(K_HUB);
        _create(
            K_CAPACITY,
            "CapacityController",
            abi.encodePacked(type(CapacityController).creationCode, abi.encode(g, cfg.guardian))
        );
        _create(
            K_HUB,
            "SolonStockHub",
            abi.encodePacked(
                type(SolonStockHub).creationCode,
                abi.encode(cfg.lzEndpoint, cfg.treasury, cfg.stockFeeBps, g, _at(K_OPS), [cfg.hubFloatA, cfg.hubFloatB])
            )
        );
        _create(
            K_SCHEDULER,
            "OrderScheduler",
            abi.encodePacked(type(OrderScheduler).creationCode, abi.encode(hub, _at(K_CAPACITY)))
        );
        _create(
            K_GATE,
            "CanonicalGate",
            abi.encodePacked(
                type(CanonicalGate).creationCode,
                abi.encode(
                    cfg.cctpMessenger,
                    cfg.cctpTransmitter,
                    cfg.arcUsdc,
                    cfg.ethDomain,
                    cfg.ethTokenMessenger,
                    hub,
                    cfg.gateFunds,
                    g
                )
            )
        );
        _create(
            K_ARC_ROUTE,
            "RelayFundingRoute",
            abi.encodePacked(
                type(RelayFundingRoute).creationCode,
                abi.encode(
                    RelayFundingRoute.Config(
                        hub,
                        address(0),
                        cfg.reserveVault,
                        cfg.rhChainId,
                        cfg.relayDepository,
                        cfg.fundingSigner,
                        cfg.relayReturnExecutor,
                        cfg.arcUsdc // r14: Relay prices Arc USDC as the 0x3600 view -> depositErc20 on it
                    )
                )
            )
        );
        cfg.capacity = _at(K_CAPACITY);
        _call("CapacityController", abi.encodeCall(CapacityController.bind, (hub, _at(K_ROUNDS))));
        _call(
            "SolonStockHub",
            abi.encodeCall(
                SolonStockHub.setCapacity, (CapacityController(cfg.capacity), OrderScheduler(_at(K_SCHEDULER)))
            )
        );
        _call("SolonStockHub", abi.encodeCall(SolonStockHub.setCanonicalGate, (_at(K_GATE))));
        _call(
            "SolonStockHub",
            abi.encodeCall(SolonStockHub.setPeer, (cfg.rhEid, bytes32(uint256(uint160(cfg.reserveVault)))))
        );
        address token = vm.computeCreateAddress(hub, vm.getNonce(hub));
        _call(
            "SolonStockHub",
            abi.encodeCall(
                SolonStockHub.listStock,
                (
                    cfg.stockUnderlying,
                    cfg.stockTicker,
                    cfg.rhEid,
                    cfg.rhChainId,
                    cfg.mintFloor,
                    _at(K_ARC_ROUTE),
                    RELAY_PATH
                )
            )
        );
        require(address(SolonStockHub(payable(hub)).getListing(cfg.stockUnderlying).arc) == token, "stock token");
        cfg.rewardAsset = token;
        cfg.stockStatus = hub;
        _record("StockToken", token);
        _listExtrasAndConfigure(hub);
        _call("SolonStockHub", abi.encodeCall(Guarded.setGuardian, (cfg.guardian)));
        _call("SolonStockHub", abi.encodeCall(SolonStockHub.setKeeper, (cfg.stockKeeper)));
        _floatMode(hub);
        _call("CanonicalGate", abi.encodeCall(CanonicalGate.setKeeper, (cfg.stockKeeper)));
        if (cfg.ethBridger != address(0)) {
            _call("CanonicalGate", abi.encodeCall(CanonicalGate.setBridger, (cfg.ethBridger)));
        }
        // r12 (review M2): pin ULN302 as the hub's send + receive library toward RH (never the endpoint default).
        _pinLibraries(hub, true);
        // Owner decision 2026-09-30: 2-of-3 DVNs on both libraries (real per-chain sets since r9, see V3LzConfig).
        // r9: send uses the Arc confirmations, receive the RH ones (DVNs attest with the sender's count).
        gov.bootstrapCall(
            cfg.lzEndpoint,
            abi.encodeCall(
                IV3LzEndpointConfig.setConfig,
                (hub, cfg.sendLib, V3LzConfig.params(cfg.rhEid, V3LzConfig.defaults(cfg.confirmations)))
            )
        );
        gov.bootstrapCall(
            cfg.lzEndpoint,
            abi.encodeCall(
                IV3LzEndpointConfig.setConfig,
                (hub, cfg.receiveLib, V3LzConfig.params(cfg.rhEid, V3LzConfig.defaults(cfg.rhConfirmations)))
            )
        );
        _create(K_STOCK_ADAPTER, "SolonStockAdapter", _adapterInit(token, cfg.stockUnderlying));
        _call("SolonStockHub", abi.encodeCall(SolonStockHub.setRewardAdapter, (_at(K_STOCK_ADAPTER), true)));
        _create(
            K_POOL_VAULT,
            "StockPoolVault",
            abi.encodePacked(
                type(StockPoolVault).creationCode,
                abi.encode(
                    StockPoolVault.Config(
                        IPoolManager(cfg.poolManager),
                        token,
                        cfg.stockUnderlying,
                        hub,
                        cfg.treasury,
                        cfg.stockKeeper,
                        cfg.refTickSigner, // r7: refTick bound to SolonStockOracle (ERC-1271)
                        g,
                        cfg.reserveRecipient
                    )
                )
            )
        );
    }

    function _deployPhase3And4() internal {
        address g = address(gov);
        _create(
            K_LEDGER,
            "V3FeeLedger",
            abi.encodePacked(type(V3FeeLedger).creationCode, abi.encode(_at(K_FACTORY), cfg.nativeUsdcView))
        );
        _create(
            K_CONTROLLER,
            "EligibilityController",
            abi.encodePacked(type(EligibilityController).creationCode, abi.encode(g))
        );
        _create(
            K_ELIGIBILITY_REGISTRY,
            "EligibilityRegistry",
            abi.encodePacked(type(EligibilityRegistry).creationCode, abi.encode(g))
        );
        _create(
            K_PAYOUT,
            "RewardPayoutVault",
            abi.encodePacked(type(RewardPayoutVault).creationCode, abi.encode(new address[](0), _at(K_CONTROLLER)))
        );
        _create(
            K_ADAPTER_REGISTRY,
            "StockAdapterRegistry",
            abi.encodePacked(type(StockAdapterRegistry).creationCode, abi.encode(g))
        );
        _create(
            K_ROUNDS,
            "RewardRoundManager",
            abi.encodePacked(
                type(RewardRoundManager).creationCode,
                abi.encode(g, _at(K_ADAPTER_REGISTRY), _at(K_PAYOUT), cfg.treasury)
            )
        );
        _record("RewardVault", address(RewardRoundManager(payable(_at(K_ROUNDS))).vault()));
        require(deployed["RewardVault"] == vm.computeCreateAddress(_at(K_ROUNDS), 1), "reward vault address");
        _create(
            K_BATCHER, "RewardBatcher", abi.encodePacked(type(RewardBatcher).creationCode, abi.encode(_at(K_ROUNDS)))
        );
        _create(
            K_DISTRIBUTOR,
            "RewardDistributor",
            abi.encodePacked(type(RewardDistributor).creationCode, abi.encode(_at(K_PAYOUT), cfg.priceOracle))
        );
        {
            address[] memory assets = new address[](1);
            assets[0] = cfg.rewardAsset;
            bytes32[] memory ids = new bytes32[](1);
            ids[0] = cfg.rewardAssetId;
            uint32[] memory versions = new uint32[](1);
            versions[0] = cfg.rewardVersion;
            bytes32[] memory prices = new bytes32[](1);
            prices[0] = cfg.rewardPricePolicy;
            _create(
                K_CALENDAR,
                "RewardAssetSchedule",
                abi.encodePacked(
                    type(RewardAssetSchedule).creationCode,
                    abi.encode(cfg.deployTime / 1 days, uint256(1), assets, ids, versions, prices)
                )
            );
        }
        _deployPhase3And4Tail(g);
    }

    /// @dev Second half of `_deployPhase3And4` (same order, same CREATE nonces); split only so
    ///      `forge coverage --ir-minimum` stays within the stack limit.
    function _deployPhase3And4Tail(address g) internal {
        _create(K_SINK, "BurnSink", type(BurnSink).creationCode);
        _create(
            K_DESK_REWARDS,
            "DeskRewards",
            abi.encodePacked(type(DeskRewards).creationCode, abi.encode(_at(K_LEDGER), g))
        );
        _create(
            K_PROTOCOL,
            "ProtocolVault",
            abi.encodePacked(type(ProtocolVault).creationCode, abi.encode(g, cfg.treasury, _at(K_OPS), _at(K_LEDGER)))
        );
        _create(
            K_OPS,
            "OpsVault",
            abi.encodePacked(type(OpsVault).creationCode, abi.encode(g, _at(K_PROTOCOL), cfg.opsVerifier))
        );
        _create(
            K_DESK,
            "DeskNFT",
            abi.encodePacked(
                type(DeskNFT).creationCode,
                abi.encode(
                    g,
                    cfg.solon,
                    _at(K_SINK),
                    _at(K_DESK_REWARDS),
                    _at(K_PROTOCOL),
                    _at(K_CONTROLLER),
                    DeskNFT.Quote(
                        cfg.solUsd18, cfg.usdcUsd18, cfg.deployTime, 1, keccak256("solon.v3.desk.surcharge.v1")
                    )
                )
            )
        );
        _create(
            K_BUYBACK_ROUTE,
            "FixedV4BuybackRoute",
            abi.encodePacked(
                type(FixedV4BuybackRoute).creationCode, abi.encode(_at(K_BUYBACK), cfg.solonFeeRouter, _solonKey())
            )
        );
        _create(
            K_BUYBACK,
            "BuybackBurnExecutor",
            abi.encodePacked(
                type(BuybackBurnExecutor).creationCode,
                abi.encode(
                    BuybackBurnExecutor.Config(
                        g,
                        cfg.solon,
                        _at(K_LEDGER),
                        _at(K_BUYBACK_ROUTE),
                        keccak256(abi.encode(_solonKey())),
                        cfg.buybackSigner,
                        _at(K_SINK),
                        _at(K_PROTOCOL_DESK)
                    )
                )
            )
        );
        _record("BuybackVault", BuybackBurnExecutor(payable(_at(K_BUYBACK))).vault());
        _create(
            K_PROTOCOL_DESK,
            "ProtocolDeskVault",
            abi.encodePacked(
                type(ProtocolDeskVault).creationCode,
                abi.encode(_at(K_DESK), cfg.solon, _at(K_SINK), _at(K_BUYBACK), _at(K_OPS))
            )
        );
        _create(
            K_STAKING,
            "SolonStakingV2",
            abi.encodePacked(type(SolonStakingV2).creationCode, abi.encode(cfg.solon, _at(K_LEDGER), _at(K_CONTROLLER)))
        );
        _record("StakingRewardSourceFactory", address(SolonStakingV2(payable(_at(K_STAKING))).sourceFactory()));
        _create(
            K_STOCK_SELL_ROUTE,
            "StockFeeSellRoute",
            abi.encodePacked(
                type(SolonStockSellRoute).creationCode, abi.encode(_at(K_HUB), _at(K_STOCK_CONVERTER), _at(K_OPS))
            )
        );
        _create(
            K_STOCK_CONVERTER,
            "StockFeeConverter",
            abi.encodePacked(
                type(StockFeeConverter).creationCode,
                abi.encode(
                    _at(K_LEDGER),
                    cfg.stockFeeSigner,
                    _at(K_STOCK_SELL_ROUTE),
                    _at(K_BUYBACK),
                    _at(K_PROTOCOL),
                    _at(K_OPS),
                    cfg.stockFeeBps,
                    uint32(1),
                    RELAY_PATH,
                    g,
                    cfg.priceOracle
                )
            )
        );
        _create(
            K_V2_INGRESS,
            "V2FeeIngress",
            abi.encodePacked(type(V2FeeIngress).creationCode, abi.encode(g, cfg.auditors, cfg.v2Funder, cfg.v2Cutover))
        );
        _create(
            K_V2_ROUTER,
            "V2PlatformRouter",
            abi.encodePacked(
                type(V2PlatformRouter).creationCode,
                abi.encode(g, _at(K_V2_INGRESS), _at(K_STAKING), _at(K_BUYBACK), _at(K_SINK))
            )
        );
        _create(
            K_V2_SELL_ROUTE,
            "V2FeeSellRoute",
            abi.encodePacked(
                type(FixedV4FeeSellRoute).creationCode, abi.encode(_at(K_V2_CONVERTER), cfg.sellSwapRouter, _solonKey())
            )
        );
        _create(
            K_V2_CONVERTER,
            "V2FeeConverter",
            abi.encodePacked(
                type(V2FeeConverter).creationCode,
                abi.encode(
                    _at(K_V2_ROUTER),
                    _at(K_V2_SELL_ROUTE),
                    cfg.v2Signer,
                    _at(K_OPS),
                    keccak256(abi.encode(_solonKey())),
                    uint32(1)
                )
            )
        );
    }

    function _deployCore() internal {
        address factory = _at(K_FACTORY);
        address ledger = deployed["V3FeeLedger"];
        _create(
            K_RIGHTS,
            "CreatorRightsNFT",
            abi.encodePacked(
                type(CreatorRightsNFT).creationCode, abi.encode(factory, ledger, deployed["EligibilityController"])
            )
        );
        _create(
            K_STRATEGY,
            "V3LaunchStrategy",
            abi.encodePacked(type(V3LaunchStrategy).creationCode, abi.encode(factory, cfg.positionManager))
        );
        _create(
            K_LOCKER,
            "V3LPLocker",
            abi.encodePacked(type(V3LPLocker).creationCode, abi.encode(factory, cfg.positionManager))
        );
        bytes memory hookInit =
            abi.encodePacked(type(V3QuoteFeeHook).creationCode, abi.encode(cfg.poolManager, factory, ledger));
        (address mined, bytes32 salt) =
            V3HookMiner.find(CREATE2_FACTORY, keccak256(hookInit), cfg.hookSaltStart, 1_000_000);
        V3QuoteFeeHook hook =
            new V3QuoteFeeHook{salt: salt}(IPoolManager(cfg.poolManager), factory, IV3HookFeeLedger(ledger));
        require(address(hook) == mined, "hook address");
        _record("V3QuoteFeeHook", address(hook));
        hookSalt = salt;
        address[] memory custodians = new address[](8);
        custodians[0] = deployed["RewardVault"];
        custodians[1] = deployed["RewardPayoutVault"];
        custodians[2] = deployed["BuybackVault"];
        custodians[3] = deployed["ProtocolDeskVault"];
        custodians[4] = deployed["BurnSink"];
        custodians[5] = deployed["OpsVault"];
        custodians[6] = deployed["DeskNFT"];
        custodians[7] = deployed["V2PlatformRouter"];
        V3LaunchFactory.QuoteConfig[] memory quotes;
        if (cfg.stockStatus != address(0)) {
            quotes = new V3LaunchFactory.QuoteConfig[](1);
            quotes[0] = V3LaunchFactory.QuoteConfig(1, cfg.rewardAsset, cfg.rewardAssetId, cfg.stockUnderlying);
            require(cfg.stockUnderlying != address(0), "STOCK_QUOTE_UNDERLYING");
        }
        V3LaunchFactory.Components memory c = V3LaunchFactory.Components(
            V3FeeLedger(payable(ledger)),
            hook,
            V3LaunchStrategy(payable(deployed["V3LaunchStrategy"])),
            IPositionManager(cfg.positionManager),
            deployed["V3LPLocker"],
            deployed["CreatorRightsNFT"],
            cfg.rewardAsset,
            [
                deployed["DeskRewards"],
                deployed["SolonStakingV2"],
                deployed["BuybackBurnExecutor"],
                deployed["ProtocolVault"]
            ],
            cfg.priceOracle,
            cfg.stockStatus,
            deployed["OpsVault"],
            custodians
        );
        factoryInitSize = abi.encodePacked(type(V3LaunchFactory).creationCode, abi.encode(c, quotes)).length;
        require(factoryInitSize <= 49152, "factory initcode > EIP-3860");
        _create(
            K_FACTORY, "V3LaunchFactory", abi.encodePacked(type(V3LaunchFactory).creationCode, abi.encode(c, quotes))
        );
        _create(
            K_ROUTER,
            "V3Router",
            abi.encodePacked(
                type(V3Router).creationCode,
                abi.encode(cfg.poolManager, address(hook), deployed["EligibilityController"])
            )
        );
        _create(K_QUOTER, "V3Quoter", abi.encodePacked(type(V3Quoter).creationCode, abi.encode(deployed["V3Router"])));
    }

    bytes32 internal hookSalt;
    uint256 internal factoryInitSize;

    function _call(string memory name, bytes memory data) internal {
        gov.bootstrapCall(deployed[name], data);
    }

    /// @dev One-shot wiring, executed by governance inside the bootstrap window.
    function _wire() internal {
        address factory = deployed["V3LaunchFactory"];
        address desk = deployed["DeskRewards"];
        address staking = deployed["SolonStakingV2"];
        address payout = deployed["RewardPayoutVault"];
        address rounds = deployed["RewardRoundManager"];
        address calendar = deployed["RewardAssetSchedule"];
        address converter = deployed["StockFeeConverter"];
        // Eligibility stays in default B: only the asset identity is frozen (needed before any A schedule).
        _call("EligibilityController", abi.encodeCall(EligibilityController.bindAsset, (cfg.rewardAsset, 0)));
        _call("EligibilityRegistry", abi.encodeCall(EligibilityRegistry.configureFactory, (factory)));
        _call("EligibilityRegistry", abi.encodeCall(EligibilityRegistry.setFixedModules, (desk, staking)));
        _call("RewardPayoutVault", abi.encodeCall(RewardPayoutVault.configureFactory, (factory)));
        _call("RewardPayoutVault", abi.encodeCall(RewardPayoutVault.configureRewardModules, (desk, staking)));
        _call(
            "RewardPayoutVault", abi.encodeCall(RewardPayoutVault.configureDistributor, (deployed["RewardDistributor"]))
        );
        _call("RewardRoundManager", abi.encodeCall(RewardRoundManager.configureSourceFactory, (factory)));
        _call("RewardRoundManager", abi.encodeCall(RewardRoundManager.configureRewardModules, (desk, staking)));
        _call(
            "RewardRoundManager",
            abi.encodeCall(RewardRoundManager.configureExecution, (deployed["RewardBatcher"], cfg.capacity))
        );
        _call(
            "StockAdapterRegistry",
            abi.encodeCall(
                StockAdapterRegistry.register,
                (
                    cfg.rewardAssetId,
                    cfg.rewardVersion,
                    StockAdapterRegistry.Route(
                        cfg.rewardAsset,
                        cfg.stockUnderlying,
                        deployed["SolonStockHub"],
                        deployed["SolonStockAdapter"],
                        RELAY_PATH,
                        cfg.rhChainId,
                        true,
                        cfg.rewardFixedCost18
                    )
                )
            )
        );
        _call("V3LaunchFactory", abi.encodeCall(V3LaunchFactory.configureAssetSchedule, (calendar)));
        _call("V3LaunchFactory", abi.encodeCall(V3LaunchFactory.configureStockFeeConverter, (converter)));
        _call(
            "V3LaunchFactory",
            abi.encodeCall(
                V3LaunchFactory.configureRewardInfrastructure,
                (
                    deployed["EligibilityController"],
                    payout,
                    rounds,
                    cfg.rewardAssetId,
                    cfg.rewardVersion,
                    cfg.rewardPricePolicy
                )
            )
        );
        _call("DeskRewards", abi.encodeCall(DeskRewards.configureNFT, (DeskNFT(payable(deployed["DeskNFT"])))));
        _call("DeskRewards", abi.encodeCall(DeskRewards.configureRounds, (rounds, payout, calendar)));
        _call("DeskRewards", abi.encodeCall(DeskRewards.configureProtocolStaking, (staking)));
        {
            address[] memory royalty = new address[](1);
            royalty[0] = cfg.rewardAsset;
            _call("DeskRewards", abi.encodeCall(DeskRewards.configureRoyaltyAssets, (royalty)));
        }
        _call("DeskNFT", abi.encodeCall(DeskNFT.configureProtocolVault, (deployed["ProtocolDeskVault"])));
        if (cfg.priceOracle.code.length != 0) {
            _call("DeskNFT", abi.encodeCall(DeskNFT.configureServicePolicy, (deployed["RewardDistributor"])));
        }
        _call("OpsVault", abi.encodeCall(OpsVault.configureDesk, (deployed["DeskNFT"], deployed["ProtocolDeskVault"])));
        _call("OpsVault", abi.encodeCall(OpsVault.configureSubsidyTarget, (uint8(6), converter)));
        _call("ProtocolVault", abi.encodeCall(ProtocolVault.configureSources, (converter, deployed["DeskNFT"])));
        _call(
            "BuybackBurnExecutor",
            abi.encodeCall(BuybackBurnExecutor.configureSources, (converter, deployed["V2PlatformRouter"]))
        );
        _call("SolonStakingV2", abi.encodeCall(SolonStakingV2.configureRewards, (rounds, payout)));
        _call(
            "SolonStakingV2",
            abi.encodeCall(
                SolonStakingV2.configureProtocolDesk,
                (desk, cfg.rewardAsset, cfg.rewardAssetId, cfg.rewardVersion, cfg.rewardPricePolicy)
            )
        );
        _call(
            "SolonStakingV2",
            abi.encodeCall(
                SolonStakingV2.configureV2,
                (
                    deployed["V2PlatformRouter"],
                    cfg.rewardAsset,
                    cfg.rewardAssetId,
                    cfg.rewardVersion,
                    cfg.rewardPricePolicy
                )
            )
        );
        _call("V2FeeIngress", abi.encodeCall(V2FeeIngress.setRouter, (deployed["V2PlatformRouter"])));
        _call("V2PlatformRouter", abi.encodeCall(V2PlatformRouter.setConverter, (deployed["V2FeeConverter"])));
        _wireR7(factory);
    }

    // ---------------------------------------------------------------- manifest

    function _record(string memory name, address a) internal {
        require(a != address(0) && deployed[name] == address(0), name);
        deployed[name] = a;
        names.push(name);
    }

    function _writeManifest() internal {
        string memory contracts = "contracts";
        string memory hashes = "codehashes";
        string memory c;
        string memory h;
        for (uint256 i; i < names.length; ++i) {
            c = vm.serializeAddress(contracts, names[i], deployed[names[i]]);
            h = vm.serializeBytes32(hashes, names[i], deployed[names[i]].codehash);
        }
        string memory conf = "config";
        vm.serializeAddress(conf, "multisig", cfg.multisig);
        vm.serializeAddress(conf, "guardian", cfg.guardian);
        vm.serializeAddress(conf, "deployer", cfg.deployer);
        vm.serializeAddress(conf, "treasury", cfg.treasury);
        vm.serializeAddress(conf, "opsVerifier", cfg.opsVerifier);
        vm.serializeAddress(conf, "buybackSigner", cfg.buybackSigner);
        vm.serializeAddress(conf, "stockFeeSigner", cfg.stockFeeSigner);
        vm.serializeAddress(conf, "v2Signer", cfg.v2Signer);
        vm.serializeAddress(conf, "poolManager", cfg.poolManager);
        vm.serializeAddress(conf, "positionManager", cfg.positionManager);
        vm.serializeAddress(conf, "sellSwapRouter", cfg.sellSwapRouter);
        vm.serializeAddress(conf, "solonFeeRouter", cfg.solonFeeRouter);
        vm.serializeAddress(conf, "solon", cfg.solon);
        vm.serializeAddress(conf, "rewardAsset", cfg.rewardAsset);
        vm.serializeAddress(conf, "nativeUsdcView", cfg.nativeUsdcView);
        vm.serializeAddress(conf, "priceOracle", cfg.priceOracle);
        vm.serializeAddress(conf, "oracleSource", cfg.oracleSource);
        vm.serializeAddress(conf, "refTickSigner", cfg.refTickSigner);
        vm.serializeAddress(conf, "priceSender", cfg.priceSender);
        vm.serializeAddress(conf, "extraUnderlyings", cfg.extraUnderlyings);
        vm.serializeString(conf, "extraTickers", cfg.extraTickers);
        vm.serializeAddress(conf, "extraTokens", cfg.extraTokens);
        vm.serializeUint(conf, "assetCapsUsd", cfg.assetCapsUsd);
        vm.serializeAddress(conf, "stockStatus", cfg.stockStatus);
        vm.serializeUint(conf, "poolASeedUsd", cfg.poolASeedUsd);
        vm.serializeUint(conf, "poolASeedStockRaw", cfg.poolASeedStockRaw);
        vm.serializeUint(conf, "poolAPoolUsd", cfg.poolAPoolUsd);
        vm.serializeUint(conf, "poolAStockUsd", cfg.poolAStockUsd);
        vm.serializeUint(conf, "poolAReserveUsd", cfg.poolAReserveUsd);
        vm.serializeBool(conf, "poolAInitialized", cfg.poolAInitialized);
        vm.serializeInt(conf, "poolAInitTick", cfg.poolAInitTick);
        vm.serializeAddress(conf, "capacity", cfg.capacity);
        vm.serializeBytes32(conf, "rewardAssetId", cfg.rewardAssetId);
        vm.serializeUint(conf, "rewardAdapterVersion", cfg.rewardVersion);
        vm.serializeBytes32(conf, "rewardPricePolicy", cfg.rewardPricePolicy);
        vm.serializeUint(conf, "stockFeeBps", cfg.stockFeeBps);
        vm.serializeUint(conf, "stockPoolFee", cfg.stockPoolFee);
        vm.serializeInt(conf, "stockPoolTickSpacing", cfg.stockPoolSpacing);
        vm.serializeUint(conf, "solonPoolFee", cfg.solonPoolFee);
        vm.serializeInt(conf, "solonPoolTickSpacing", cfg.solonPoolSpacing);
        vm.serializeUint(conf, "v2CutoverBlock", cfg.v2Cutover);
        vm.serializeAddress(conf, "v2Funder", cfg.v2Funder);
        vm.serializeAddress(conf, "v2Auditor0", cfg.auditors[0]);
        vm.serializeAddress(conf, "v2Auditor1", cfg.auditors[1]);
        vm.serializeAddress(conf, "v2Auditor2", cfg.auditors[2]);
        vm.serializeUint(conf, "minDelay", gov.MIN_DELAY());
        vm.serializeUint(conf, "deployTimestamp", cfg.deployTime);
        vm.serializeUint(conf, "feeSplitBps", _split());
        vm.serializeUint(conf, "deskMaxSupply", 5000);
        vm.serializeUint(conf, "deskSolonPerCard", 100000e18);
        vm.serializeUint(conf, "protocolDeskMax", 1000);
        vm.serializeUint(conf, "factoryInitcodeBytes", factoryInitSize);
        vm.serializeBytes32(conf, "hookSalt", hookSalt);
        vm.serializeBool(conf, "eligibilityModeA", false);
        vm.serializeBool(conf, "localStandIns", cfg.local);
        _serializeStock(conf);
        string memory confJson = vm.serializeString(conf, "opsTodo", opsTodo);
        string memory root = "manifest";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployedAtBlock", block.number);
        vm.serializeString(root, "standIns", standIns);
        vm.serializeString(root, "contracts", c);
        vm.serializeString(root, "codehashes", h);
        string memory json = vm.serializeString(root, "config", confJson);
        manifestJson = json;
        string memory path = vm.envOr(
            "MANIFEST_PATH", string.concat(vm.projectRoot(), "/script/v3/out/v3-", vm.toString(block.chainid), ".json")
        );
        // The repo's foundry.toml grants no write access outside ./test (read-only), so the
        // manifest is always emitted on one log line; script/v3/run-local.sh saves it to
        // script/v3/out/. A direct file write is attempted where fs_permissions allow it.
        try vm.writeJson(json, path) {
            console2.log("V3 manifest written", path);
        } catch {
            console2.log("V3 manifest not written (fs_permissions)", path);
        }
        console2.log(string.concat("V3_MANIFEST_JSON=", json));
        console2.log("V3Governance", address(gov));
        console2.log("V3LaunchFactory", deployed["V3LaunchFactory"]);
    }

    function _serializeStock(string memory conf) internal {
        vm.serializeAddress(conf, "lzEndpoint", cfg.lzEndpoint);
        vm.serializeUint(conf, "arcEid", cfg.arcEid);
        vm.serializeUint(conf, "rhEid", cfg.rhEid);
        vm.serializeUint(conf, "rhChainId", cfg.rhChainId);
        vm.serializeAddress(conf, "reserveVault", cfg.reserveVault);
        vm.serializeAddress(conf, "stockUnderlying", cfg.stockUnderlying);
        vm.serializeString(conf, "stockTicker", cfg.stockTicker);
        vm.serializeUint(conf, "mintFloor", cfg.mintFloor);
        vm.serializeAddress(conf, "relayDepository", cfg.relayDepository);
        vm.serializeAddress(conf, "relayReturnExecutor", cfg.relayReturnExecutor);
        vm.serializeAddress(conf, "fundingSigner", cfg.fundingSigner);
        vm.serializeAddress(conf, "rewardQuoteSigner", cfg.rewardQuoteSigner);
        vm.serializeAddress(conf, "stockKeeper", cfg.stockKeeper);
        vm.serializeAddress(conf, "reserveRecipient", cfg.reserveRecipient);
        vm.serializeAddress(conf, "cctpMessenger", cfg.cctpMessenger);
        vm.serializeAddress(conf, "cctpTransmitter", cfg.cctpTransmitter);
        vm.serializeAddress(conf, "arcUsdc", cfg.arcUsdc);
        vm.serializeUint(conf, "ethDomain", cfg.ethDomain);
        vm.serializeAddress(conf, "ethTokenMessenger", cfg.ethTokenMessenger);
        vm.serializeAddress(conf, "ethBridger", cfg.ethBridger);
        vm.serializeAddress(conf, "gateFunds", cfg.gateFunds);
        vm.serializeAddress(conf, "hubFloatA", cfg.hubFloatA);
        vm.serializeAddress(conf, "hubFloatB", cfg.hubFloatB);
        vm.serializeBool(conf, "hubFloatEnabled", cfg.hubFloatEnabled);
        vm.serializeUint(conf, "hubFloatSeedUsd", cfg.hubFloatSeedUsd);
        vm.serializeUint(conf, "hubPayFloorUsd", cfg.hubPayFloorUsd);
        vm.serializeUint(conf, "lRunUsd", cfg.lRunUsd);
        vm.serializeUint(conf, "rewardFixedCost18", cfg.rewardFixedCost18);
        vm.serializeAddress(conf, "sendLib", cfg.sendLib);
        vm.serializeAddress(conf, "receiveLib", cfg.receiveLib);
        vm.serializeUint(conf, "confirmations", cfg.confirmations);
        vm.serializeUint(conf, "rhConfirmations", cfg.rhConfirmations);
        vm.serializeBool(conf, "dvnPlaceholders", V3LzConfig.placeholder(V3LzConfig.defaults(0)));
        CapacityController cap = CapacityController(cfg.capacity);
        vm.serializeUint(conf, "capLRun", cap.lRun());
        vm.serializeUint(conf, "capURun", cap.uRun());
        vm.serializeUint(conf, "capTotal", cap.totalCap());
        vm.serializeUint(conf, "capMinOrder", cap.minOrderUsd());
        if (cfg.local) vm.serializeAddress(conf, "reserveOwner", cfg.multisig);
    }

    function _localFees(uint256 n) internal pure returns (uint24[] memory f) {
        f = new uint24[](n);
        for (uint256 i; i < n; ++i) {
            f[i] = 3000;
        }
    }

    function _split() internal pure returns (uint256[] memory s) {
        s = new uint256[](6);
        (s[0], s[1], s[2], s[3], s[4], s[5]) = (5750, 1000, 1000, 500, 1000, 750);
    }
}
