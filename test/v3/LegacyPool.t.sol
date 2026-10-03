// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./V3Launch.t.sol";
import {CustodyStakeAsset, CustodyObserver} from "./StakingLedgerCustody.t.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {SolonStakingV2} from "../../src/v3/SolonStakingV2.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {RewardPayoutVault} from "../../src/v3/RewardPayoutVault.sol";
import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";

contract LegacyPoolTest is Test {
    function testLegacyHolderAndStakingBucketsUseIndependentMatureWeightSources() public {
        vm.warp(10 days);
        CustodyStakeAsset solon = new CustodyStakeAsset();
        CustodyStakeAsset stock = new CustodyStakeAsset();
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        EligibilityController controller = new EligibilityController(address(this));
        SolonStakingV2 staking = new SolonStakingV2(address(solon), address(ledger), controller);
        RewardPayoutVault payout = new RewardPayoutVault(new address[](0), controller);
        RewardRoundManager rounds = new RewardRoundManager(address(this), address(stock), address(payout), address(77));
        staking.configureRewards(address(rounds), address(payout));
        rounds.configureRewardModules(address(0), address(staking));
        payout.configureRewardModules(address(0), address(staking));
        bytes32 pool = keccak256("SOLON/NVDA");
        address observer = address(new CustodyObserver());
        address[6] memory recipients = [address(staking), observer, observer, address(staking), observer, observer];
        bytes memory data = abi.encodeWithSignature(
            "registerLegacyPool(bytes32,address,address,address[6])", pool, address(stock), address(this), recipients
        );
        (bool registered,) = address(ledger).call(data);
        assertTrue(registered, "legacy ledger registration missing");
        solon.mint(address(this), 100 ether);
        solon.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        assertEq(staking.eligible(address(this)), 100 ether, "stake must earn without activation");
        stock.mint(address(this), 100 ether);
        stock.approve(address(ledger), 100 ether);
        ledger.creditStock(pool, 100 ether);
        bytes32 holderSource = keccak256(abi.encode(keccak256("SOLON_NVDA_POOL"), pool));
        bytes32 holderKey = staking.poolLane(holderSource);
        assertTrue(holderKey != staking.poolLane(pool));
        assertEq(staking.creditOf(holderSource, 10, address(stock), 1, address(this)), 57.5 ether * 1e27);
        assertEq(staking.creditOf(pool, 10, address(stock), 1, address(this)), 5 ether * 1e27);
        uint256 sum;
        for (uint8 i; i < 6; ++i) {
            sum += ledger.accrued(pool, i);
        }
        assertEq(sum, 100 ether);
        vm.prank(address(0xbad));
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        ledger.claim(pool, 0, 1);
        address source = staking.createEntrySource(holderKey);
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = 10;
        payout.stageCredit(source, address(this), epochs, address(stock));
        assertEq(payout.readyRaw(address(this), address(stock)), 57.5 ether);
        assertEq(ledger.accrued(pool, 0), 0);
        assertEq(ledger.accrued(pool, 3), 5 ether);
        assertLe(address(staking).code.length, 24576, "staking EIP170");
    }
}

contract LegacyConverterBoundary {
    address public immutable ledger;
    address public immutable buyback;
    address public immutable protocol;

    constructor(address l, address b, address p) {
        ledger = l;
        buyback = b;
        protocol = p;
    }

    function feeCustodyMode() external pure returns (uint256) {
        return 2;
    }
}

