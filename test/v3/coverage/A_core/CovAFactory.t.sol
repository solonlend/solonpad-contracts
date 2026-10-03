// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "../../V3Launch.t.sol";
import {V3TokenCodeStore} from "../../../../src/v3/V3TokenCodeStore.sol";
import {V3LegacyPools} from "../../../../src/v3/libraries/V3LegacyPools.sol";
import {PoolManager as CovAPM} from "@uniswap/v4-core/src/PoolManager.sol";

/// @dev Same CREATE as FactoryDeploy (incl. the coverage-only store-limit patch) but bubbles the
///      constructor's revert data so constructor arms can be asserted by selector.
library CovAFactoryDeployer {
    uint256 internal constant PRODUCTION_TOKEN_CODE_LIMIT = 44000;

    function tryDeploy(V3LaunchFactory.Components memory c, V3LaunchFactory.QuoteConfig[] memory quotes)
        internal
        returns (V3LaunchFactory factory, bytes memory err)
    {
        bytes memory init = type(V3LaunchFactory).creationCode;
        if (type(V3RewardToken).creationCode.length > PRODUCTION_TOKEN_CODE_LIMIT) _raise(init);
        init = abi.encodePacked(init, abi.encode(c, quotes));
        assembly ("memory-safe") {
            factory := create(0, add(init, 32), mload(init))
        }
        if (address(factory) == address(0)) {
            err = new bytes(0);
            assembly ("memory-safe") {
                err := mload(0x40)
                mstore(err, returndatasize())
                returndatacopy(add(err, 32), 0, returndatasize())
                mstore(0x40, add(add(err, 32), and(add(returndatasize(), 31), not(31))))
            }
        }
    }

    function _raise(bytes memory init) private pure {
        bytes memory store = type(V3TokenCodeStore).creationCode;
        bytes32 want = keccak256(store);
        uint256 at = type(uint256).max;
        for (uint256 i; i + store.length <= init.length; ++i) {
            bytes32 h;
            assembly ("memory-safe") {
                h := keccak256(add(add(init, 32), i), mload(store))
            }
            if (h == want) {
                at = i;
                break;
            }
        }
        require(at != type(uint256).max, "store");
        for (uint256 i = at; i + 2 < at + store.length; ++i) {
            if (init[i] == 0x61 && init[i + 1] == 0x5d && init[i + 2] == 0xc0) {
                init[i + 1] = 0xff;
                init[i + 2] = 0xff;
            }
        }
    }
}

contract CovAMockConverter {
    uint8 public feeCustodyMode = 2;
    address public ledger;
    address public buyback;
    address public protocol;

    constructor(address l, address b, address p) {
        ledger = l;
        buyback = b;
        protocol = p;
    }

    function set(uint8 m, address l, address b, address p) external {
        feeCustodyMode = m;
        ledger = l;
        buyback = b;
        protocol = p;
    }
}

