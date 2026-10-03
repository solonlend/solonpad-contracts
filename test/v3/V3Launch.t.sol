// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V3Router, IV3TradeEligibility} from "../../src/v3/V3Router.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {CreatorRightsNFT} from "../../src/v3/CreatorRightsNFT.sol";
import {V3LaunchFactory} from "../../src/v3/V3LaunchFactory.sol";
import {FactoryDeploy} from "./helpers/FactoryDeploy.sol";
import {V3LaunchValidation} from "../../src/v3/libraries/V3LaunchValidation.sol";
import {V3RewardWiring} from "../../src/v3/libraries/V3RewardWiring.sol";
import {LaunchPayoutChoice} from "../../src/v3/LaunchPayoutChoice.sol";
import {V3LaunchStrategy} from "../../src/v3/V3LaunchStrategy.sol";
import {V3LPLocker} from "../../src/v3/V3LPLocker.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {V3QuoteFeeHook, IV3HookFeeLedger} from "../../src/v3/V3QuoteFeeHook.sol";
import {StockFeeConverter} from "../../src/v3/StockFeeConverter.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {V3HookMiner} from "../../script/v3/MineV3Hook.s.sol";
import {HookToken, HookFeeReceiver} from "./helpers/HookHarness.sol";

import {EligibilityRegistry} from "../../src/v3/EligibilityRegistry.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {RewardPayoutVault} from "../../src/v3/RewardPayoutVault.sol";
import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";
import {RewardAssetSchedule} from "../../src/v3/RewardAssetSchedule.sol";
import {StockAdapterRegistry} from "../../src/v3/StockAdapterRegistry.sol";

contract LaunchStockStatus {
    bool public open = true;
    bool public transferable = true;
    uint256 public version = 1;

    function stockState(address) external view returns (bool, bool, uint256) {
        return (open, transferable, version);
    }

    function set(bool o, bool t, uint256 v) external {
        open = o;
        transferable = t;
        version = v;
    }
}

/// @notice SolonStockOracle stand-in: `execPrice` reverts unless Live, as the real oracle does.
contract LaunchPriceOracle {
    uint256 public price = 100 ether;
    bool public live = true;

    function set(uint256 p, bool l) external {
        price = p;
        live = l;
    }

    function execPrice(address) external view returns (uint256, uint256) {
        require(live, "PriceNotLive");
        return (price, block.timestamp);
    }
}

contract LaunchReadiness {
    uint256 public paidDeskCount = 1;
    uint256 public opsAvailable = 1 ether;

    function set(uint256 n, uint256 funds) external {
        paidDeskCount = n;
        opsAvailable = funds;
    }
}

