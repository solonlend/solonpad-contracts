// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {V3LaunchValidation} from "./libraries/V3LaunchValidation.sol";
import {V3LegacyPools} from "./libraries/V3LegacyPools.sol";
import {V3RewardWiring} from "./libraries/V3RewardWiring.sol";
import {V3TokenCodeStore} from "./V3TokenCodeStore.sol";
import {V3RewardToken} from "./V3RewardToken.sol";
import {V3FeeLedger} from "./V3FeeLedger.sol";
import {V3QuoteFeeHook} from "./V3QuoteFeeHook.sol";
import {V3LaunchStrategy} from "./V3LaunchStrategy.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IV3PhaseThreePayout {
    function controller() external view returns (address);
}

interface IV3PhaseThreeRounds {
    function payout() external view returns (address);
}

interface IV3StockFeeCustodian {
    function ledger() external view returns (address);
    function buyback() external view returns (address);
    function protocol() external view returns (address);
    function feeCustodyMode() external view returns (uint8);
}

interface IV3LaunchLocker {
    function registerPosition(bytes32, uint256, address) external;
}

interface IV3CreatorRights {
    function mint(bytes32, address) external returns (uint256);
    function factory() external view returns (address);
    function ledger() external view returns (address);
}

interface IV3LaunchBoundLocker {
    function factory() external view returns (address);
    function positionManager() external view returns (address);
}

interface IV3LaunchReadiness {
    function paidDeskCount() external view returns (uint256);
    function opsAvailable() external view returns (uint256);
}

interface IV3LaunchStockStatus {
    function stockState(address asset)
        external
        view
        returns (bool marketOpen, bool transferable, uint256 multiplierVersion);
}