contract CovADecimals6 {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

/// @notice Factory fixture bound to a fixed future CREATE address, so the factory constructor can be
/// re-attempted (nonce reset) with one mutated component at a time.
contract CovAFactoryTest is Test {
    uint64 constant FACTORY_NONCE = 900;
    PoolManager manager;
    PositionManager positions;
    V3FeeLedger ledger;
    V3QuoteFeeHook hook;
    V3LaunchStrategy strategy;
    V3LPLocker locker;
    HookToken stock;
    LaunchStockStatus status;
    LaunchPriceOracle priceOracle;
    LaunchReadiness ready;
    address module;
    address buyback;
    address protocol;
    address rights;
    address predicted;
    V3LaunchFactory.Components cfg;
    V3LaunchFactory factory;

    function setUp() public {
        vm.warp(30 days);
        predicted = vm.computeCreateAddress(address(this), FACTORY_NONCE);
        manager = new PoolManager(address(this));
        positions = new PositionManager(
            manager, IAllowanceTransfer(address(0)), 100000, IPositionDescriptor(address(0)), IWETH9(address(0))
        );
        stock = new HookToken();
        module = address(new HookFeeReceiver());
        buyback = address(new HookFeeReceiver());
        protocol = address(new HookFeeReceiver());
        status = new LaunchStockStatus();
        ready = new LaunchReadiness();
        priceOracle = new LaunchPriceOracle();
        ledger = new V3FeeLedger(predicted, address(0));
        rights = address(new CreatorRightsNFT(predicted, ledger, address(0)));
        strategy = new V3LaunchStrategy(predicted, IPositionManager(address(positions)));
        locker = new V3LPLocker(predicted, IPositionManager(address(positions)));
        bytes memory init = abi.encodePacked(type(V3QuoteFeeHook).creationCode, abi.encode(manager, predicted, ledger));
        (, bytes32 hookSalt) = V3HookMiner.find(address(this), keccak256(init), 0, 1000000);
        hook = new V3QuoteFeeHook{salt: hookSalt}(manager, predicted, IV3HookFeeLedger(address(ledger)));
        address[] memory custodians = new address[](1);
        custodians[0] = address(0xcafe);
        cfg = V3LaunchFactory.Components(
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
    }

    function _quotes() internal view returns (V3LaunchFactory.QuoteConfig[] memory quotes) {
        quotes = new V3LaunchFactory.QuoteConfig[](1);
        quotes[0] = V3LaunchFactory.QuoteConfig(1, address(stock), keccak256("NVDA"), address(0x1234));
    }

    /// External so vm.expectRevert can wrap the CREATE; CREATE sender stays address(this).
    function deployAt(V3LaunchFactory.Components memory c, V3LaunchFactory.QuoteConfig[] memory quotes)
        external
        returns (V3LaunchFactory f)
    {
        require(msg.sender == address(this));
        uint64 saved = vm.getNonce(address(this));
        vm.setNonceUnsafe(address(this), FACTORY_NONCE);
        bytes memory err;
        (f, err) = CovAFactoryDeployer.tryDeploy(c, quotes);
        vm.setNonceUnsafe(address(this), saved); // later `new`s in the test must never land on `predicted`
        if (address(f) == address(0)) {
            assembly ("memory-safe") {
                revert(add(err, 32), mload(err))
            }
        }
    }

    function _deploy() internal returns (V3LaunchFactory f) {
        f = this.deployAt(cfg, _quotes());
        assertEq(address(f), predicted);
        factory = f;
    }

    function _expectCtorRevert(V3LaunchFactory.Components memory c, V3LaunchFactory.QuoteConfig[] memory q, bytes4 sel)
        internal
    {
        vm.expectRevert(sel);
        this.deployAt(c, q);
        assertEq(predicted.code.length, 0);
    }

    // ---------------------------------------------------------------- constructor (lines 264-299)

    function testCtorBaselineDeploysAtPredictedAddress() public {
        V3LaunchFactory f = _deploy();
        assertEq(f.infrastructureConfigurator(), address(this));
        assertEq(f.approvedQuote(address(stock)), keccak256(abi.encode(_quotes()[0])));
        assertEq(f.tokenCodePart1().code.length != 0, true);
    }

    // line 281 short-circuit arm: no stock quotes -> oracle/status may be absent
    function testCtorWithoutQuotesNeedsNoOracle() public {
        cfg.priceOracle = address(0);
        cfg.stockStatus = address(0);
        V3LaunchFactory g = this.deployAt(cfg, new V3LaunchFactory.QuoteConfig[](0));
        assertEq(address(g), predicted);
        assertEq(g.approvedQuote(address(stock)), bytes32(0));
    }

    // line 269: every codeless component
    function testCtorRejectsCodelessComponents() public {
        address dead = address(0xDEAD01);
        V3LaunchFactory.QuoteConfig[] memory q = _quotes();
        V3LaunchFactory.Components memory c = cfg;
        c.ledger = V3FeeLedger(payable(dead));
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        c = cfg;
        c.hook = V3QuoteFeeHook(payable(dead));
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        c = cfg;
        c.strategy = V3LaunchStrategy(dead);
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        c = cfg;
        c.positions = IPositionManager(dead);
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        c = cfg;
        c.locker = dead;
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        c = cfg;
        c.rights = dead;
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        c = cfg;
        c.defaultRewardAsset = dead;
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        c = cfg;
        c.readiness = dead;
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
    }

    // line 280: each binding mismatch
    function testCtorRejectsComponentsBoundElsewhere() public {
        V3LaunchFactory.QuoteConfig[] memory q = _quotes();
        address other = address(0x0BAD);
        V3LaunchFactory.Components memory c = cfg;
        c.ledger = new V3FeeLedger(other, address(0));
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        c = cfg;
        c.strategy = new V3LaunchStrategy(other, IPositionManager(address(positions)));
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        c = cfg;
        c.locker = address(new V3LPLocker(other, IPositionManager(address(positions))));
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        c = cfg;
        c.rights = address(new CreatorRightsNFT(other, ledger, address(0)));
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        c = cfg;
        c.rights = address(new CreatorRightsNFT(predicted, new V3FeeLedger(predicted, address(0)), address(0)));
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        // positions on a different PoolManager than the hook's
        c = cfg;
        CovAPM pm2 = new CovAPM(address(this));
        c.positions = IPositionManager(
            address(
                new PositionManager(
                    pm2, IAllowanceTransfer(address(0)), 100000, IPositionDescriptor(address(0)), IWETH9(address(0))
                )
            )
        );
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        // strategy / locker bound to the right factory but another PositionManager on the same core
        IPositionManager otherPositions = IPositionManager(
            address(
                new PositionManager(
                    manager, IAllowanceTransfer(address(0)), 100000, IPositionDescriptor(address(0)), IWETH9(address(0))
                )
            )
        );
        c = cfg;
        c.strategy = new V3LaunchStrategy(predicted, otherPositions);
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        c = cfg;
        c.locker = address(new V3LPLocker(predicted, otherPositions));
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
    }

    // line 281: stock quotes need oracle and status code
    function testCtorQuotesRequireOracleAndStatus() public {
        V3LaunchFactory.QuoteConfig[] memory q = _quotes();
        V3LaunchFactory.Components memory c = cfg;
        c.priceOracle = address(0);
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidQuote.selector);
        c = cfg;
        c.stockStatus = address(0xDEAD02);
        _expectCtorRevert(c, q, V3LaunchFactory.InvalidQuote.selector);
    }

    // line 285: codeless module; line 288: zero system custodian
    function testCtorRejectsCodelessModuleAndZeroCustodian() public {
        V3LaunchFactory.QuoteConfig[] memory q = _quotes();
        for (uint256 i; i < 4; ++i) {
            V3LaunchFactory.Components memory c = cfg;
            c.modules[i] = address(0xDEAD03);
            _expectCtorRevert(c, q, V3LaunchFactory.InvalidLaunch.selector);
        }
        V3LaunchFactory.Components memory d = cfg;
        address[] memory custodians = new address[](2);
        custodians[0] = address(0xcafe);
        d.systemCustodians = custodians; // [1] == address(0)
        _expectCtorRevert(d, q, V3LaunchFactory.InvalidLaunch.selector);
    }

    // line 297: every invalid quote config arm
    function testCtorRejectsInvalidQuoteConfigs() public {
        V3LaunchFactory.QuoteConfig[] memory q = _quotes();
        q[0].kind = 0;
        _expectCtorRevert(cfg, q, V3LaunchFactory.InvalidQuote.selector);
        q = _quotes();
        q[0].asset = address(0xDEAD04);
        _expectCtorRevert(cfg, q, V3LaunchFactory.InvalidQuote.selector);
        q = _quotes();
        q[0].assetId = 0;
        _expectCtorRevert(cfg, q, V3LaunchFactory.InvalidQuote.selector);
        q = _quotes();
        q[0].underlying = address(0);
        _expectCtorRevert(cfg, q, V3LaunchFactory.InvalidQuote.selector);
        q = _quotes();
        q[0].asset = address(new CovADecimals6());
        _expectCtorRevert(cfg, q, V3LaunchFactory.InvalidQuote.selector);
        V3LaunchFactory.QuoteConfig[] memory dup = new V3LaunchFactory.QuoteConfig[](2);
        dup[0] = _quotes()[0];
        dup[1] = _quotes()[0];
        _expectCtorRevert(cfg, dup, V3LaunchFactory.InvalidQuote.selector);
        // quote equal to the ledger's native USDC view
        V3FeeLedger viewLedger = new V3FeeLedger(predicted, address(stock));
        V3LaunchFactory.Components memory c = cfg;
        c.ledger = viewLedger;
        // rights / hook are bound to the fixture ledger, so the first failing check is the binding (280);
        // swap them by mocking the getters so the quote loop is reached.
        vm.mockCall(address(hook), abi.encodeWithSignature("ledger()"), abi.encode(address(viewLedger)));
        vm.mockCall(rights, abi.encodeWithSignature("ledger()"), abi.encode(address(viewLedger)));
        _expectCtorRevert(c, _quotes(), V3LaunchFactory.InvalidQuote.selector);
        vm.clearMockedCalls();
    }

    // ---------------------------------------------------------------- runtime configuration

    function _infra(V3LaunchFactory f) internal returns (EligibilityController controller) {
        controller = new EligibilityController(address(this));
        controller.bindAsset(address(stock), 0);
        RewardPayoutVault payout = new RewardPayoutVault(new address[](0), controller);
        StockAdapterRegistry registry = new StockAdapterRegistry(address(this));
        RewardRoundManager rounds =
            new RewardRoundManager(address(this), address(registry), address(payout), address(0xFEE));
        payout.configureFactory(address(f));
        rounds.configureSourceFactory(address(f));
        f.configureRewardInfrastructure(
            address(controller), address(payout), address(rounds), keccak256("NVDA"), 1, keccak256("PRICE")
        );
    }

    function _native(bytes32 salt) internal returns (V3LaunchFactory.Launch memory) {
        return factory.launch(
            "Meme", "MEME", 0, salt, address(this), V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)), 0
        );
    }

    // lines 127-134: every configureStockFeeConverter arm
    function testConfigureStockFeeConverterArms() public {
        V3LaunchFactory f = _deploy();
        CovAMockConverter conv = new CovAMockConverter(address(ledger), buyback, protocol);
        vm.prank(address(0xBAD));
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.configureStockFeeConverter(address(conv));
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.configureStockFeeConverter(address(0xDEAD05)); // no code
        conv.set(1, address(ledger), buyback, protocol);
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.configureStockFeeConverter(address(conv));
        conv.set(2, address(0x1), buyback, protocol);
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.configureStockFeeConverter(address(conv));
        conv.set(2, address(ledger), protocol, protocol);
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.configureStockFeeConverter(address(conv));
        conv.set(2, address(ledger), buyback, buyback);
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.configureStockFeeConverter(address(conv));
        assertEq(f.stockFeeConverter(), address(0));
        conv.set(2, address(ledger), buyback, protocol);
        f.configureStockFeeConverter(address(conv));
        assertEq(f.stockFeeConverter(), address(conv));
        CovAMockConverter second = new CovAMockConverter(address(ledger), buyback, protocol);
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.configureStockFeeConverter(address(second)); // already set
    }

    function testConfigureStockFeeConverterFrozenAfterLaunch() public {
        _deploy();
        _infra(factory);
        _native(bytes32(uint256(1)));
        assertTrue(factory.hasLaunched());
        CovAMockConverter conv = new CovAMockConverter(address(ledger), buyback, protocol);
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        factory.configureStockFeeConverter(address(conv));
    }

    // lines 202-205: every configureAssetSchedule arm
    function testConfigureAssetScheduleArms() public {
        V3LaunchFactory f = _deploy();
        address sched = address(new CovADecimals6()); // any code
        vm.prank(address(0xBAD));
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.configureAssetSchedule(sched);
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.configureAssetSchedule(address(0xDEAD06));
        f.configureAssetSchedule(sched);
        assertEq(f.assetSchedule(), sched);
        address another = address(new CovADecimals6());
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.configureAssetSchedule(another);
    }

    function testConfigureAssetScheduleFrozenByInfrastructure() public {
        _deploy();
        _infra(factory);
        address sched = address(new CovADecimals6());
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        factory.configureAssetSchedule(sched);
        assertEq(factory.assetSchedule(), address(0));
    }

    // lines 213-219: every declareRewardEpoch arm incl. duplicate epoch and the 64-entry cap
    function testDeclareRewardEpochArms() public {
        V3LaunchFactory f = _deploy();
        uint256 today = block.timestamp / 1 days;
        address a = address(stock);
        vm.prank(address(0xBAD));
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.declareRewardEpoch(today, a, bytes32("id"), 1, bytes32("p"));
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.declareRewardEpoch(today - 1, a, bytes32("id"), 1, bytes32("p"));
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.declareRewardEpoch(today, address(0xDEAD07), bytes32("id"), 1, bytes32("p"));
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.declareRewardEpoch(today, a, 0, 1, bytes32("p"));
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.declareRewardEpoch(today, a, bytes32("id"), 0, bytes32("p"));
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.declareRewardEpoch(today, a, bytes32("id"), 1, 0);
        f.declareRewardEpoch(today, a, bytes32("id"), 1, bytes32("p")); // today itself is allowed
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.declareRewardEpoch(today, a, bytes32("id2"), 2, bytes32("p2")); // duplicate epoch (line 219)
        for (uint256 i = 1; i < 64; ++i) {
            f.declareRewardEpoch(today + i, a, bytes32("id"), 1, bytes32("p"));
        }
        (uint256 last,,,,) = f.epochPolicies(63);
        assertEq(last, today + 63);
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.declareRewardEpoch(today + 64, a, bytes32("id"), 1, bytes32("p")); // 65th entry
        _infra(f);
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        f.declareRewardEpoch(today + 100, a, bytes32("id"), 1, bytes32("p")); // frozen by infrastructure
    }

    // V3LegacyPools line 34: legacy administration is impossible before the controller is bound
    function testLegacyAdminRequiresInfrastructure() public {
        _deploy();
        vm.expectRevert(V3LegacyPools.InvalidLegacyPool.selector);
        factory.whitelistLegacyToken(address(stock));
        vm.expectRevert(V3LegacyPools.InvalidLegacyPool.selector);
        factory.scheduleLegacyPool(bytes32(uint256(1)));
        _infra(factory);
        factory.whitelistLegacyToken(address(stock)); // governor == this once bound
    }

    // line 176: unapproved legacy quote
    function testRegisterLegacyPoolRejectsUnapprovedQuote() public {
        _deploy();
        address unapproved = address(new HookToken());
        vm.expectRevert(V3LaunchFactory.InvalidQuote.selector);
        factory.registerLegacyPool(address(0x501), unapproved, module, address(this), uint160(1 << 96));
        assertFalse(factory.hasLaunched());
    }

    // line 98: CREATE2 of the token fails (gas-starved) -> InvalidLaunch, nothing persists
    function testTokenCreationFailureRevertsLaunchAtomically() public {
        _deploy();
        _infra(factory);
        bytes32 salt = bytes32(uint256(77));
        vm.expectRevert(V3LaunchFactory.InvalidLaunch.selector);
        factory.launch{gas: 1_500_000}(
            "Meme", "MEME", 0, salt, address(this), V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)), 0
        );
        assertFalse(factory.usedSalt(keccak256(abi.encode(address(this), salt))));
        assertFalse(factory.hasLaunched());
        V3LaunchFactory.Launch memory r = _native(salt); // same salt still usable with enough gas
        assertEq(uint8(r.state), uint8(V3LaunchFactory.State.Locked));
    }

    // ---------------------------------------------------------------- V3LaunchStrategy (lines 43, 77, 88)

    function testStrategyInitializeOnlyFactory() public {
        PoolKey memory key;
        vm.prank(address(0xBAD));
        vm.expectRevert(V3LaunchStrategy.Unauthorized.selector);
        strategy.initialize(key, 1, 0, 0, 0, address(stock), address(locker));
    }

    function testStrategyStockTickBounds() public view {
        // line 77: price so small the target rounds to zero
        try strategy.stockTick(0) returns (int24) {
            revert("zero price accepted");
        } catch (bytes memory err) {
            assertEq(bytes4(err), V3LaunchStrategy.InvalidQuote.selector);
        }
        // line 88 upper arm, inside the narrow window where the target still fits uint256
        uint160 base = TickMath.getSqrtPriceAtTick(123800);
        uint256 x = FullMath.mulDiv(base, base, 1 << 64);
        uint160 hiRoot = TickMath.getSqrtPriceAtTick(887250);
        uint256 price = FullMath.mulDiv(FullMath.mulDiv(hiRoot, hiRoot, 1 << 64), 1e18, x);
        try strategy.stockTick(price) returns (int24) {
            revert("out-of-band price accepted");
        } catch (bytes memory err) {
            assertEq(bytes4(err), V3LaunchStrategy.InvalidQuote.selector);
        }
        // the highest in-band price still returns 887200
        uint160 okRoot = TickMath.getSqrtPriceAtTick(887150);
        assertEq(strategy.stockTick(FullMath.mulDiv(FullMath.mulDiv(okRoot, okRoot, 1 << 64), 1e18, x)), 887200);
        // line 88 lower sub-condition is dead: the smallest nonzero price (1 wei of USD18) maps to ~-290700
        int24 lowest = strategy.stockTick(1);
        assertGt(lowest, -603300);
        assertLt(lowest, -290000);
        int24 t = strategy.stockTick(100 ether);
        assertEq(t, 169900);
        assertEq(t % 100, 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}

    // ---------------------------------------------------------------- V3QuoteFeeHook (lines 45, 103)

    function testHookReceiveOnlyFromPoolManager() public {
        (bool ok, bytes memory err) = address(hook).call{value: 1}("");
        assertFalse(ok);
        assertEq(bytes4(err), bytes4(keccak256("NotPoolManager()")));
        vm.deal(address(manager), 1);
        vm.prank(address(manager));
        (ok,) = address(hook).call{value: 1}("");
        assertTrue(ok);
        assertEq(address(hook).balance, 1);
    }

    function testHookLegacyRegistrationRequiresStockKind() public {
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(stock)), 0, 100, IHooks(address(hook)));
        V3QuoteFeeHook.PoolRegistration memory r = V3QuoteFeeHook.PoolRegistration(
            address(stock), address(0), 0, address(stock).codehash, address(this), address(positions), 1 << 96, bytes32(uint256(1))
        );
        vm.prank(predicted);
        vm.expectRevert(V3QuoteFeeHook.InvalidPoolKey.selector);
        hook.registerLegacyPool(key, r);
        // stock kind passes line 103 and reaches the factory gate in registerPool
        r.quoteKind = 1;
        vm.prank(address(0xBAD));
        vm.expectRevert(V3QuoteFeeHook.NotFactory.selector);
        hook.registerLegacyPool(key, r);
    }
}
