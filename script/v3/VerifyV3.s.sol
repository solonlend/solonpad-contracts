// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Script, console2} from "forge-std/Script.sol";
import {V3Governance} from "../../src/v3/governance/V3Governance.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {V3QuoteFeeHook} from "../../src/v3/V3QuoteFeeHook.sol";
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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeskNFT as DeskNFTType} from "../../src/v3/DeskNFT.sol";
import {SolonStockHub} from "../../src/v3/stock/SolonStockHub.sol";
import {HubSettlement} from "../../src/v3/stock/HubSettlement.sol";
import {CapacityController} from "../../src/v3/stock/CapacityController.sol";
import {OrderScheduler} from "../../src/v3/stock/OrderScheduler.sol";
import {CanonicalGate} from "../../src/v3/stock/CanonicalGate.sol";
import {RelayFundingRoute} from "../../src/v3/stock/RelayFundingRoute.sol";
import {SolonStockSellRoute} from "../../src/v3/stock/SolonStockSellRoute.sol";
import {SolonStockToken} from "../../src/v3/stock/SolonStockToken.sol";
import {StockPoolVault} from "../../src/v3/stock/StockPoolVault.sol";
import {SolonStockAdapter} from "../../src/v3/adapters/SolonStockAdapter.sol";
import {SolonStockOracle} from "../../src/v3/oracle/SolonStockOracle.sol";
import {ChainlinkStockSource} from "../../src/v3/oracle/ChainlinkStockSource.sol";
import {RelayedStockSource} from "../../src/v3/oracle/RelayedStockSource.sol";
import {OracleRefTickSigner} from "../../src/v3/oracle/OracleRefTickSigner.sol";
import {LaunchPayoutChoice} from "../../src/v3/LaunchPayoutChoice.sol";
import {V3MultiHopRouter, IV3HopEligibility} from "../../src/v3/V3MultiHopRouter.sol";
import {ReserveVault} from "../../src/v3/stock/robinhood/ReserveVault.sol";
import {RestrictedVenue} from "../../src/v3/stock/robinhood/RestrictedVenue.sol";
import {V3LzConfig, IV3LzEndpointConfig} from "./V3LzConfig.sol";
import {rhTwapPoolListed} from "./V3OracleConfig.sol";
import {V3ReserveVerifier} from "./DeployV3Reserve.s.sol";