contract V3LaunchTest is Test {
    PoolManager manager;
    PositionManager positions;
    V3FeeLedger ledger;
    V3QuoteFeeHook hook;
    V3LaunchStrategy strategy;
    V3LPLocker locker;
    V3LaunchFactory factory;
    HookToken stock;
    LaunchStockStatus status;
    LaunchPriceOracle priceOracle;
    address module;
    address rights;
    LaunchReadiness ready;
    V3LaunchFactory.Components cfg;
    EligibilityController controller;
    RewardPayoutVault payout;
    RewardRoundManager rounds;
    RewardAssetSchedule calendar;

    function setUp() public {
        manager = new PoolManager(address(this));
        positions = new PositionManager(
            manager, IAllowanceTransfer(address(0)), 100000, IPositionDescriptor(address(0)), IWETH9(address(0))
        );
        stock = new HookToken();
        module = address(new HookFeeReceiver());
        status = new LaunchStockStatus();
        ready = new LaunchReadiness();
        priceOracle = new LaunchPriceOracle();
        address buyback = address(new HookFeeReceiver());
        address protocol = address(new HookFeeReceiver());
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5);
        ledger = new V3FeeLedger(predicted, address(0));
        rights = address(new CreatorRightsNFT(predicted, ledger, address(0)));
        strategy = new V3LaunchStrategy(predicted, IPositionManager(address(positions)));
        locker = new V3LPLocker(predicted, IPositionManager(address(positions)));
        bytes memory init = abi.encodePacked(type(V3QuoteFeeHook).creationCode, abi.encode(manager, predicted, ledger));
        (, bytes32 hookSalt) = V3HookMiner.find(address(this), keccak256(init), 0, 1000000);
        hook = new V3QuoteFeeHook{salt: hookSalt}(manager, predicted, IV3HookFeeLedger(address(ledger)));
        address[] memory custodians = new address[](1);
        custodians[0] = address(0xcafe);
        V3LaunchFactory.Components memory c = V3LaunchFactory.Components(
            ledger,
            hook,
            strategy,
            IPositionManager(address(positions)),
            address(locker),
            rights,
            address(stock),
            [module, module, buyback, protocol],
            address(priceOracle),
            address(status),
            address(ready),
            custodians
        );
        cfg = c;
        V3LaunchFactory.QuoteConfig[] memory quotes = new V3LaunchFactory.QuoteConfig[](1);
        quotes[0] = V3LaunchFactory.QuoteConfig(1, address(stock), keccak256("NVDA"), address(0x1234));
        factory = FactoryDeploy.deploy(c, quotes); // == new V3LaunchFactory(c, quotes); see helper
        assertEq(address(factory), predicted);
        (bool early,) = address(factory)
            .call(
                abi.encodeCall(
                    factory.launch,
                    (
                        "Early",
                        "EARLY",
                        bytes32(0),
                        bytes32(uint256(99999)),
                        address(this),
                        V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
                        uint256(0)
                    )
                )
            );
        assertFalse(early, "unconfigured factory can be front-run");
        controller = new EligibilityController(address(this));
        controller.bindAsset(address(stock), 0);
        payout = new RewardPayoutVault(new address[](0), controller);
        StockAdapterRegistry registry = new StockAdapterRegistry(address(this));
        rounds = new RewardRoundManager(address(this), address(registry), address(payout), address(0xFEE));
        payout.configureFactory(address(factory));
        rounds.configureSourceFactory(address(factory));
        address[] memory calendarAssets = new address[](1);
        calendarAssets[0] = address(stock);
        bytes32[] memory calendarIds = new bytes32[](1);
        calendarIds[0] = keccak256("NVDA");
        uint32[] memory calendarVersions = new uint32[](1);
        calendarVersions[0] = 3;
        bytes32[] memory calendarPrices = new bytes32[](1);
        calendarPrices[0] = keccak256("CALENDAR");
        calendar = new RewardAssetSchedule(
            block.timestamp / 1 days, 2, calendarAssets, calendarIds, calendarVersions, calendarPrices
        );
        factory.configureAssetSchedule(address(calendar));
        factory.declareRewardEpoch(
            block.timestamp / 1 days + 3, address(stock), keccak256("NVDA"), 2, keccak256("PRICE2")
        );
        EligibilityController wrongController = new EligibilityController(address(this));
        (bool mismatch,) = address(factory)
            .call(
                abi.encodeCall(
                    factory.configureRewardInfrastructure,
                    (
                        address(wrongController),
                        address(payout),
                        address(rounds),
                        keccak256("NVDA"),
                        uint32(1),
                        keccak256("PRICE")
                    )
                )
            );
        assertFalse(mismatch, "mismatched delivery policy accepted");
        factory.configureRewardInfrastructure(
            address(controller), address(payout), address(rounds), keccak256("NVDA"), 1, keccak256("PRICE")
        );
    }

    function testInfrastructureBindingFreezesOptionalPolicies() public {
        vm.expectRevert();
        factory.declareRewardEpoch(
            block.timestamp / 1 days + 100, address(stock), keccak256("NVDA"), 4, keccak256("LATE")
        );
    }

    function testRewardInfrastructureCanBeBoundOnlyOnceBeforeLaunch() public {
        bytes memory data = abi.encodeWithSignature(
            "configureRewardInfrastructure(address,address,address,bytes32,uint32,bytes32)",
            address(status),
            module,
            module,
            keccak256("NVDA"),
            uint32(1),
            keccak256("PRICE")
        );
        vm.prank(address(12345));
        (bool unauthorized,) = address(factory).call(data);
        assertFalse(unauthorized);

        (bool duplicate,) = address(factory).call(data);
        assertFalse(duplicate);
    }

    function testCannotBindRewardInfrastructureAfterFirstLaunch() public {
        factory.launch(
            "Meme",
            "MEME",
            0,
            bytes32(uint256(987)),
            address(this),
            V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
            uint256(0)
        );
        bytes memory data = abi.encodeWithSignature(
            "configureRewardInfrastructure(address,address,address,bytes32,uint32,bytes32)",
            address(status),
            module,
            module,
            keccak256("NVDA"),
            uint32(1),
            keccak256("PRICE")
        );
        (bool configured,) = address(factory).call(data);
        assertFalse(configured, "must freeze before launch");
    }

    function testLaunchWiresActualPhaseThreeSources() public {
        uint256 futureEpoch = block.timestamp / 1 days + 3;
        V3LaunchFactory.Launch memory r = factory.launch(
            "Meme",
            "MEME",
            0,
            bytes32(uint256(988)),
            address(this),
            V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
            uint256(0)
        );
        assertEq(address(V3RewardToken(payable(r.token)).eligibilityController()), address(controller));
        assertEq(V3RewardToken(payable(r.token)).payout(), address(payout));
        assertTrue(payout.trustedSource(r.token));
        assertTrue(payout.trustedSource(address(rounds.vault())));
        assertEq(rounds.sourcePool(r.token), r.poolId);
        (, uint32 policyVersion,,) = V3RewardToken(payable(r.token)).rewardPolicy(futureEpoch, 0);
        assertEq(policyVersion, 2);
    }

    function testFactoryWiresImmutableCalendarSchedule() public {
        V3LaunchFactory.Launch memory r = factory.launch(
            "Meme",
            "MEME",
            0,
            bytes32(uint256(989)),
            address(this),
            V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
            uint256(0)
        );
        (, uint32 version,,) = V3RewardToken(payable(r.token)).rewardPolicy(block.timestamp / 1 days + 5, 0);
        assertEq(version, 3);
    }

    function testNewAEnabledPoolIsAutomaticallyRegistered() public {
        EligibilityRegistry identity = new EligibilityRegistry(address(this));
        identity.configureFactory(address(factory));
        uint256 effective = block.timestamp / 1 days + 3;
        controller.scheduleEnable(address(identity), keccak256("REGION"), effective);
        vm.warp(effective * 1 days);
        V3LaunchFactory.Launch memory r = factory.launch(
            "Meme",
            "MEME",
            0,
            bytes32(uint256(991)),
            address(this),
            V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
            uint256(0)
        );
        assertTrue(identity.rewardModule(r.token), "new A pool missing registration");
    }

    function testMismatchedLedgerRegistrationRevertsEntireLaunch() public {
        V3FeeLedger.Pool memory wrong;
        wrong.quote = address(stock);
        wrong.settlementKind = 1;
        wrong.hook = address(hook);
        wrong.beneficiaries = [_predict(bytes32(uint256(701))), rights, module, module, cfg.modules[2], cfg.modules[3]];
        vm.mockCall(address(ledger), abi.encodeWithSelector(V3FeeLedger.poolInfo.selector), abi.encode(wrong));
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        factory.launch(
            "Meme",
            "MEME",
            0,
            bytes32(uint256(701)),
            address(this),
            V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
            uint256(0)
        );
    }

    function testNativeLaunchLocksWholeSupply() public {
        V3LaunchFactory.Launch memory r = factory.launch(
            "Meme",
            "MEME",
            keccak256("metadata"),
            bytes32(uint256(1)),
            address(this),
            V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
            uint256(0)
        );
        assertTrue(r.token != address(0), "launch token missing");
        assertEq(r.token, _predict(bytes32(uint256(1))), "unchanged CREATE2 initcode");
        assertLe(r.token.code.length, 24576, "reward token exceeds EIP170");
        assertEq(uint8(r.state), uint8(V3LaunchFactory.State.Locked));
        assertEq(V3RewardToken(payable(r.token)).totalSupply(), 1e27);
        assertEq(r.initialTick, 123800);
        assertEq(r.lower, -160100);
        assertEq(r.upper, 123800);
        assertEq(positions.ownerOf(r.positionId), address(locker));
        assertEq(IERC20(r.token).balanceOf(address(manager)) + IERC20(r.token).balanceOf(address(0xdead)), 1e27);
        assertEq(IERC20(r.token).balanceOf(address(strategy)), 0);
        assertGt(r.liquidity, 0);
    }

    function testOnlyCreatorCanConsumeSalt() public {
        vm.expectRevert();
        factory.launch(
            "Meme",
            "MEME",
            0,
            bytes32(uint256(1)),
            address(0xbeef),
            V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
            uint256(0)
        );
    }

    function testDuplicateSaltCannotChangeName() public {
        factory.launch(
            "Meme",
            "MEME",
            0,
            bytes32(uint256(1)),
            address(this),
            V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
            uint256(0)
        );
        vm.expectRevert();
        factory.launch(
            "Different",
            "DIFF",
            0,
            bytes32(uint256(1)),
            address(this),
            V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
            uint256(0)
        );
    }

    function testFactoryRegistersNativeCustodyBeforeFirstSwap() public {
        address marker = address(new LaunchOperatingMode());
        vm.etch(cfg.modules[2], marker.code);
        vm.etch(cfg.modules[3], marker.code);
        V3LaunchFactory.Launch memory r = factory.launch(
            "Meme",
            "MEME",
            0,
            bytes32(uint256(999123)),
            address(this),
            V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
            uint256(0)
        );
        assertTrue(ledger.controlledClaim(r.poolId, 4));
        assertTrue(ledger.controlledClaim(r.poolId, 5));
    }

    function testFactoryPinsSeparateStockConverterAndExcludesCustody() public {
        address converter = address(
            new StockFeeConverter(
                ledger,
                vm.addr(44),
                module,
                cfg.modules[2],
                cfg.modules[3],
                address(55),
                25,
                1,
                keccak256("fixed-stock-route"),
                address(this),
                address(priceOracle)
            )
        );
        (bool ok,) = address(factory).call(abi.encodeWithSignature("configureStockFeeConverter(address)", converter));
        assertTrue(ok);
        bytes32 salt = bytes32(uint256(999124));
        address[] memory excluded = new address[](12);
        excluded[0] = address(manager);
        excluded[1] = address(positions);
        excluded[2] = address(hook);
        excluded[3] = address(locker);
        excluded[4] = rights;
        excluded[5] = address(factory);
        excluded[6] = module;
        excluded[7] = module;
        excluded[8] = cfg.modules[2];
        excluded[9] = cfg.modules[3];
        excluded[10] = address(0xcafe);
        excluded[11] = converter;
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(V3RewardToken).creationCode,
                abi.encode("Meme", "MEME", address(strategy), address(ledger), excluded)
            )
        );
        address token = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(factory), keccak256(abi.encode(address(this), salt)), initHash
                        )
                    )
                )
            )
        );
        V3LaunchFactory.Launch memory launched = _launchStock(salt);
        assertEq(launched.token, token);
        V3FeeLedger.Pool memory pool = ledger.poolInfo(launched.poolId);
        assertEq(pool.beneficiaries[4], converter);
        assertEq(pool.beneficiaries[5], converter);
        assertTrue(ledger.stockLotCustody(launched.poolId, 4));
        assertTrue(ledger.stockLotCustody(launched.poolId, 5));
        assertTrue(V3RewardToken(payable(launched.token)).excluded(converter));
        (ok,) = address(factory)
            .call(
                abi.encodeWithSignature("configureStockFeeConverter(address)", address(new LaunchStockOperatingMode()))
            );
        assertFalse(ok);
    }

    function _predict(bytes32 salt) internal view returns (address) {
        address[] memory excluded = new address[](11);
        excluded[0] = address(manager);
        excluded[1] = address(positions);
        excluded[2] = address(hook);
        excluded[3] = address(locker);
        excluded[4] = rights;
        excluded[5] = address(factory);
        excluded[6] = module;
        excluded[7] = module;
        excluded[8] = cfg.modules[2];
        excluded[9] = cfg.modules[3];
        excluded[10] = address(0xcafe);
        bytes32 hash = keccak256(
            abi.encodePacked(
                type(V3RewardToken).creationCode,
                abi.encode("Meme", "MEME", address(strategy), address(ledger), excluded)
            )
        );
        return vm.computeCreate2Address(keccak256(abi.encode(address(this), salt)), hash, address(factory));
    }

    function _launchStock(bytes32 salt) internal returns (V3LaunchFactory.Launch memory) {
        return factory.launch(
            "Meme",
            "MEME",
            0,
            salt,
            address(this),
            V3LaunchFactory.QuoteConfig(1, address(stock), keccak256("NVDA"), address(0x1234)),
            0
        );
    }

    function testStockBothSortingsOracleSingleSidedLaunch() public {
        bool gotLow;
        bool gotHigh;
        // The fixed stock fixture sits near the top of the address range. Token
        // bytecode changes move CREATE2 outputs, so 40 salts do not reliably
        // cover both sides. Keep the mandatory two-layout assertion below.
        for (uint256 i = 1; i <= 4096 && !(gotLow && gotHigh); i++) {
            bytes32 salt = bytes32(i);
            bool quote0 = address(stock) < _predict(salt);
            if (quote0 ? gotLow : gotHigh) continue;
            V3LaunchFactory.Launch memory r = _launchStock(salt);
            assertEq(r.initialTick, quote0 ? int24(169900) : int24(-169900));
            assertEq(r.upper - r.lower, 283900);
            assertEq(positions.ownerOf(r.positionId), address(locker));
            assertEq(IERC20(r.token).balanceOf(address(manager)) + IERC20(r.token).balanceOf(address(0xdead)), 1e27);
            assertEq(stock.balanceOf(address(manager)), 0);
            if (quote0) gotLow = true;
            else gotHigh = true;
        }
        assertTrue(gotLow && gotHigh, "both sorting layouts exercised");
    }

    /// @dev r7: the opening price is the oracle's execution price; a non-Live oracle blocks stock launches only.
    function testStockLaunchRequiresLiveOraclePrice() public {
        bytes32 salt = bytes32(uint256(61));
        priceOracle.set(100 ether, false);
        vm.expectRevert();
        _launchStock(salt);
        assertFalse(factory.usedSalt(keccak256(abi.encode(address(this), salt))), "atomic");
        _native(bytes32(uint256(62))); // native USDC launches never read the oracle
        priceOracle.set(0, true);
        vm.expectRevert(V3LaunchValidation.InvalidQuote.selector);
        _launchStock(salt);
        priceOracle.set(100 ether, true);
        assertEq(_launchStock(salt).token, _predict(salt));
    }

    function testStockOpeningTickFollowsOraclePrice() public {
        bytes32 a = bytes32(uint256(63));
        bytes32 b = bytes32(uint256(64));
        V3LaunchFactory.Launch memory r1 = _launchStock(a);
        priceOracle.set(400 ether, true);
        V3LaunchFactory.Launch memory r2 = _launchStock(b);
        int24 t1 = address(stock) < r1.token ? r1.initialTick : -r1.initialTick;
        int24 t2 = address(stock) < r2.token ? r2.initialTick : -r2.initialTick;
        assertEq(t1, 169900);
        assertEq(t2, strategy.stockTick(400 ether));
        assertGt(t2, t1);
    }

    /// @dev For any Live oracle price inside the strategy's band, the opening tick is exactly the §3.3 tick of
    ///      that price (sign by sorting) and the range stays single-sided at the opening price; outside the band
    ///      the launch reverts instead of clamping.
    function testFuzzStockOpeningTickIsTheOracleTick(uint256 price, uint256 saltSeed) public {
        price = bound(price, 1e9, 1e30);
        priceOracle.set(price, true);
        bytes32 salt = bytes32(bound(saltSeed, 1_000, type(uint64).max));
        int24 want;
        try strategy.stockTick(price) returns (int24 t) {
            want = t;
        } catch {
            vm.expectRevert();
            _launchStock(salt);
            return;
        }
        V3LaunchFactory.Launch memory r = _launchStock(salt);
        bool quote0 = address(stock) < r.token;
        assertEq(r.initialTick, quote0 ? want : -want);
        assertEq(quote0 ? r.upper : r.lower, r.initialTick, "opening price at the meme-only boundary");
        assertEq(r.upper - r.lower, 283900);
    }

    function testStockStateChecked() public {
        bytes32 salt = bytes32(uint256(66));
        status.set(false, true, 1);
        vm.expectRevert();
        _launchStock(salt);
        status.set(true, false, 1);
        vm.expectRevert();
        _launchStock(salt);
        status.set(true, true, 2); // multiplier versions no longer matter: the Chainlink price includes it
        _launchStock(salt);
    }

    function testStockAssetIdentityCannotBeSubstituted() public {
        bytes32 salt = bytes32(uint256(68));
        vm.expectRevert();
        factory.launch(
            "Meme",
            "MEME",
            0,
            salt,
            address(this),
            V3LaunchFactory.QuoteConfig(1, address(stock), keccak256("FAKE"), address(0x1234)),
            0
        );
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function testLaunchRequiresPaidDeskAndOpsFunds() public {
        ready.set(0, 1 ether);
        vm.expectRevert();
        factory.launch(
            "Meme",
            "MEME",
            0,
            bytes32(uint256(90)),
            address(this),
            V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
            uint256(0)
        );
        ready.set(1, 0);
        vm.expectRevert();
        factory.launch(
            "Meme",
            "MEME",
            0,
            bytes32(uint256(90)),
            address(this),
            V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
            uint256(0)
        );
    }

    function testEveryConfiguredCustodianExcludedFromRewards() public {
        V3LaunchFactory.Launch memory r = factory.launch(
            "Meme",
            "MEME",
            0,
            bytes32(uint256(91)),
            address(this),
            V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)),
            uint256(0)
        );
        for (uint256 i; i < 4; i++) {
            assertTrue(V3RewardToken(payable(r.token)).excluded(cfg.modules[i]), "module exclusion missing");
        }
        assertTrue(V3RewardToken(payable(r.token)).excluded(address(0xcafe)), "custody exclusion missing");
        assertEq(CreatorRightsNFT(payable(rights)).ownerOfPool(r.poolId), address(this));
    }

    function testFactoryRejectsDependenciesBoundToAnotherFactory() public {
        V3LaunchFactory.QuoteConfig[] memory empty = new V3LaunchFactory.QuoteConfig[](0);
        vm.expectRevert();
        new V3LaunchFactory(cfg, empty);
    }

    function testFactoryFitsEIP170RuntimeLimit() public view {
        assertLe(address(factory).code.length, 24576, "factory exceeds EIP170");
        assertLe(factory.tokenCodePart1().code.length, 24576);
        assertLe(factory.tokenCodePart2().code.length, 24576);
        V3LaunchFactory.QuoteConfig[] memory quoteConfigs = new V3LaunchFactory.QuoteConfig[](1);
        quoteConfigs[0] = V3LaunchFactory.QuoteConfig(1, address(stock), keccak256("NVDA"), address(0x1234));
        assertLe(
            type(V3LaunchFactory).creationCode.length + abi.encode(cfg, quoteConfigs).length,
            49152,
            "factory initcode exceeds EIP3860"
        );
    }

    receive() external payable {}

    function _native(bytes32 salt) internal returns (V3LaunchFactory.Launch memory r) {
        return factory.launch(
            "Meme", "MEME", 0, salt, address(this), V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)), 0
        );
    }

    function testRealLaunchFirstBuyPaysSixBucketsAndCreator() public {
        vm.deal(address(this), 1000 ether);
        V3LaunchFactory.Launch memory r = _native(bytes32(uint256(200)));
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(r.token), 0, 100, IHooks(address(hook)));
        V3Router route = new V3Router(manager, hook, IV3TradeEligibility(address(0)));
        route.swap{value: 100 ether}(
            V3Router.SwapRequest(key, true, -100 ether, 0, 1, 100 ether, address(this), vm.getBlockTimestamp())
        );
        assertEq(ledger.totalReceived(r.poolId), 1 ether);
        uint256[6] memory expected = [uint256(0.575 ether), 0.1 ether, 0.1 ether, 0.05 ether, 0.1 ether, 0.075 ether];
        for (uint256 i; i < 6; i++) {
            assertEq(ledger.accrued(r.poolId, i), expected[i]);
        }
        uint256 id = CreatorRightsNFT(payable(rights)).tokenOfPool(r.poolId);
        uint256 beforeBalance = address(this).balance;
        assertTrue(CreatorRightsNFT(payable(rights)).claimCreator(id, address(0), 0.1 ether, 0));
        assertEq(address(this).balance, beforeBalance + 0.1 ether);
        uint256 bought = IERC20(r.token).balanceOf(address(this));
        assertGt(bought, 0);
        // The buyer earns from the next fee without activation, but not from its own buy fee.
        assertEq(V3RewardToken(payable(r.token)).totalEligible(), bought);
        assertEq(V3RewardToken(payable(r.token)).epochCredit27(address(this), vm.getBlockTimestamp() / 1 days), 0);
        assertEq(strategy.initialPositionContext(r.poolId), bytes32(0));
    }

    function testRealRouterSameTransactionBuyThenSellEarnsZero() public {
        vm.deal(address(this), 1000 ether);
        V3LaunchFactory.Launch memory r = _native(bytes32(uint256(205)));
        V3RewardToken token = V3RewardToken(payable(r.token));
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(r.token), 0, 100, IHooks(address(hook)));
        V3Router route = new V3Router(manager, hook, IV3TradeEligibility(address(0)));
        address holder = address(0xB0B);
        route.swap{value: 10 ether}(
            V3Router.SwapRequest(key, true, -10 ether, 0, 1, 10 ether, holder, vm.getBlockTimestamp())
        );
        route.swap{value: 100 ether}(
            V3Router.SwapRequest(key, true, -100 ether, 0, 1, 100 ether, address(this), vm.getBlockTimestamp())
        );
        uint256 bought = token.balanceOf(address(this));
        token.approve(address(route), bought);
        route.swap(
            V3Router.SwapRequest(key, false, -int256(bought), 0, 1, bought, address(this), vm.getBlockTimestamp())
        );
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.eligible(address(this)), 0);
        assertEq(token.epochCredit27(address(this), epoch), 0, "flash buyer earned");
        assertGt(token.epochCredit27(holder, epoch), 0, "resting holder must earn both flash fees");
        assertEq(token.totalEligible(), token.balanceOf(holder));
    }

    function testRealLaunchStockFirstBuyNeverNeedsStockAtInitialization() public {
        bytes32 salt = bytes32(uint256(201));
        V3LaunchFactory.Launch memory r = _launchStock(salt);
        assertEq(stock.balanceOf(address(manager)), 0);
        bool q0 = address(stock) < r.token;
        PoolKey memory key = PoolKey(
            Currency.wrap(q0 ? address(stock) : r.token),
            Currency.wrap(q0 ? r.token : address(stock)),
            0,
            100,
            IHooks(address(hook))
        );
        V3Router route = new V3Router(manager, hook, IV3TradeEligibility(address(0)));
        stock.mint(address(this), 1 ether);
        stock.approve(address(route), 1 ether);
        route.swap(V3Router.SwapRequest(key, true, -1 ether, 0, 1, 1 ether, address(this), vm.getBlockTimestamp()));
        assertEq(ledger.totalReceived(r.poolId), 0.01 ether);
        uint256 id = CreatorRightsNFT(payable(rights)).tokenOfPool(r.poolId);
        assertTrue(CreatorRightsNFT(payable(rights)).claimCreator(id, address(stock), 0.001 ether, 0));
        assertEq(stock.balanceOf(address(this)), 0.001 ether);
    }

    function testRealPositionManagerCannotAddSecondPosition() public {
        V3LaunchFactory.Launch memory r = _native(bytes32(uint256(202)));
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(r.token), 0, 100, IHooks(address(hook)));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(key, r.lower, r.upper, uint256(1), uint128(0), uint128(1e27), address(this), bytes(""));
        vm.expectRevert();
        positions.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION)), params), vm.getBlockTimestamp()
        );
        assertEq(hook.initialPositionId(PoolId.wrap(r.poolId)), r.positionId);
        assertEq(positions.ownerOf(r.positionId), address(locker));
    }

    function testOverflowOraclePriceRejectedAtomically() public {
        bytes32 salt = bytes32(uint256(204));
        priceOracle.set(type(uint256).max, true);
        vm.expectRevert();
        _launchStock(salt);
        assertEq(_predict(salt).code.length, 0);
    }

    // ------------------------------------------------------------ r7: creator-chosen payout stock

    function _choices() internal returns (LaunchPayoutChoice choice, HookToken aapl) {
        aapl = new HookToken();
        controller.bindAsset(address(aapl), 1);
        choice = new LaunchPayoutChoice(address(this), address(status));
        choice.bindFactory(address(factory));
        factory.configurePayoutChoice(address(choice));
        assertEq(choice.approve(address(aapl), keccak256("AAPL"), 1, keccak256("PRICE-AAPL")), 1);
    }

    function testCreatorChoosesPayoutStockBeforeLaunch() public {
        (LaunchPayoutChoice choice, HookToken aapl) = _choices();
        bytes32 salt = bytes32(uint256(300));
        vm.expectEmit(false, false, false, false, address(factory));
        emit V3RewardWiring.LaunchPayoutChosen(bytes32(0), address(0), 0, address(0));
        V3LaunchFactory.Launch memory r = factory.launch(
            "Meme", "MEME", 0, salt, address(this), V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)), 1
        );
        V3RewardToken t = V3RewardToken(payable(r.token));
        assertEq(t.defaultRewardAsset(), address(aapl));
        assertEq(address(t.assetSchedule()), address(0), "a chosen stock replaces the factory calendar");
        uint256 epoch = block.timestamp / 1 days;
        (bytes32 id, uint32 v, bytes32 pp,) = t.rewardPolicy(epoch + 3, 0); // factory epoch policy not applied
        assertEq(id, keccak256("AAPL"));
        assertEq(v, 1);
        assertEq(pp, keccak256("PRICE-AAPL"));
        assertEq(choice.choiceOf(r.token), 1);
        (uint256[] memory ids, address[] memory assets) = choice.choicesOf(_one(r.token));
        assertEq(ids[0], 1);
        assertEq(assets[0], address(aapl));
    }

    function testDefaultChoiceIsFactoryNvda() public {
        (LaunchPayoutChoice choice,) = _choices();
        V3LaunchFactory.Launch memory r = _native(bytes32(uint256(301)));
        V3RewardToken t = V3RewardToken(payable(r.token));
        assertEq(t.defaultRewardAsset(), address(stock));
        assertEq(address(t.assetSchedule()), address(calendar));
        assertEq(choice.choiceOf(r.token), 0);
    }

    function testPayoutChoiceRejections() public {
        (LaunchPayoutChoice choice,) = _choices();
        // stock-quote coins are paid in their quote stock
        vm.expectRevert(V3RewardWiring.InvalidPayoutChoice.selector);
        factory.launch(
            "Meme",
            "MEME",
            0,
            bytes32(uint256(302)),
            address(this),
            V3LaunchFactory.QuoteConfig(1, address(stock), keccak256("NVDA"), address(0x1234)),
            1
        );
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.BadChoice.selector, 2));
        factory.launch(
            "Meme", "MEME", 0, bytes32(uint256(303)), address(this), V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)), 2
        );
        choice.setEnabled(1, false);
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.BadChoice.selector, 1));
        factory.launch(
            "Meme", "MEME", 0, bytes32(uint256(304)), address(this), V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)), 1
        );
        choice.setEnabled(1, true);
        status.set(false, true, 1); // hub stopped listing the stock
        vm.expectRevert();
        factory.launch(
            "Meme", "MEME", 0, bytes32(uint256(305)), address(this), V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)), 1
        );
        vm.expectRevert();
        choice.approve(address(stock), keccak256("NVDA"), 1, keccak256("P"));
        vm.expectRevert(LaunchPayoutChoice.NotFactory.selector);
        choice.choose(address(1), 1);
        vm.prank(address(0xbad));
        vm.expectRevert(LaunchPayoutChoice.NotGovernance.selector);
        choice.approve(address(stock), keccak256("NVDA"), 1, keccak256("P"));
    }

    function testPayoutChoiceFixedBeforeFirstLaunch() public {
        _native(bytes32(uint256(306)));
        LaunchPayoutChoice late = new LaunchPayoutChoice(address(this), address(status));
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        factory.configurePayoutChoice(address(late));
        vm.expectRevert(V3RewardWiring.InvalidPayoutChoice.selector);
        factory.launch(
            "Meme", "MEME", 0, bytes32(uint256(307)), address(this), V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)), 1
        );
    }

    function _one(address a) internal pure returns (address[] memory x) {
        x = new address[](1);
        x[0] = a;
    }

    function testFuzzStockTickRoundsMemeDollarPriceDown(uint256 price) public {
        price = bound(price, 1e12, 1e30);
        bytes32 salt = bytes32(uint256(205));
        priceOracle.set(price, true);
        V3LaunchFactory.Launch memory r = _launchStock(salt);
        int24 qtick = address(stock) < r.token ? r.initialTick : -r.initialTick;
        assertEq(qtick % 100, 0);
        uint160 base = TickMath.getSqrtPriceAtTick(123800);
        uint256 target = FullMath.mulDiv(FullMath.mulDiv(base, base, 1 << 64), price, 1e18);
        uint160 root = TickMath.getSqrtPriceAtTick(qtick);
        uint160 prev = TickMath.getSqrtPriceAtTick(qtick - 100);
        assertGe(FullMath.mulDiv(root, root, 1 << 64), target);
        assertLt(FullMath.mulDiv(prev, prev, 1 << 64), target);
        assertEq(IERC20(r.token).balanceOf(address(manager)) + IERC20(r.token).balanceOf(address(0xdead)), 1e27);
    }
}

contract LaunchOperatingMode {
    function feeCustodyMode() external pure returns (uint8) {
        return 1;
    }
    receive() external payable {}
}

contract LaunchStockOperatingMode {
    function feeCustodyMode() external pure returns (uint8) {
        return 2;
    }
}