contract LegacyFactoryTest is Test {
    PoolManager manager;
    PositionManager positions;
    V3FeeLedger ledger;
    V3QuoteFeeHook hook;
    V3LaunchFactory factory;
    SolonStakingV2 staking;
    CustodyStakeAsset solon;
    HookToken stock;
    CreatorRightsNFT rights;
    EligibilityController controller;
    address observer;
    uint256 factoryInitcodeSize;
    V3LaunchFactory.Components cfg;

    function setUp() public {
        vm.warp(10 days);
        manager = new PoolManager(address(this));
        positions = new PositionManager(
            manager, IAllowanceTransfer(address(0)), 100000, IPositionDescriptor(address(0)), IWETH9(address(0))
        );
        solon = new CustodyStakeAsset();
        stock = new HookToken();
        observer = address(new HookFeeReceiver());
        controller = new EligibilityController(address(this));
        controller.bindAsset(address(stock), 0);
        address status = address(new LaunchStockStatus());
        address ready = address(new LaunchReadiness());
        address priceOracle = address(new LaunchPriceOracle());
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 6);
        ledger = new V3FeeLedger(predicted, address(0));
        staking = new SolonStakingV2(address(solon), address(ledger), controller);
        rights = new CreatorRightsNFT(predicted, ledger, address(0));
        V3LaunchStrategy strategy = new V3LaunchStrategy(predicted, IPositionManager(address(positions)));
        V3LPLocker locker = new V3LPLocker(predicted, IPositionManager(address(positions)));
        bytes memory init = abi.encodePacked(type(V3QuoteFeeHook).creationCode, abi.encode(manager, predicted, ledger));
        (, bytes32 salt) = V3HookMiner.find(address(this), keccak256(init), 0, 1000000);
        hook = new V3QuoteFeeHook{salt: salt}(manager, predicted, IV3HookFeeLedger(address(ledger)));
        V3LaunchFactory.Components memory c = V3LaunchFactory.Components(
            ledger,
            hook,
            strategy,
            IPositionManager(address(positions)),
            address(locker),
            address(rights),
            address(stock),
            [observer, address(staking), observer, observer],
            priceOracle,
            status,
            ready,
            new address[](0)
        );
        V3LaunchFactory.QuoteConfig[] memory quotes = new V3LaunchFactory.QuoteConfig[](1);
        quotes[0] = V3LaunchFactory.QuoteConfig(1, address(stock), keccak256("NVDA"), address(0x1234));
        cfg = c;
        factoryInitcodeSize = type(V3LaunchFactory).creationCode.length + abi.encode(c, quotes).length;
        factory = FactoryDeploy.deploy(c, quotes); // == new V3LaunchFactory(c, quotes); see helper
        assertEq(address(factory), predicted);
        factory.configureStockFeeConverter(address(new LegacyConverterBoundary(address(ledger), observer, observer)));
        RewardPayoutVault payout = new RewardPayoutVault(new address[](0), controller);
        RewardRoundManager rounds = new RewardRoundManager(address(this), address(stock), address(payout), address(77));
        factory.configureRewardInfrastructure(
            address(controller), address(payout), address(rounds), keccak256("NVDA"), 1, keccak256("PRICE")
        );
        payout.configureFactory(address(factory));
        rounds.configureSourceFactory(address(factory));
        staking.configureRewards(address(rounds), address(payout));
        payout.configureRewardModules(address(0), address(staking));
        rounds.configureRewardModules(address(0), address(staking));
    }

    function _registration(address sink) internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "registerLegacyPool(address,address,address,address,uint160)",
            address(solon),
            address(stock),
            sink,
            address(this),
            uint160(1 << 96)
        );
    }

    function testGovernorWhitelistedLegacyRegistrationWaits48HoursAndFixesHolderSink() public {
        bytes memory registration = _registration(address(staking));
        vm.prank(address(0xbad));
        (bool badWhitelist,) =
            address(factory).call(abi.encodeWithSignature("whitelistLegacyToken(address)", address(solon)));
        assertFalse(badWhitelist);
        vm.prank(address(0xbad));
        (bool badSchedule,) =
            address(factory).call(abi.encodeWithSignature("scheduleLegacyPool(bytes32)", keccak256(registration)));
        assertFalse(badSchedule);
        (bool whitelist,) =
            address(factory).call(abi.encodeWithSignature("whitelistLegacyToken(address)", address(solon)));
        assertTrue(whitelist, "legacy whitelist missing");
        vm.prank(address(0xbad));
        (bool unauthorized,) = address(factory).call(registration);
        assertFalse(unauthorized);
        (bool scheduled,) =
            address(factory).call(abi.encodeWithSignature("scheduleLegacyPool(bytes32)", keccak256(registration)));
        assertTrue(scheduled, "legacy timelock scheduling missing");
        (bool early,) = address(factory).call(registration);
        assertFalse(early);
        vm.warp(block.timestamp + 48 hours);
        (bool wrongSink,) = address(factory).call(_registration(observer));
        assertFalse(wrongSink);
        (bool ok, bytes memory result) = address(factory).call(registration);
        assertTrue(ok, "legacy registration failed");
        bytes32 pool = abi.decode(result, (bytes32));
        V3FeeLedger.Pool memory info = ledger.poolInfo(pool);
        assertEq(info.beneficiaries[0], address(staking));
        assertEq(info.beneficiaries[3], address(staking));
        assertEq(rights.ownerOfPool(pool), address(this));
        assertEq(info.quote, address(stock));
        assertEq(info.hook, address(hook));
        (bool replay,) = address(factory).call(registration);
        assertFalse(replay);
        assertLe(address(factory).code.length, 24576);
        assertLe(factoryInitcodeSize, 49152, "factory EIP3860");
    }

    function _register() internal returns (bytes32 pool, PoolKey memory key) {
        bytes memory registration = _registration(address(staking));
        factory.whitelistLegacyToken(address(solon));
        factory.scheduleLegacyPool(keccak256(registration));
        vm.warp(block.timestamp + 48 hours);
        (bool ok, bytes memory data) = address(factory).call(registration);
        require(ok, "register");
        pool = abi.decode(data, (bytes32));
        bool quote0 = address(stock) < address(solon);
        key = PoolKey(
            Currency.wrap(quote0 ? address(stock) : address(solon)),
            Currency.wrap(quote0 ? address(solon) : address(stock)),
            0,
            100,
            IHooks(address(hook))
        );
    }

    /// @dev Split out of the test below only to keep `forge coverage --ir-minimum` within the stack limit.
    function _mintLegacyLiquidity(PoolKey memory key) internal {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            int24(-10000),
            int24(10000),
            uint256(100 ether),
            uint128(1000 ether),
            uint128(1000 ether),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, uint256(0), false);
        params[2] = abi.encode(key.currency1, uint256(0), false);
        positions.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function testLegacyAndNewTokenRealSwapsShareHookWithoutCrossAccounting() public {
        (bytes32 legacy, PoolKey memory legacyKey) = _register();
        manager.initialize(legacyKey, uint160(1 << 96));
        solon.mint(address(positions), 1000 ether);
        stock.mint(address(positions), 1000 ether);
        _mintLegacyLiquidity(legacyKey);
        solon.mint(address(this), 100 ether);
        solon.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        V3Router router = new V3Router(manager, hook, IV3TradeEligibility(address(controller)));
        stock.mint(address(this), 1 ether);
        stock.approve(address(router), 1 ether);
        router.swap(
            V3Router.SwapRequest(legacyKey, true, -int256(1 ether), 0, 1, 1 ether, address(this), block.timestamp)
        );
        assertEq(ledger.totalReceived(legacy), 0.01 ether);
        assertEq(ledger.accrued(legacy, 0), 0.00575 ether);
        assertEq(ledger.accrued(legacy, 3), 0.0005 ether);
        bytes32 source = keccak256(abi.encode(keccak256("SOLON_NVDA_POOL"), legacy));
        uint256 epoch = block.timestamp / 1 days;
        assertEq(staking.creditOf(source, epoch, address(stock), 1, address(this)), 0.00575 ether * 1e27);
        uint256 oldHolder = staking.sourceCredit(staking.poolLane(source), address(this), epoch);
        V3LaunchFactory.Launch memory launched = _launchStock();
        bool stock0 = address(stock) < launched.token;
        PoolKey memory newKey = PoolKey(
            Currency.wrap(stock0 ? address(stock) : launched.token),
            Currency.wrap(stock0 ? launched.token : address(stock)),
            0,
            100,
            IHooks(address(hook))
        );
        stock.mint(address(this), 1 ether);
        stock.approve(address(router), 1 ether);
        router.swap(V3Router.SwapRequest(newKey, true, -int256(1 ether), 0, 1, 1 ether, address(this), block.timestamp));
        assertEq(ledger.totalReceived(launched.poolId), 0.01 ether);
        assertEq(ledger.totalReceived(legacy), 0.01 ether);
        assertEq(staking.sourceCredit(staking.poolLane(source), address(this), epoch), oldHolder);
        assertTrue(staking.poolLane(launched.poolId) != staking.poolLane(source));
        assertEq(ledger.poolInfo(launched.poolId).beneficiaries[0], launched.token);
        address adapter = staking.createEntrySource(staking.poolLane(source));
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = epoch;
        RewardPayoutVault pay = RewardPayoutVault(staking.payout());
        pay.stageCredit(adapter, address(this), epochs, address(stock));
        assertEq(pay.readyRaw(address(this), address(stock)), 0.00575 ether);
        assertEq(ledger.accrued(legacy, 0), 0);
        assertEq(ledger.accrued(launched.poolId, 0), 0.00575 ether);
        assertEq(ledger.accrued(legacy, 3), 0.0005 ether);
        assertEq(ledger.accrued(launched.poolId, 3), 0.0005 ether);
    }

    function _launchStock() internal returns (V3LaunchFactory.Launch memory) {
        address[] memory excluded = new address[](11);
        excluded[0] = address(manager);
        excluded[1] = address(positions);
        excluded[2] = address(hook);
        excluded[3] = cfg.locker;
        excluded[4] = address(rights);
        excluded[5] = address(factory);
        for (uint256 i; i < 4; i++) {
            excluded[6 + i] = cfg.modules[i];
        }
        excluded[10] = factory.stockFeeConverter();
        bytes32 salt = keccak256("new");
        bytes32 scoped = keccak256(abi.encode(address(this), salt));
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(V3RewardToken).creationCode,
                abi.encode("New", "NEW", address(cfg.strategy), address(ledger), excluded)
            )
        );
        address token = vm.computeCreate2Address(scoped, initHash, address(factory));
        V3LaunchFactory.QuoteConfig memory quote =
            V3LaunchFactory.QuoteConfig(1, address(stock), keccak256("NVDA"), address(0x1234));
        V3LaunchFactory.Launch memory l = factory.launch("New", "NEW", 0, salt, address(this), quote, 0);
        assertEq(l.token, token);
        return l;
    }

    function testScheduledArbitrarySinkAndUnwhitelistedTokenCannotRegister() public {
        factory.whitelistLegacyToken(address(solon));
        bytes memory badSink = _registration(observer);
        factory.scheduleLegacyPool(keccak256(badSink));
        bytes memory unlisted = abi.encodeWithSignature(
            "registerLegacyPool(address,address,address,address,uint160)",
            observer,
            address(stock),
            address(staking),
            address(this),
            uint160(1 << 96)
        );
        factory.scheduleLegacyPool(keccak256(unlisted));
        bytes memory wrongCreator = abi.encodeWithSignature(
            "registerLegacyPool(address,address,address,address,uint160)",
            address(solon),
            address(stock),
            address(staking),
            address(0xbad),
            uint160(1 << 96)
        );
        factory.scheduleLegacyPool(keccak256(wrongCreator));
        vm.warp(block.timestamp + 48 hours);
        (bool sinkOk,) = address(factory).call(badSink);
        assertFalse(sinkOk, "arbitrary holder sink");
        (bool tokenOk,) = address(factory).call(unlisted);
        assertFalse(tokenOk, "unwhitelisted legacy token");
        (bool creatorOk,) = address(factory).call(wrongCreator);
        assertFalse(creatorOk, "creator rights must belong to protocol governor");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