/// @notice Read-only verification of a DeployV3 manifest against live chain state.
/// Never broadcasts. Local reference deployments below exist only in this simulation and
/// prove that live runtime code equals this checkout's compiled source with the live args.
/// Env: MANIFEST_JSON (manifest content), else MANIFEST_PATH (default script/v3/out/v3-<chainid>.json,
/// which needs fs read permission for that path).
contract VerifyV3 is V3ReserveVerifier {
    using StateLibrary for IPoolManager;

    string internal json;
    uint256 public checks;

    function _a(string memory name) internal view returns (address payable) {
        return payable(vm.parseJsonAddress(json, string.concat(".contracts.", name)));
    }

    /// @dev r13: numeric/bool manifest config with a default for manifests written before the key existed.
    function _cfgUint(string memory path, uint256 dflt) internal view returns (uint256) {
        return vm.keyExistsJson(json, path) ? vm.parseJsonUint(json, path) : dflt;
    }

    function _cfgBool(string memory path, bool dflt) internal view returns (bool) {
        return vm.keyExistsJson(json, path) ? vm.parseJsonBool(json, path) : dflt;
    }

    function _c(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(json, string.concat(".config.", key));
    }

    function _eq(address x, address y, string memory what) internal {
        require(x == y, what);
        ++checks;
    }

    function _true(bool ok, string memory what) internal {
        require(ok, what);
        ++checks;
    }

    function run() external {
        string memory path = vm.envOr(
            "MANIFEST_PATH", string.concat(vm.projectRoot(), "/script/v3/out/v3-", vm.toString(block.chainid), ".json")
        );
        json = vm.envOr("MANIFEST_JSON", string(""));
        if (bytes(json).length == 0) json = vm.readFile(path);
        _verify();
    }

    /// @notice r13: the same checks on a manifest passed in directly (forge tests run suites in parallel and
    ///         MANIFEST_JSON is process-wide).
    function runWith(string memory manifest) external {
        json = manifest;
        _verify();
    }

    function _verify() internal {
        _true(vm.parseJsonUint(json, ".chainId") == block.chainid, "chainId");
        _codehashes();
        _governance();
        _roles();
        _wiring();
        _policy();
        _stockRoles();
        _stockWiring();
        _stockPolicy();
        _r7Oracle();
        _r7Stocks();
        _r8PoolA();
        _reserveSide();
        _reproducedCode();
        _reproducedStockCode();
        _reproducedR7();
        console2.log("VerifyV3 checks passed", checks + reserveChecks);
    }

    function _codehashes() internal {
        string[] memory names = vm.parseJsonKeys(json, ".contracts");
        for (uint256 i; i < names.length; ++i) {
            address a = _a(names[i]);
            bytes32 expected = vm.parseJsonBytes32(json, string.concat(".codehashes.", names[i]));
            _true(a.code.length != 0 && a.codehash == expected, string.concat("codehash ", names[i]));
        }
    }

    function _governance() internal {
        V3Governance gov = V3Governance(payable(_a("V3Governance")));
        address multisig = _c("multisig");
        address guardian = _c("guardian");
        _true(gov.getMinDelay() == 48 hours && gov.MIN_DELAY() == 48 hours, "min delay");
        _true(gov.bootstrapClosed(), "bootstrap closed");
        _true(gov.hasRole(gov.PROPOSER_ROLE(), multisig), "proposer");
        _true(gov.hasRole(gov.CANCELLER_ROLE(), multisig), "multisig canceller");
        _true(gov.hasRole(gov.CANCELLER_ROLE(), guardian) && gov.hasRole(gov.GUARDIAN_ROLE(), guardian), "guardian");
        _true(!gov.hasRole(gov.PROPOSER_ROLE(), guardian), "guardian cannot propose");
        _true(gov.hasRole(gov.EXECUTOR_ROLE(), address(0)), "open executor");
        _true(gov.hasRole(gov.DEFAULT_ADMIN_ROLE(), address(gov)), "self admin");
        address deployer = _c("deployer");
        _true(
            !gov.hasRole(gov.DEFAULT_ADMIN_ROLE(), deployer) && !gov.hasRole(gov.DEFAULT_ADMIN_ROLE(), multisig)
                && !gov.hasRole(gov.DEFAULT_ADMIN_ROLE(), guardian) && !gov.hasRole(gov.PROPOSER_ROLE(), deployer),
            "no external admin"
        );
        _eq(gov.bootstrapper(), deployer, "bootstrapper");
    }

    /// @dev Every privileged role in phases 1-4 is the governance timelock.
    function _roles() internal {
        address g = _a("V3Governance");
        _eq(V3LaunchFactory(_a("V3LaunchFactory")).infrastructureConfigurator(), g, "factory configurator");
        _eq(EligibilityController(_a("EligibilityController")).governance(), g, "controller");
        _eq(EligibilityRegistry(_a("EligibilityRegistry")).governance(), g, "eligibility registry");
        _eq(RewardPayoutVault(_a("RewardPayoutVault")).configurator(), g, "payout configurator");
        _eq(StockAdapterRegistry(_a("StockAdapterRegistry")).governance(), g, "adapter registry");
        _eq(RewardRoundManager(payable(_a("RewardRoundManager"))).governor(), g, "rounds");
        _eq(RewardDistributor(_a("RewardDistributor")).governance(), g, "distributor");
        _eq(DeskRewards(payable(_a("DeskRewards"))).governance(), g, "desk rewards");
        _eq(DeskNFT(payable(_a("DeskNFT"))).governance(), g, "desk nft");
        _eq(ProtocolVault(payable(_a("ProtocolVault"))).governance(), g, "protocol vault");
        _eq(OpsVault(payable(_a("OpsVault"))).governance(), g, "ops vault");
        (address bg,,,,,,,) = BuybackBurnExecutor(payable(_a("BuybackBurnExecutor"))).config();
        _eq(bg, g, "buyback");
        _eq(SolonStakingV2(payable(_a("SolonStakingV2"))).configurator(), g, "staking configurator");
        _eq(StockFeeConverter(payable(_a("StockFeeConverter"))).governance(), g, "stock converter");
        _eq(V2FeeIngress(_a("V2FeeIngress")).governance(), g, "v2 ingress");
        _eq(V2PlatformRouter(payable(_a("V2PlatformRouter"))).governance(), g, "v2 router");
    }

    function _wiring() internal {
        _wiringCore();
        _rewardInfrastructure();
        _wiringRewards();
        _wiringDesk();
        _wiringVaults();
        _wiringConverters();
    }

    function _wiringCore() internal {
        address factory = _a("V3LaunchFactory");
        address ledger = _a("V3FeeLedger");
        address payable hook = _a("V3QuoteFeeHook");
        _eq(V3FeeLedger(payable(ledger)).factory(), factory, "ledger factory");
        _eq(V3QuoteFeeHook(hook).factory(), factory, "hook factory");
        _eq(address(V3QuoteFeeHook(hook).ledger()), ledger, "hook ledger");
        _eq(address(V3QuoteFeeHook(hook).poolManager()), _c("poolManager"), "hook manager");
        _true(uint160(address(hook)) & 0x3fff == 0x28cc, "hook permission bits");
        _eq(V3LaunchStrategy(payable(_a("V3LaunchStrategy"))).factory(), factory, "strategy");
        _eq(CreatorRightsNFT(payable(_a("CreatorRightsNFT"))).factory(), factory, "rights");
        _eq(
            CreatorRightsNFT(payable(_a("CreatorRightsNFT"))).eligibilityPolicy(),
            _a("EligibilityController"),
            "rights policy"
        );
        _eq(V3LPLocker(_a("V3LPLocker")).factory(), factory, "locker");
        V3LaunchFactory f = V3LaunchFactory(factory);
        _eq(f.stockFeeConverter(), _a("StockFeeConverter"), "factory stock converter");
        _eq(f.assetSchedule(), _a("RewardAssetSchedule"), "factory calendar");
        _true(!f.hasLaunched(), "no launch during deployment");
        V3Router router = V3Router(payable(_a("V3Router")));
        _true(address(router.hook()) == hook && router.factory() == factory, "router");
        _eq(address(router.eligibility()), _a("EligibilityController"), "router eligibility");
        _eq(address(V3Quoter(payable(_a("V3Quoter"))).router()), address(router), "quoter");
    }

    function _rewardInfrastructure() internal {
        (address rc, address rp, address rr, bytes32 id, uint32 ver, bytes32 price) =
            V3LaunchFactory(_a("V3LaunchFactory")).rewardInfrastructure();
        _true(rc == _a("EligibilityController") && rp == _a("RewardPayoutVault"), "reward infrastructure");
        _eq(rr, _a("RewardRoundManager"), "reward rounds");
        _true(id == vm.parseJsonBytes32(json, ".config.rewardAssetId"), "reward asset id");
        _true(ver == vm.parseJsonUint(json, ".config.rewardAdapterVersion"), "reward version");
        _true(price == vm.parseJsonBytes32(json, ".config.rewardPricePolicy"), "reward price policy");
    }

    function _wiringRewards() internal {
        address factory = _a("V3LaunchFactory");
        address desk = _a("DeskRewards");
        address staking = _a("SolonStakingV2");
        RewardPayoutVault p = RewardPayoutVault(_a("RewardPayoutVault"));
        _true(address(p.controller()) == _a("EligibilityController") && p.factory() == factory, "payout");
        _true(p.rewardModulesConfigured() && p.deskModule() == desk && p.stakingModule() == staking, "payout modules");
        _eq(p.distributor(), _a("RewardDistributor"), "payout distributor");
        RewardRoundManager r = RewardRoundManager(_a("RewardRoundManager"));
        _true(r.payout() == address(p) && r.registry() == _a("StockAdapterRegistry"), "rounds");
        _eq(r.sourceFactory(), factory, "rounds factory");
        _true(r.rewardModulesConfigured() && r.deskModule() == desk && r.stakingModule() == staking, "rounds modules");
        _eq(r.treasury(), _c("treasury"), "rounds treasury");
        _eq(r.batcher(), _a("RewardBatcher"), "rounds execution");
        _eq(r.capacity(), _a("CapacityController"), "rounds capacity");
        _eq(address(r.vault()), _a("RewardVault"), "reward vault");
        EligibilityRegistry er = EligibilityRegistry(_a("EligibilityRegistry"));
        _true(er.factory() == factory && er.desk() == desk && er.staking() == staking, "eligibility registry");
    }

    function _wiringDesk() internal {
        DeskRewards dr = DeskRewards(_a("DeskRewards"));
        _true(address(dr.nft()) == _a("DeskNFT") && address(dr.rounds()) == _a("RewardRoundManager"), "desk");
        _eq(address(dr.payout()), _a("RewardPayoutVault"), "desk payout");
        _true(dr.protocolStaking() == _a("SolonStakingV2") && dr.royaltyAssetsConfigured(), "desk protocol staking");
        DeskNFT nft = DeskNFT(_a("DeskNFT"));
        _true(nft.protocolVault() == _a("ProtocolDeskVault") && nft.rewards() == address(dr), "desk nft");
        _true(nft.burnSink() == _a("BurnSink") && nft.protocolAccount() == _a("ProtocolVault"), "desk sinks");
        _true(nft.controller() == _a("EligibilityController") && address(nft.solon()) == _c("solon"), "desk solon");
        _eq(ProtocolDeskVault(_a("ProtocolDeskVault")).buyer(), _a("BuybackBurnExecutor"), "protocol desk buyer");
    }

    function _wiringVaults() internal {
        address converter = _a("StockFeeConverter");
        OpsVault ops = OpsVault(_a("OpsVault"));
        _true(ops.desk() == _a("DeskNFT") && ops.protocolDeskVault() == _a("ProtocolDeskVault"), "ops desk");
        _true(ops.protocol() == _a("ProtocolVault") && ops.verifier() == _c("opsVerifier"), "ops");
        _true(ops.targets(6) == converter && ops.shortfallTarget(6), "ops subsidy target");
        ProtocolVault pv = ProtocolVault(_a("ProtocolVault"));
        _true(pv.stockConverter() == converter && pv.desk() == _a("DeskNFT"), "protocol sources");
        _true(pv.treasury() == _c("treasury") && pv.ops() == address(ops), "protocol");
        _eq(pv.ledger(), _a("V3FeeLedger"), "protocol ledger");
        BuybackBurnExecutor b = BuybackBurnExecutor(_a("BuybackBurnExecutor"));
        _true(b.stockConverter() == converter && b.v2Router() == _a("V2PlatformRouter"), "buyback sources");
        _eq(b.vault(), _a("BuybackVault"), "buyback vault");
    }

    function _wiringConverters() internal {
        SolonStakingV2 s = SolonStakingV2(_a("SolonStakingV2"));
        _true(s.roundsManager() == _a("RewardRoundManager") && s.payout() == _a("RewardPayoutVault"), "staking");
        _eq(s.ledger(), _a("V3FeeLedger"), "staking ledger");
        _true(s.protocolDesk() == _a("DeskRewards") && s.v2Notifier() == _a("V2PlatformRouter"), "staking notifiers");
        _true(
            address(s.controller()) == _a("EligibilityController") && address(s.solon()) == _c("solon"), "staking solon"
        );
        StockFeeConverter sc = StockFeeConverter(_a("StockFeeConverter"));
        _true(sc.buyback() == _a("BuybackBurnExecutor") && sc.protocol() == _a("ProtocolVault"), "stock converter");
        _true(sc.ops() == _a("OpsVault") && sc.sellRoute() == _a("StockFeeSellRoute"), "stock converter route");
        _eq(address(sc.ledger()), _a("V3FeeLedger"), "stock converter ledger");
        _eq(V2FeeIngress(_a("V2FeeIngress")).router(), _a("V2PlatformRouter"), "v2 ingress router");
        _eq(V2PlatformRouter(_a("V2PlatformRouter")).converter(), _a("V2FeeConverter"), "v2 converter");
        _eq(V2FeeConverter(_a("V2FeeConverter")).router(), _a("V2PlatformRouter"), "v2 converter router");
    }

    /// @dev Default B, fixed caps and fee constants.
    function _policy() internal {
        EligibilityController c = EligibilityController(_a("EligibilityController"));
        _true(!c.enabled() && c.effectiveEpoch() == 0 && c.registry() == address(0), "eligibility default B");
        _true(c.assetIds(_c("rewardAsset")) == 1, "reward asset identity bound");
        DeskNFT nft = DeskNFT(payable(_a("DeskNFT")));
        _true(nft.MAX_SUPPLY() == 5000 && nft.SOLON_PER_DESK() == 100000e18 && nft.totalSupply() == 0, "desk caps");
        _true(ProtocolDeskVault(_a("ProtocolDeskVault")).protocolMax() == 1000, "protocol desk cap");
        // r9: per-address primary-mint cap (1% of supply) and its guardian (tighten-only) selector.
        _true(nft.mintCapPerAddress() == 50 && nft.mintCapPerAddress() * 100 == nft.MAX_SUPPLY(), "desk address cap 1%");
        _true(
            nft.guardianTightenOnly(DeskNFT.tightenMintCapPerAddress.selector)
                && !nft.guardianTightenOnly(DeskNFT.setMintCapPerAddress.selector),
            "desk cap guardian = tighten only"
        );
        ProtocolVault pv = ProtocolVault(payable(_a("ProtocolVault")));
        _true(
            pv.operatingBuffer() >= 100 ether && pv.liabilities() == 0 && pv.executionBudget() == 0,
            "protocol commitments"
        );
        _true(RewardDistributor(_a("RewardDistributor")).minimumUSD18() >= 2 ether, "push floor");
        StockFeeConverter sc = StockFeeConverter(payable(_a("StockFeeConverter")));
        _true(sc.feeBps() == vm.parseJsonUint(json, ".config.stockFeeBps") && !sc.routePaused(), "stock fee bps");
        uint256[] memory split = vm.parseJsonUintArray(json, ".config.feeSplitBps");
        _true(
            split.length == 6 && split[0] == 5750 && split[1] == 1000 && split[2] == 1000 && split[3] == 500
                && split[4] == 1000 && split[5] == 750,
            "fee split manifest"
        );
    }

    function _solonKey() internal view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(_c("solon")),
            uint24(vm.parseJsonUint(json, ".config.solonPoolFee")),
            int24(vm.parseJsonInt(json, ".config.solonPoolTickSpacing")),
            IHooks(address(0))
        );
    }

    function _stockKey() internal view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(_c("rewardAsset")),
            uint24(vm.parseJsonUint(json, ".config.stockPoolFee")),
            int24(vm.parseJsonInt(json, ".config.stockPoolTickSpacing")),
            IHooks(address(0))
        );
    }

    function _same(string memory name, address fresh) internal {
        _true(fresh.codehash == _a(name).codehash, string.concat("source mismatch ", name));
    }

    /// @dev Simulation-only reference builds. The fee split (5750/1000/1000/500/1000/750),
    /// Desk/protocol caps and all constructor-fixed bindings live in this runtime code.
    function _reproducedCode() internal {
        // r12 (F11): Arc mainnet has no PoolSwapTest; SELL_SWAP_ROUTER must be the self-deployed lib/v4-core one bound to
        // the real PoolManager (deploy.sh arc-ext), byte-identical to this build.
        _true(
            address(new PoolSwapTest(IPoolManager(_c("poolManager")))).codehash == _c("sellSwapRouter").codehash,
            "sell swap router = v4-core PoolSwapTest(PoolManager) (F11)"
        );
        address g = _a("V3Governance");
        address factory = _a("V3LaunchFactory");
        address ledger = _a("V3FeeLedger");
        address ops = _a("OpsVault");
        address pv = _a("ProtocolVault");
        address sink = _a("BurnSink");
        address positions = _c("positionManager");
        _same("V3FeeLedger", address(new V3FeeLedger(factory, _c("nativeUsdcView"))));
        _same("EligibilityController", address(new EligibilityController(g)));
        _same("StockAdapterRegistry", address(new StockAdapterRegistry(g)));
        _same("BurnSink", address(new BurnSink()));
        _same("OpsVault", address(new OpsVault(g, pv, _c("opsVerifier"))));
        _same("ProtocolVault", address(new ProtocolVault(g, _c("treasury"), ops, ledger)));
        _same("V3LPLocker", address(new V3LPLocker(factory, IPositionManager(positions))));
        _same("V3LaunchStrategy", address(new V3LaunchStrategy(factory, IPositionManager(positions))));
        _same("DeskRewards", address(new DeskRewards(V3FeeLedger(payable(ledger)), g)));
        _same(
            "V3Router",
            address(
                new V3Router(
                    IPoolManager(_c("poolManager")),
                    V3QuoteFeeHook(_a("V3QuoteFeeHook")),
                    IV3TradeEligibility(_a("EligibilityController"))
                )
            )
        );
        _same("V3Quoter", address(new V3Quoter(V3Router(payable(_a("V3Router"))))));
        _same("RewardBatcher", address(new RewardBatcher(RewardRoundManager(payable(_a("RewardRoundManager"))))));
        vm.prank(g);
        _same(
            "RewardPayoutVault",
            address(new RewardPayoutVault(new address[](0), EligibilityController(_a("EligibilityController"))))
        );
        vm.prank(g);
        _same(
            "RewardDistributor",
            address(new RewardDistributor(RewardPayoutVault(_a("RewardPayoutVault")), _c("priceOracle")))
        );
        _same(
            "FixedV4BuybackRoute",
            address(new FixedV4BuybackRoute(_a("BuybackBurnExecutor"), _c("solonFeeRouter"), _solonKey()))
        );
        _same("StockFeeSellRoute", address(new SolonStockSellRoute(_a("SolonStockHub"), _a("StockFeeConverter"), ops)));
        _same(
            "V2FeeSellRoute", address(new FixedV4FeeSellRoute(_a("V2FeeConverter"), _c("sellSwapRouter"), _solonKey()))
        );
        _same(
            "StockFeeConverter",
            address(
                new StockFeeConverter(
                    V3FeeLedger(payable(ledger)),
                    _c("stockFeeSigner"),
                    _a("StockFeeSellRoute"),
                    _a("BuybackBurnExecutor"),
                    pv,
                    ops,
                    uint16(vm.parseJsonUint(json, ".config.stockFeeBps")),
                    1,
                    keccak256("RELAY"),
                    g,
                    _c("priceOracle")
                )
            )
        );
        _same(
            "V2FeeIngress",
            address(
                new V2FeeIngress(
                    g,
                    [_c("v2Auditor0"), _c("v2Auditor1"), _c("v2Auditor2")],
                    _c("v2Funder"),
                    uint64(vm.parseJsonUint(json, ".config.v2CutoverBlock"))
                )
            )
        );
        _same(
            "V2PlatformRouter",
            address(new V2PlatformRouter(g, _a("V2FeeIngress"), _a("SolonStakingV2"), _a("BuybackBurnExecutor"), sink))
        );
        _same(
            "V2FeeConverter",
            address(
                new V2FeeConverter(
                    _a("V2PlatformRouter"),
                    _a("V2FeeSellRoute"),
                    _c("v2Signer"),
                    ops,
                    keccak256(abi.encode(_solonKey())),
                    1
                )
            )
        );
        _same(
            "ProtocolDeskVault",
            address(
                new ProtocolDeskVault(
                    DeskNFTType(payable(_a("DeskNFT"))), IERC20(_c("solon")), sink, _a("BuybackBurnExecutor"), ops
                )
            )
        );
    }

    // ---------------------------------------------------------------- phase 5: stock layer (Arc)

    function _stockRoles() internal {
        address g = _a("V3Governance");
        address guardian = _c("guardian");
        SolonStockHub hub = SolonStockHub(_a("SolonStockHub"));
        _eq(hub.owner(), g, "hub owner");
        _eq(hub.guardian(), guardian, "hub guardian");
        _eq(hub.keeper(), _c("stockKeeper"), "hub keeper");
        CapacityController cap = CapacityController(_a("CapacityController"));
        _true(cap.owner() == g && cap.guardian() == guardian, "capacity owner/guardian");
        _eq(CanonicalGate(_a("CanonicalGate")).owner(), g, "gate owner");
        _eq(StockPoolVault(_a("StockPoolVault")).owner(), g, "pool A owner");
        IV3LzEndpointConfig ep = IV3LzEndpointConfig(_c("lzEndpoint"));
        _eq(ep.delegates(address(hub)), g, "hub LayerZero delegate");
    }

    function _stockWiring() internal {
        SolonStockHub hub = SolonStockHub(_a("SolonStockHub"));
        address cap = _a("CapacityController");
        address token = _a("StockToken");
        address underlying = _c("stockUnderlying");
        OrderScheduler sched = OrderScheduler(_a("OrderScheduler"));
        _true(address(hub.capacity()) == cap && address(hub.scheduler()) == address(sched), "hub capacity");
        _true(address(sched.hub()) == address(hub) && address(sched.capacity()) == cap, "scheduler");
        _true(
            CapacityController(cap).hub() == address(hub)
                && CapacityController(cap).rewardManager() == _a("RewardRoundManager"),
            "capacity binding"
        );
        CanonicalGate gate = CanonicalGate(_a("CanonicalGate"));
        _true(address(hub.gate()) == address(gate) && gate.hub() == address(hub), "gate binding");
        _true(gate.fundsRecipient() == _c("gateFunds") && gate.keeper() == _c("stockKeeper"), "gate funds/keeper");
        _eq(gate.bridger(), _c("ethBridger"), "gate bridger");
        uint32 rhEid = uint32(vm.parseJsonUint(json, ".config.rhEid"));
        _true(hub.peers(rhEid) == bytes32(uint256(uint160(_c("reserveVault")))), "hub peer = reserve vault");
        HubSettlement.Listing memory l = hub.getListing(underlying);
        _true(address(l.arc) == token && l.enabled && !l.tradingPaused && l.vaultEid == rhEid, "listing");
        _true(l.route == _a("RelayFundingRoute") && l.routePath == keccak256("RELAY"), "listing route");
        _eq(hub.underlyingOfToken(token), underlying, "token underlying");
        SolonStockToken t = SolonStockToken(token);
        _true(t.hub() == address(hub) && t.underlying() == underlying && t.totalSupply() == 0, "stock token");
        _true(t.reserveChainId() == vm.parseJsonUint(json, ".config.rhChainId"), "stock token chain");
        (bool open, bool transferable, uint256 version) = hub.stockState(token);
        _true(open && transferable && version == 1, "stock state");
        RelayFundingRoute route = RelayFundingRoute(_a("RelayFundingRoute"));
        _true(route.caller() == address(hub) && route.asset() == address(0), "arc route caller/asset");
        _true(route.nativeToken() == _c("arcUsdc"), "arc route native ERC-20 view");
        _true(route.destination() == _c("reserveVault"), "arc route destination");
        _true(route.destinationChainId() == vm.parseJsonUint(json, ".config.rhChainId"), "arc route chain");
        _true(
            route.depository() == _c("relayDepository") && route.signer() == _c("fundingSigner")
                && route.returnExecutor() == _c("relayReturnExecutor"),
            "arc route relay binding"
        );
        if (block.chainid == V3LzConfig.ARC_CHAIN_ID) {
            // r12 (F1): deposits go through the live Relay depository v2. r14: Arc USDC is deposited as the 0x3600
            // ERC-20 view (depositErc20) — Relay fails depositNative orders with ORIGIN_CURRENCY_MISMATCH.
            _true(route.depository() == RELAY_DEPOSITORY_V2 && RELAY_DEPOSITORY_V2.code.length != 0, "Relay depository v2");
            _true(route.nativeToken() == ARC_USDC_VIEW && ARC_USDC_VIEW.code.length != 0, "arc route 0x3600 view");
        }
        address adapter = _a("SolonStockAdapter");
        _true(hub.rewardAdapter(adapter), "reward adapter allowed");
        StockAdapterRegistry.Route memory r = StockAdapterRegistry(_a("StockAdapterRegistry"))
            .resolve(
                vm.parseJsonBytes32(json, ".config.rewardAssetId"),
                uint32(vm.parseJsonUint(json, ".config.rewardAdapterVersion"))
            );
        _true(r.asset == token && r.underlying == underlying && r.hub == address(hub) && r.adapter == adapter, "route");
        _true(
            r.enabled && r.path == keccak256("RELAY") && r.chainId == vm.parseJsonUint(json, ".config.rhChainId"),
            "route path"
        );
        _eq(_c("rewardAsset"), token, "reward asset = stock token");
        _eq(_c("stockStatus"), address(hub), "factory stock status = hub");
        SolonStockSellRoute sell = SolonStockSellRoute(payable(_a("StockFeeSellRoute")));
        _true(
            address(sell.hub()) == address(hub) && sell.converter() == _a("StockFeeConverter")
                && sell.ops() == _a("OpsVault"),
            "fee-lot sell route"
        );
        StockPoolVault pool = StockPoolVault(payable(_a("StockPoolVault")));
        _true(pool.token() == token && pool.underlying() == underlying && address(pool.hub()) == address(hub), "pool A");
        _true(
            address(pool.manager()) == _c("poolManager") && pool.priceSigner() == _c("refTickSigner")
                && pool.keeper() == _c("stockKeeper") && pool.treasury() == _c("treasury")
                && pool.reserveRecipient() == _c("reserveRecipient"),
            "pool A bindings"
        );
        PoolKey memory k = pool.poolKey();
        PoolKey memory want = _stockKey();
        _true(
            Currency.unwrap(k.currency1) == Currency.unwrap(want.currency1) && k.fee == want.fee
                && k.tickSpacing == want.tickSpacing && address(k.hooks) == address(0),
            "pool A key = manifest"
        );
    }

    /// @dev Caps (owner decision 2026-09-30), fees, defaults, DVNs, and the halt path.
    function _stockPolicy() internal {
        CapacityController cap = CapacityController(_a("CapacityController"));
        // r13 (path 2a): L_run is the manifest's launch value (lowered at deployment; default $10,000).
        uint256 lRun = _cfgUint(".config.lRunUsd", 10_000) * 1e18;
        _true(cap.lRun() == lRun && cap.uRun() == 1_000_000e18 && cap.totalCap() == 1_000_000e18, "caps");
        _true(cap.publicCap() == 800_000e18 && cap.rewardUnreviewedShare() == 200_000e18, "reward reserve 20%");
        _true(cap.exposureUsd() == 0 && cap.LIMIT_DELAY() == 48 hours, "capacity clean, 48h raise");
        _true(cap.minOrderUsd() == 20e18, "minimum public order $20 (re-review L3)");
        (uint256 pl,,, uint64 eta) = cap.pendingLimits();
        _true(pl == 0 && eta == 0, "no pending raise");
        SolonStockHub hub = SolonStockHub(_a("SolonStockHub"));
        (uint16 buyFee, uint16 sellFee,) = hub.fees();
        _true(buyFee == 25 && sellFee == 25 && hub.MAX_FEE_BPS() == 100, "25 bps both ways");
        // r13 (path 2a): float mode = the manifest's setting; seeded float exactly the deployer's seed, nothing escrowed;
        // the daily float-advance allowance = max(pay floor, 20% of the float) (nothing paid yet).
        bool floatOn = _cfgBool(".config.hubFloatEnabled", false);
        uint256 seed = _cfgUint(".config.hubFloatSeedUsd", 0) * 1e18;
        _true(hub.floatEnabled() == floatOn && hub.available() == seed && hub.escrowed() == 0, "hub float (mode, seed)");
        uint256 floor = _cfgUint(".config.hubPayFloorUsd", 10_000) * 1e18;
        _true(hub.payAllowance() == (seed / 5 > floor ? seed / 5 : floor), "hub float pay floor");
        _true(!hub.paused() && !hub.mintsHalted() && hub.orderCount() == 0, "hub clean");
        _true(hub.treasury() == _c("treasury"), "hub treasury");
        _true(
            hub.floatRecipientA() == _c("hubFloatA") && hub.floatRecipientB() == _c("hubFloatB"), "hub float recipients"
        );
        _true(
            hub.getListing(_c("stockUnderlying")).mintFloor == vm.parseJsonUint(json, ".config.mintFloor"), "mint floor"
        );
        IV3LzEndpointConfig ep = IV3LzEndpointConfig(_c("lzEndpoint"));
        uint32 rhEid = uint32(vm.parseJsonUint(json, ".config.rhEid"));
        _uln(ep, address(hub), _c("sendLib"), rhEid, "hub send DVNs", ".config.confirmations");
        _uln(ep, address(hub), _c("receiveLib"), rhEid, "hub receive DVNs", ".config.rhConfirmations");
        _pinned(ep, address(hub), rhEid, true, "hub");
        if (V3LzConfig.live(block.chainid)) {
            _true(
                address(ep) == V3LzConfig.endpoint(block.chainid) && _c("sendLib") == V3LzConfig.sendLib(block.chainid)
                    && _c("receiveLib") == V3LzConfig.receiveLib(block.chainid),
                "LayerZero EndpointV2 / ULN302 libraries"
            );
        }
    }

    /// @dev r12 (review M2): the OApp's libraries toward `eid` are explicitly set (not the endpoint default) and are the
    ///      manifest's ULN302 send / receive libraries (equal to V3LzConfig's on a live chain, checked above).
    function _pinned(IV3LzEndpointConfig ep, address oapp, uint32 eid, bool send, string memory what) internal {
        if (send) {
            _true(
                !ep.isDefaultSendLibrary(oapp, eid) && ep.getSendLibrary(oapp, eid) == _c("sendLib"),
                string.concat(what, ": send library pinned to ULN302 (not default)")
            );
        }
        (address lib, bool isDefault) = ep.getReceiveLibrary(oapp, eid);
        _true(
            !isDefault && lib == _c("receiveLib"), string.concat(what, ": receive library pinned to ULN302 (not default)")
        );
    }

    /// @dev r9: >= 2 of >= 3 DVNs, never the Dead DVN (LayerZero's default on RH<->Arc), exactly the V3LzConfig set
    ///      of this chain on a live chain, and the confirmations of the SENDING side (`confKey` in the manifest).
    function _uln(
        IV3LzEndpointConfig ep,
        address oapp,
        address lib,
        uint32 eid,
        string memory what,
        string memory confKey
    ) internal {
        bytes memory raw = ep.getConfig(oapp, lib, eid, V3LzConfig.ULN_CONFIG_TYPE);
        _true(raw.length != 0, what);
        V3LzConfig.UlnConfig memory c = abi.decode(raw, (V3LzConfig.UlnConfig));
        _true(V3LzConfig.adequate(c), string.concat(what, ": >= 2 of >= 3 (testnet: the single live DVN)"));
        _true(block.chainid == 31337 || !V3LzConfig.placeholder(c), string.concat(what, ": TODO-verify placeholders"));
        _true(!V3LzConfig.dead(c), string.concat(what, ": not the Dead DVN"));
        if (V3LzConfig.live(block.chainid)) {
            _true(V3LzConfig.matchesChain(c, block.chainid), string.concat(what, ": V3LzConfig DVN set"));
        }
        _true(c.confirmations == vm.parseJsonUint(json, confKey), string.concat(what, ": confirmations"));
    }

    /// @dev The RH side is verified here only when the manifest carries it (local devnet: one chain);
    ///      on Robinhood Chain use VerifyV3Reserve.
    function _reserveSide() internal {
        if (!vm.keyExistsJson(json, ".contracts.ReserveVault")) return;
        expectRhFloat = _cfgBool(".config.hubFloatEnabled", false);
        _verifyReserve(
            ReserveVault(_a("ReserveVault")),
            RestrictedVenue(_a("RestrictedVenue")),
            RelayFundingRoute(_a("ReserveReturnRoute")),
            _a("SolonStockHub"),
            uint32(vm.parseJsonUint(json, ".config.arcEid")),
            _c("stockUnderlying"),
            _c("reserveOwner"),
            V3LzConfig.SEND_LIB_PLACEHOLDER,
            V3LzConfig.RECEIVE_LIB_PLACEHOLDER,
            vm.parseJsonAddressArray(json, ".config.extraUnderlyings")
        );
    }

    function _reproducedStockCode() internal {
        address g = _a("V3Governance");
        _same(
            "SolonStockHub",
            address(
                new SolonStockHub(
                    _c("lzEndpoint"),
                    _c("treasury"),
                    uint16(vm.parseJsonUint(json, ".config.stockFeeBps")),
                    g,
                    _a("OpsVault"),
                    [_c("hubFloatA"), _c("hubFloatB")]
                )
            )
        );
        _same(
            "CanonicalGate",
            address(
                new CanonicalGate(
                    _c("cctpMessenger"),
                    _c("cctpTransmitter"),
                    _c("arcUsdc"),
                    uint32(vm.parseJsonUint(json, ".config.ethDomain")),
                    _c("ethTokenMessenger"),
                    _a("SolonStockHub"),
                    _c("gateFunds"),
                    g
                )
            )
        );
        _same(
            "SolonStockAdapter",
            address(
                new SolonStockAdapter(
                    SolonStockAdapter.Config(
                        _a("RewardRoundManager"),
                        _a("RewardVault"),
                        _a("StockToken"),
                        _c("stockUnderlying"),
                        _a("SolonStockHub"),
                        _c("rewardQuoteSigner"),
                        keccak256("RELAY"),
                        vm.parseJsonUint(json, ".config.rhChainId"),
                        _a("OpsVault"),
                        _c("priceOracle")
                    )
                )
            )
        );
        _same("CapacityController", address(new CapacityController(g, _c("guardian"))));
        _same(
            "OrderScheduler",
            address(new OrderScheduler(_a("SolonStockHub"), CapacityController(_a("CapacityController"))))
        );
        _same(
            "RelayFundingRoute",
            address(
                new RelayFundingRoute(
                    RelayFundingRoute.Config(
                        _a("SolonStockHub"),
                        address(0),
                        _c("reserveVault"),
                        vm.parseJsonUint(json, ".config.rhChainId"),
                        _c("relayDepository"),
                        _c("fundingSigner"),
                        _c("relayReturnExecutor"),
                        _c("arcUsdc")
                    )
                )
            )
        );
        _same(
            "StockPoolVault",
            address(
                new StockPoolVault(
                    StockPoolVault.Config(
                        IPoolManager(_c("poolManager")),
                        _a("StockToken"),
                        _c("stockUnderlying"),
                        _a("SolonStockHub"),
                        _c("treasury"),
                        _c("stockKeeper"),
                        _c("refTickSigner"),
                        g,
                        _c("reserveRecipient")
                    )
                )
            )
        );
    }

    // ---------------------------------------------------------------- r7: oracle, three stocks, payout choice

    function _stockAt(uint256 i) internal view returns (address u, address token, string memory ticker) {
        if (i == 0) return (_c("stockUnderlying"), _a("StockToken"), vm.parseJsonString(json, ".config.stockTicker"));
        u = vm.parseJsonAddressArray(json, ".config.extraUnderlyings")[i - 1];
        token = vm.parseJsonAddressArray(json, ".config.extraTokens")[i - 1];
        ticker = vm.parseJsonStringArray(json, ".config.extraTickers")[i - 1];
    }

    function _stockCount() internal view returns (uint256) {
        return 1 + vm.parseJsonAddressArray(json, ".config.extraTokens").length;
    }

    /// @dev Design §12.2: governance-owned oracle on a fixed source, every consumer pointed at it.
    function _r7Oracle() internal {
        address g = _a("V3Governance");
        SolonStockOracle o = SolonStockOracle(_a("SolonStockOracle"));
        _true(o.owner() == g && o.guardian() == _c("guardian"), "oracle owner/guardian");
        _eq(_c("priceOracle"), address(o), "price oracle = SolonStockOracle");
        _eq(_c("oracleSource"), _a("StockPriceSource"), "oracle source");
        _eq(RewardDistributor(_a("RewardDistributor")).oracle(), address(o), "distributor oracle");
        _true(RewardDistributor(_a("RewardDistributor")).oracleMaxAge() == 2 hours, "distributor max age 2h");
        _eq(StockFeeConverter(payable(_a("StockFeeConverter"))).oracle(), address(o), "converter oracle floor");
        _eq(address(OracleRefTickSigner(_a("OracleRefTickSigner")).oracle()), address(o), "ref tick signer");
        (bool local) = vm.parseJsonBool(json, ".config.localStandIns");
        if (local) {
            ChainlinkStockSource src = ChainlinkStockSource(_a("StockPriceSource"));
            _eq(src.owner(), g, "local source owner");
        } else {
            RelayedStockSource src = RelayedStockSource(_a("StockPriceSource"));
            uint32 rhEid = uint32(vm.parseJsonUint(json, ".config.rhEid"));
            _true(src.owner() == g && src.rhEid() == rhEid, "relayed source owner/eid");
            IV3LzEndpointConfig ep = IV3LzEndpointConfig(_c("lzEndpoint"));
            _eq(ep.delegates(address(src)), g, "relayed source LayerZero delegate");
            _uln(ep, address(src), _c("receiveLib"), rhEid, "price receive DVNs", ".config.rhConfirmations");
            _pinned(ep, address(src), rhEid, false, "relayed price source");
            address sender = _c("priceSender");
            if (sender != address(0)) {
                _true(src.peers(rhEid) == bytes32(uint256(uint160(sender))), "relayed source peer = RH sender");
            }
        }
        if (block.chainid == V3LzConfig.ARC_CHAIN_ID) {
            _true(
                vm.envOr("ORACLE_POOLS", ",", new address[](0)).length == _stockCount(),
                "ORACLE_STOCKS / ORACLE_POOLS (RH inputs) given for the M4 TWAP check"
            );
        }
        for (uint256 i; i < _stockCount(); ++i) {
            (address u, address token,) = _stockAt(i);
            SolonStockOracle.Asset memory a = o.assetOf(token);
            _true(a.token == token && o.underlyingOf(token) == u && !a.paused, "oracle asset binding");
            _eq(address(a.source), _a("StockPriceSource"), "oracle asset source");
            SolonStockOracle.Params memory p = a.params;
            _true(
                p.maxAge == 15 minutes && p.maxMoveBps == 1_000 && p.confirmBps == 200 && p.maxDepegBps == 50
                    && p.maxSourceAge == 26 hours,
                "oracle params (design 12.2)"
            );
            // r12 (review M4): TWAP check on <=> the price source has a TWAP pool for the stock (150 bps when on).
            bool hasPool = local
                ? ChainlinkStockSource(_a("StockPriceSource")).twapPoolOf(u).pool != address(0)
                : rhTwapPoolListed(vm, u);
            _true(p.maxTwapBps == (hasPool ? 150 : 0), "oracle TWAP check <=> RH TWAP pool (M4)");
            if (local) _true(o.status(token) == SolonStockOracle.Status.Live, "local oracle live");
        }
    }

    /// @dev Design §12.5/§12.6: listings, per-asset caps, reward routes, NVDA-only stock quote, payout choices.
    function _r7Stocks() internal {
        SolonStockHub hub = SolonStockHub(_a("SolonStockHub"));
        CapacityController cap = CapacityController(_a("CapacityController"));
        V3LaunchFactory f = V3LaunchFactory(_a("V3LaunchFactory"));
        StockAdapterRegistry reg = StockAdapterRegistry(_a("StockAdapterRegistry"));
        uint256[] memory caps = vm.parseJsonUintArray(json, ".config.assetCapsUsd");
        uint256 n = _stockCount();
        _true(caps.length == n && cap.cappedAssets().length == n, "one cap per stock");
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            (address u, address token, string memory ticker) = _stockAt(i);
            (uint256 c, bool set) = cap.assetCap(u);
            _true(set && c == caps[i] * 1e18, string.concat("asset cap ", ticker));
            sum += c;
            (uint256 pending, uint64 eta) = cap.pendingAssetCap(u);
            _true(pending == 0 && eta == 0, "no pending asset cap");
            if (i == 0) {
                _true(f.approvedQuote(token) != 0, "NVDA stock-quote approved");
                continue;
            }
            HubSettlement.Listing memory l = hub.getListing(u);
            _true(address(l.arc) == token && l.enabled && !l.tradingPaused, string.concat("listing ", ticker));
            _true(l.route == _a("RelayFundingRoute") && l.routePath == keccak256("RELAY"), "extra listing route");
            _true(f.approvedQuote(token) == 0, string.concat("no stock-quote coins in ", ticker));
            address payable adapter = _a(string.concat("SolonStockAdapter_", ticker));
            _true(hub.rewardAdapter(adapter), "extra reward adapter allowed");
            StockAdapterRegistry.Route memory r =
                reg.resolve(keccak256(bytes(ticker)), uint32(vm.parseJsonUint(json, ".config.rewardAdapterVersion")));
            _true(
                r.asset == token && r.underlying == u && r.hub == address(hub) && r.adapter == adapter && r.enabled,
                string.concat("route ", ticker)
            );
            (,, address aAsset, address aUnderlying,,,,,, address aOracle) = SolonStockAdapter(adapter).config();
            _true(aAsset == token && aUnderlying == u && aOracle == _c("priceOracle"), "extra adapter config");
        }
        _true(sum <= cap.totalCap(), "asset caps within the total");
        (,,,,,,,,, address nvdaOracle) = SolonStockAdapter(_a("SolonStockAdapter")).config();
        _eq(nvdaOracle, _c("priceOracle"), "NVDA adapter oracle floor");
        LaunchPayoutChoice pc = LaunchPayoutChoice(_a("LaunchPayoutChoice"));
        _true(
            pc.governance() == _a("V3Governance") && address(pc.hub()) == address(hub) && pc.factory() == address(f),
            "payout choice binding"
        );
        _eq(f.payoutChoice(), address(pc), "factory payout choice");
        _true(pc.choiceCount() == n, "one payout choice per stock");
        for (uint256 i; i < n; ++i) {
            (, address token, string memory ticker) = _stockAt(i);
            LaunchPayoutChoice.Choice memory c = pc.choice(i + 1);
            bytes32 id = i == 0 ? vm.parseJsonBytes32(json, ".config.rewardAssetId") : keccak256(bytes(ticker));
            _true(c.asset == token && c.assetId == id && c.enabled, string.concat("payout choice ", ticker));
            // r12 (review L5): the choice's registry route buys exactly this asset and is enabled.
            StockAdapterRegistry.Route memory rr = reg.resolve(c.assetId, c.version);
            _true(
                rr.asset == c.asset && rr.enabled && rr.adapter != address(0),
                string.concat("payout choice registry route asset ", ticker)
            );
            _true(
                EligibilityController(_a("EligibilityController")).assetIds(token) == i + 1,
                string.concat("payout choice eligibility id ", ticker)
            );
        }
    }

    /// @dev r8: pool A (NVDA only) and its one-step router. The router is bound to the same manager, fee hook and
    ///      eligibility seam as V3Router and to exactly the vault's pool key; the vault's price signer is the oracle
    ///      ref-tick signer; the pool is initialized iff the manifest says so (the keeper may move an empty pool to the
    ///      oracle later, so the tick itself is not pinned); a seeded vault holds its native seed until the first range.
    function _r8PoolA() internal {
        StockPoolVault v = StockPoolVault(payable(_a("StockPoolVault")));
        V3MultiHopRouter r = V3MultiHopRouter(payable(_a("V3MultiHopRouter")));
        _eq(v.priceSigner(), _a("OracleRefTickSigner"), "pool A signer = OracleRefTickSigner");
        _eq(address(OracleRefTickSigner(_a("OracleRefTickSigner")).oracle()), _a("SolonStockOracle"), "signer oracle");
        _true(
            address(r.manager()) == _c("poolManager") && address(r.hook()) == _a("V3QuoteFeeHook")
                && address(r.eligibility()) == _a("EligibilityController"),
            "multi-hop router bindings = V3Router"
        );
        PoolKey memory a = r.poolA();
        PoolKey memory k = v.poolKey();
        _true(
            keccak256(abi.encode(a)) == keccak256(abi.encode(k)) && r.stock() == _c("rewardAsset"),
            "router pool A = vault pool (NVDA.sol)"
        );
        (uint160 sqrtP,,,) = IPoolManager(_c("poolManager")).getSlot0(k.toId());
        if (vm.parseJsonBool(json, ".config.poolAInitialized")) {
            _true(sqrtP != 0, "pool A initialized");
        } else {
            _true(sqrtP == 0, "pool A not initialized (timelock op)");
        }
        uint256 seed = vm.parseJsonUint(json, ".config.poolASeedUsd");
        uint256 stockUsd = vm.parseJsonUint(json, ".config.poolAStockUsd");
        _true(
            seed
                == vm.parseJsonUint(json, ".config.poolAPoolUsd") + vm.parseJsonUint(json, ".config.poolAReserveUsd")
                    + (vm.parseJsonUint(json, ".config.poolASeedStockRaw") == 0 ? stockUsd : 0),
            "pool A seed = pool USDC + reserve + stock side (r9 structure)"
        );
        if (seed != 0 && v.liquidity() == 0) {
            _true(_a("StockPoolVault").balance >= seed * 1e18, "pool A native seed in the vault");
        }
        uint256 stockSeed = vm.parseJsonUint(json, ".config.poolASeedStockRaw");
        if (stockSeed != 0 && v.liquidity() == 0) {
            _true(IERC20(_c("rewardAsset")).balanceOf(_a("StockPoolVault")) >= stockSeed, "pool A stock seed");
        }
    }

    function _reproducedR7() internal {
        address g = _a("V3Governance");
        _same("SolonStockOracle", address(new SolonStockOracle(g, _c("guardian"))));
        _same("OracleRefTickSigner", address(new OracleRefTickSigner(SolonStockOracle(_a("SolonStockOracle")))));
        _same("LaunchPayoutChoice", address(new LaunchPayoutChoice(g, _a("SolonStockHub"))));
        _same(
            "V3MultiHopRouter",
            address(
                new V3MultiHopRouter(
                    IPoolManager(_c("poolManager")),
                    V3QuoteFeeHook(_a("V3QuoteFeeHook")),
                    StockPoolVault(payable(_a("StockPoolVault"))).poolKey(),
                    IV3HopEligibility(_a("EligibilityController"))
                )
            )
        );
        if (!vm.parseJsonBool(json, ".config.localStandIns")) {
            _same(
                "StockPriceSource",
                address(
                    new RelayedStockSource(_c("lzEndpoint"), g, uint32(vm.parseJsonUint(json, ".config.rhEid")))
                )
            );
        }
    }
}