/// @notice Atomic fixed-supply launches into the registered zero-core-fee v4 pool.
/// @dev Components, stock admissions and system exclusions are constructor-only.
/// Stock status and paid-Desk/Ops readiness are fixed external policy boundaries;
/// production deployment must wire the actual later-phase modules, not test stubs.
/// CREATE2 salt is creator-scoped; token initcode includes name/symbol and the
/// constructor-configured exclusions. Offchain initial-price signers must derive
/// that exact address, as demonstrated by the real-periphery launch tests.
contract V3LaunchFactory is ReentrancyGuard {
    address public immutable tokenCodePart1;
    address public immutable tokenCodePart2;

    function _tokenCreationCode() internal view returns (bytes memory code) {
        address first = tokenCodePart1;
        address second = tokenCodePart2;
        uint256 firstSize = first.code.length - 1;
        uint256 secondSize = second.code.length - 1;
        code = new bytes(firstSize + secondSize);
        assembly ("memory-safe") {
            extcodecopy(first, add(code, 32), 1, firstSize)
            extcodecopy(second, add(add(code, 32), firstSize), 1, secondSize)
        }
    }

    function _deployToken(
        bytes32 salt,
        string calldata name,
        string calldata symbol,
        address strategy,
        address ledger,
        address[] memory excluded
    ) internal returns (V3RewardToken token) {
        bytes memory init = abi.encodePacked(_tokenCreationCode(), abi.encode(name, symbol, strategy, ledger, excluded));
        address deployed;
        assembly ("memory-safe") { deployed := create2(0, add(init, 32), mload(init), salt) }
        if (deployed == address(0)) revert InvalidLaunch();
        token = V3RewardToken(payable(deployed));
    }

    struct Components {
        V3FeeLedger ledger;
        V3QuoteFeeHook hook;
        V3LaunchStrategy strategy;
        IPositionManager positions;
        address locker;
        address rights;
        address defaultRewardAsset;
        address[4] modules;
        address priceOracle; // SolonStockOracle (r7); required when stock quotes are approved
        address stockStatus;
        address readiness;
        address[] systemCustodians;
    }

    V3RewardWiring.Infrastructure public rewardInfrastructure;
    address public immutable infrastructureConfigurator;
    bool public hasLaunched;
    address public stockFeeConverter;
    event StockFeeConverterConfigured(address indexed converter);

    /// @notice Stock operating fees require conversion before reaching the native-only vaults.
    /// Fixed before the first launch and included in every subsequent token's immutable exclusions.
    function configureStockFeeConverter(address converter) external {
        if (
            msg.sender != infrastructureConfigurator || hasLaunched || stockFeeConverter != address(0)
                || converter.code.length == 0
        ) revert InvalidLaunch();
        IV3StockFeeCustodian receiver = IV3StockFeeCustodian(converter);
        if (
            receiver.feeCustodyMode() != 2 || receiver.ledger() != address(components.ledger)
                || receiver.buyback() != components.modules[2] || receiver.protocol() != components.modules[3]
        ) revert InvalidLaunch();
        stockFeeConverter = converter;
        emit StockFeeConverterConfigured(converter);
    }

    /// @notice Deployment-time binding; cannot retrofit or change already launched rights.
    function configureRewardInfrastructure(
        address controller,
        address payout,
        address rounds,
        bytes32 assetId,
        uint32 version,
        bytes32 pricePolicy
    ) external {
        if (
            msg.sender != infrastructureConfigurator || hasLaunched || rewardInfrastructure.controller != address(0)
                || controller.code.length == 0 || payout.code.length == 0 || rounds.code.length == 0 || assetId == 0
                || version == 0 || pricePolicy == 0
        ) revert InvalidLaunch();
        if (IV3PhaseThreePayout(payout).controller() != controller || IV3PhaseThreeRounds(rounds).payout() != payout) {
            revert InvalidLaunch();
        }
        rewardInfrastructure = V3RewardWiring.Infrastructure(controller, payout, rounds, assetId, version, pricePolicy);
    }

    V3LegacyPools.State private legacyPools;

    function whitelistLegacyToken(address token) external {
        V3LegacyPools.whitelist(legacyPools, rewardInfrastructure.controller, token);
    }

    function scheduleLegacyPool(bytes32 action) external {
        V3LegacyPools.schedule(legacyPools, rewardInfrastructure.controller, action);
    }

    /// @notice Register the existing SOLON supply without minting or launching a new token.
    /// holderSink is the fixed staking module; creator rights belong to protocol governance.
    function registerLegacyPool(address token, address quote, address holderSink, address creatorRights, uint160 price)
        external
        nonReentrant
        returns (bytes32 pool)
    {
        if (approvedQuote[quote] == 0) revert InvalidQuote();
        hasLaunched = true;
        return V3LegacyPools.register(
            legacyPools,
            components,
            rewardInfrastructure.controller,
            stockFeeConverter,
            V3LegacyPools.Request(token, quote, holderSink, creatorRights, price),
            keccak256(msg.data)
        );
    }

    address public assetSchedule;
    /// @notice r7: creator-chosen payout stock (LaunchPayoutChoice); fixed before the first launch.
    address public payoutChoice;
    event LaunchPayoutChosen(bytes32 indexed poolId, address indexed token, uint256 indexed choiceId, address asset);

    function configurePayoutChoice(address registry) external {
        if (
            msg.sender != infrastructureConfigurator || hasLaunched || payoutChoice != address(0)
                || registry.code.length == 0
        ) revert InvalidLaunch();
        payoutChoice = registry;
    }

    function configureAssetSchedule(address schedule) external {
        if (
            msg.sender != infrastructureConfigurator || rewardInfrastructure.controller != address(0)
                || assetSchedule != address(0) || schedule.code.length == 0
        ) revert InvalidLaunch();
        assetSchedule = schedule;
    }
    V3RewardWiring.EpochPolicy[] public epochPolicies;

    function declareRewardEpoch(uint256 epoch, address asset, bytes32 assetId, uint32 version, bytes32 pricePolicy)
        external
    {
        if (
            msg.sender != infrastructureConfigurator || rewardInfrastructure.controller != address(0)
                || epoch < block.timestamp / 1 days || asset.code.length == 0 || assetId == 0 || version == 0
                || pricePolicy == 0 || epochPolicies.length >= 64
        ) revert InvalidLaunch();
        for (uint256 i; i < epochPolicies.length; i++) {
            if (epochPolicies[i].epoch == epoch) revert InvalidLaunch();
        }
        epochPolicies.push(V3RewardWiring.EpochPolicy(epoch, asset, assetId, version, pricePolicy));
    }

    struct QuoteConfig {
        uint8 kind;
        address asset;
        bytes32 assetId;
        address underlying;
    }

    enum State {
        None,
        Registered,
        Initialized,
        Locked
    }

    struct Launch {
        address token;
        bytes32 poolId;
        uint256 positionId;
        int24 initialTick;
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint256 dust;
        State state;
        bytes32 metadataHash;
    }
    error InvalidLaunch();
    mapping(bytes32 => bool) public usedSalt;
    Components internal components;
    mapping(bytes32 => Launch) public launches;
    mapping(address => bytes32) public approvedQuote;
    error InvalidQuote();
    event LaunchState(bytes32 indexed poolId, address indexed token, State state);

    constructor(Components memory c, QuoteConfig[] memory quotes) {
        infrastructureConfigurator = msg.sender;
        bytes memory tokenCode = type(V3RewardToken).creationCode;
        uint256 firstSize = tokenCode.length > 20000 ? 20000 : tokenCode.length;
        tokenCodePart1 = address(new V3TokenCodeStore(tokenCode, 0, firstSize));
        tokenCodePart2 = address(new V3TokenCodeStore(tokenCode, firstSize, tokenCode.length - firstSize));
        if (
            address(c.ledger).code.length == 0 || address(c.hook).code.length == 0
                || address(c.strategy).code.length == 0 || address(c.positions).code.length == 0
                || c.locker.code.length == 0 || c.rights.code.length == 0 || c.defaultRewardAsset.code.length == 0
                || c.readiness.code.length == 0
        ) revert InvalidLaunch();
        if (
            c.ledger.factory() != address(this) || c.hook.factory() != address(this)
                || address(c.hook.ledger()) != address(c.ledger)
                || address(c.hook.poolManager()) != address(c.positions.poolManager())
                || c.strategy.factory() != address(this)
                || address(c.strategy.positionManager()) != address(c.positions)
                || IV3LaunchBoundLocker(c.locker).factory() != address(this)
                || IV3LaunchBoundLocker(c.locker).positionManager() != address(c.positions)
                || IV3CreatorRights(c.rights).factory() != address(this)
                || IV3CreatorRights(c.rights).ledger() != address(c.ledger)
        ) revert InvalidLaunch();
        if (quotes.length != 0 && (c.priceOracle.code.length == 0 || c.stockStatus.code.length == 0)) {
            revert InvalidQuote();
        }
        for (uint256 i; i < 4; i++) {
            if (c.modules[i].code.length == 0) revert InvalidLaunch();
        }
        for (uint256 i; i < c.systemCustodians.length; i++) {
            if (c.systemCustodians[i] == address(0)) revert InvalidLaunch();
        }
        components = c;
        for (uint256 i; i < quotes.length; i++) {
            QuoteConfig memory q = quotes[i];
            if (
                q.kind != 1 || q.asset.code.length == 0 || q.assetId == 0 || q.underlying == address(0)
                    || IERC20Metadata(q.asset).decimals() != 18 || approvedQuote[q.asset] != 0
                    || q.asset == c.ledger.nativeUsdcView()
            ) revert InvalidQuote();
            approvedQuote[q.asset] = keccak256(abi.encode(q));
        }
    }

    /// @dev Weight-excluded system accounts for a new token; split out of `launch` only to keep
    ///      `forge coverage --ir-minimum` within the stack limit (no behaviour change).
    function _excludedAccounts(Components memory c) private view returns (address[] memory excluded) {
        excluded =
            new address[](10 + c.systemCustodians.length + (stockFeeConverter == address(0) ? 0 : 1));
        excluded[0] = address(c.positions.poolManager());
        excluded[1] = address(c.positions);
        excluded[2] = address(c.hook);
        excluded[3] = c.locker;
        excluded[4] = c.rights;
        excluded[5] = address(this);
        for (uint256 i; i < 4; i++) {
            excluded[6 + i] = c.modules[i];
        }
        for (uint256 i; i < c.systemCustodians.length; i++) {
            excluded[10 + i] = c.systemCustodians[i];
        }
        if (stockFeeConverter != address(0)) excluded[10 + c.systemCustodians.length] = stockFeeConverter;
    }

    function launch(
        string calldata name,
        string calldata symbol,
        bytes32 metadataHash,
        bytes32 salt,
        address creator,
        QuoteConfig calldata q,
        uint256 payoutChoiceId
    ) external nonReentrant returns (Launch memory r) {
        if (msg.sender != creator || creator == address(0)) revert InvalidLaunch();
        if (rewardInfrastructure.controller == address(0)) revert InvalidLaunch();
        hasLaunched = true;
        bytes32 scopedSalt = keccak256(abi.encode(creator, salt));
        if (usedSalt[scopedSalt]) revert InvalidLaunch();
        usedSalt[scopedSalt] = true;
        Components memory c = components;
        if (IV3LaunchReadiness(c.readiness).paidDeskCount() == 0 || IV3LaunchReadiness(c.readiness).opsAvailable() == 0)
        {
            revert InvalidLaunch();
        }
        address[] memory excluded = _excludedAccounts(c);
        V3RewardToken token = _deployToken(scopedSalt, name, symbol, address(c.strategy), address(c.ledger), excluded);
        r.token = address(token);
        uint256 openPrice = V3LaunchValidation.validateQuote(approvedQuote, c.priceOracle, c.stockStatus, q);
        r.metadataHash = metadataHash;
        r.initialTick = 123800;
        r.lower = -160100;
        r.upper = 123800;
        bool quote0 = q.asset < r.token;
        if (q.kind == 1) {
            int24 qt = c.strategy.stockTick(openPrice);
            r.initialTick = quote0 ? qt : -qt;
            r.lower = quote0 ? r.initialTick - 283900 : r.initialTick;
            r.upper = quote0 ? r.initialTick : r.initialTick + 283900;
        }
        PoolKey memory key = PoolKey(
            Currency.wrap(quote0 ? q.asset : r.token),
            Currency.wrap(quote0 ? r.token : q.asset),
            0,
            100,
            IHooks(address(c.hook))
        );
        r.poolId = PoolId.unwrap(key.toId());
        r.positionId = c.positions.nextTokenId();
        uint160 price = TickMath.getSqrtPriceAtTick(r.initialTick);
        r.liquidity = quote0
            ? LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(r.lower), price, 1e27)
            : LiquidityAmounts.getLiquidityForAmount0(price, TickMath.getSqrtPriceAtTick(r.upper), 1e27);
        V3RewardWiring.wireLaunch(
            r.token,
            r.poolId,
            q.asset,
            q.kind,
            V3RewardWiring.Defaults(c.defaultRewardAsset, payoutChoice, payoutChoiceId),
            rewardInfrastructure,
            assetSchedule,
            epochPolicies
        );
        address[6] memory beneficiaries = [r.token, c.rights, c.modules[0], c.modules[1], c.modules[2], c.modules[3]];
        if (q.kind == 1 && stockFeeConverter != address(0)) {
            beneficiaries[4] = stockFeeConverter;
            beneficiaries[5] = stockFeeConverter;
        }
        c.ledger.registerPool(r.poolId, q.asset, q.kind, address(c.hook), beneficiaries);
        c.hook
            .registerPool(
                key,
                V3QuoteFeeHook.PoolRegistration(
                    r.token,
                    q.asset,
                    q.kind,
                    r.token.codehash,
                    address(c.strategy),
                    address(c.positions),
                    price,
                    keccak256(
                        abi.encode(
                            ModifyLiquidityParams(r.lower, r.upper, int256(uint256(r.liquidity)), bytes32(r.positionId))
                        )
                    )
                )
            );
        // Registration is split across two contracts; verify the same immutable
        // asset, hook and payout modules before any liquidity or rights are issued.
        V3FeeLedger.Pool memory registered = c.ledger.poolInfo(r.poolId);
        if (
            registered.quote != q.asset || registered.settlementKind != q.kind || registered.hook != address(c.hook)
                || keccak256(abi.encode(registered.beneficiaries)) != keccak256(abi.encode(beneficiaries))
        ) {
            revert InvalidLaunch();
        }
        IV3LaunchLocker(c.locker).registerPosition(r.poolId, r.positionId, address(c.strategy));
        IV3CreatorRights(c.rights).mint(r.poolId, creator);
        r.state = State.Registered;
        emit LaunchState(r.poolId, r.token, r.state);
        r.dust = c.strategy.initialize(key, price, r.lower, r.upper, r.liquidity, r.token, c.locker);
        r.state = State.Initialized;
        emit LaunchState(r.poolId, r.token, r.state);
        r.state = State.Locked;
        launches[r.poolId] = r;
        emit LaunchState(r.poolId, r.token, r.state);
    }
}
