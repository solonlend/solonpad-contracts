// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {DeployV3PayoutHarness} from "./DeployV3Payout.t.sol";
import {VerifyV3} from "../../script/v3/VerifyV3.s.sol";
import {V3LaunchFactory} from "../../src/v3/V3LaunchFactory.sol";
import {V3LaunchValidation} from "../../src/v3/libraries/V3LaunchValidation.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {V3Router} from "../../src/v3/V3Router.sol";
import {SolonStockToken} from "../../src/v3/stock/SolonStockToken.sol";
import {StockFeeConverter} from "../../src/v3/StockFeeConverter.sol";
import {SolonStockSellRoute} from "../../src/v3/stock/SolonStockSellRoute.sol";
import {CapacityController} from "../../src/v3/stock/CapacityController.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {OpsVault} from "../../src/v3/OpsVault.sol";
import {V3StandInToken} from "../../script/v3/V3LocalStandIns.sol";
import {SolonStakingV2} from "../../src/v3/SolonStakingV2.sol";
import {StakingRewardSource} from "../../src/v3/StakingRewardSource.sol";
import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";
import {StockAdapterRegistry} from "../../src/v3/StockAdapterRegistry.sol";

/// @notice r10 fixture audit (PLAN r10 §2): checks that hand-built fixtures never exercised, run on the configuration
///         DeployV3 actually produces (local stand-ins, chain 31337).
contract DeployV3ConfigTest is Test {
    uint256 constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // anvil #0

    /// @dev VerifyV3 on this deployment (pool A seeded, no range yet). Pinned so that any change in the number of
    ///      checks is deliberate: the count depends on the configuration (PLAN r10 §4: 316 vs 317 at 5f81a74 was
    ///      POOL_A_SEED_USD unset vs 3000 -> the "pool A native seed" check is skipped).
    ///      r12: 340 = 329 + M2 library pins (hub send/receive 2, local reserve 2) + L5 payout-choice routes (3) +
    ///      M4 TWAP <=> pool per stock (3) + F11 sell swap router code (1).
    ///      r13: 342 = + hub float pay floor (1) + local reserve float seed (1) (float mode itself is asserted both ways).
    ///      r14: 343 = + Arc route nativeToken == manifest arcUsdc (1); on Arc 5042 also == 0x3600 (+1, not counted here).
    uint256 constant VERIFY_CHECKS = 343;

    DeployV3PayoutHarness h;
    address creator = address(0xC12EA7);
    address holder = address(0x401DE2);
    address whale = address(0x3A1E);

    function setUp() public {
        vm.chainId(31337);
        vm.setEnv("LOCAL_STANDINS", "true");
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_PK)));
        vm.warp(1_790_000_000);
        vm.deal(vm.addr(DEPLOYER_PK), 100_000 ether);
        h = new DeployV3PayoutHarness();
        h.run();
    }

    /// @dev Until r10 VerifyV3 only ran in script/v3/run-local.sh, never in `forge test`.
    function test_verifyV3PassesOnTheDeployedState() public {
        VerifyV3 v = new VerifyV3();
        v.runWith(h.manifest()); // r13: not the process-wide MANIFEST_JSON (DeployV3FloatModeTest runs in parallel)
        assertEq(v.checks() + v.reserveChecks(), VERIFY_CHECKS, "VerifyV3 check count");
    }

    /// @dev Stock-quote coins (design §12.8): the factory approves NVDA.sol only; AAPL.sol / TSLA.sol are reward assets
    ///      without an Arc pool. Fixtures used a stub oracle and underlying 0x1234; here the deployed oracle (Live via
    ///      the stand-in feeds), hub listing and approvedQuote are used.
    function test_stockQuoteLaunchIsNvdaOnly_holderEarnsNvdaDirectly() public {
        (address[] memory stocks, string[] memory tickers) = h.stocks();
        (, address[] memory underlyings) = _underlyings();
        V3LaunchFactory factory = V3LaunchFactory(h.addr("V3LaunchFactory"));
        _desk();
        for (uint256 i = 1; i < stocks.length; ++i) {
            assertEq(factory.approvedQuote(stocks[i]), bytes32(0), "AAPL/TSLA not quotes");
            vm.prank(creator);
            vm.expectRevert(V3LaunchValidation.InvalidQuote.selector);
            factory.launch(
                "X",
                "X",
                0,
                bytes32(i),
                creator,
                V3LaunchFactory.QuoteConfig(1, stocks[i], keccak256(bytes(tickers[i])), underlyings[i]),
                0
            );
        }
        address nvda = stocks[0];
        V3LaunchFactory.QuoteConfig memory q =
            V3LaunchFactory.QuoteConfig(1, nvda, keccak256(bytes(tickers[0])), underlyings[0]);
        assertEq(factory.approvedQuote(nvda), keccak256(abi.encode(q)), "NVDA.sol quote = deployed underlying");
        vm.prank(creator);
        V3LaunchFactory.Launch memory l = factory.launch("StockCat", "STCAT", 0, bytes32("stcat"), creator, q, 0);
        V3RewardToken token = V3RewardToken(payable(l.token));
        assertEq(token.settlementKind(), 1, "direct stock settlement");
        assertEq(token.quote(), nvda);

        // Holder buys first, a whale's later buy pays the holder bucket in NVDA.sol.
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        _buy(token, nvda, holder, 1 ether);
        _buy(token, nvda, whale, 50 ether);
        vm.warp((epoch + 1) * 1 days + 1);
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = epoch;
        address[] memory assets = new address[](1);
        assets[0] = nvda;
        uint256 before = IERC20(nvda).balanceOf(holder);
        vm.prank(holder);
        token.claim(epochs, assets);
        assertGt(IERC20(nvda).balanceOf(holder) - before, 0, "holder paid in NVDA.sol");

        // The NVDA.sol fee converter is bound to the deployed sell route / ops / oracle and the stock layer's run limit
        // (fixtures pinned a $1,000 limit; the deployment follows CapacityController.lRun).
        StockFeeConverter conv = StockFeeConverter(payable(h.addr("StockFeeConverter")));
        assertEq(conv.sellRoute(), h.addr("StockFeeSellRoute"));
        assertEq(conv.ops(), h.addr("OpsVault"));
        assertEq(conv.buyback(), h.addr("BuybackBurnExecutor"));
        assertEq(conv.protocol(), h.addr("ProtocolVault"));
        assertEq(
            SolonStockSellRoute(payable(conv.sellRoute())).runLimit(),
            CapacityController(h.addr("CapacityController")).lRun(),
            "sell route run limit = lRun"
        );
    }

    /// @dev Same bug class as cc6ee75 on the other lanes: an AAPL/TSLA payout coin's staking bucket (5%) must resolve
    ///      to a registered route and seal on the deployed wiring (registerSource via configureRewardModules, payout
    ///      trust, eligibility ids). Finding (PLAN r10): the lane follows the coin's own holder policy
    ///      (StakingRewardSource.resolvePool -> rewardPolicy), i.e. stakers earn AAPL.sol from AAPL coins — PLAN r7 §4
    ///      says staking stays on the platform calendar (NVDA). Pinned here as the code's behaviour.
    function test_stakingLaneOfAaplAndTslaChoiceCoinsSealsOnTheDeployedRoutes() public {
        SolonStakingV2 staking = SolonStakingV2(payable(h.addr("SolonStakingV2")));
        V3StandInToken solon = V3StandInToken(h.addr("standin_SOLON"));
        address staker = address(0x57A6E);
        solon.mint(staker, 1_000_000 ether);
        vm.startPrank(staker);
        solon.approve(address(staking), type(uint256).max);
        staking.stake(1_000_000 ether);
        vm.stopPrank();
        _desk();
        (address[] memory stocks,) = h.stocks();
        RewardRoundManager manager = RewardRoundManager(payable(h.addr("RewardRoundManager")));
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        bytes32[] memory keys = new bytes32[](2);
        address[] memory chosen = new address[](2);
        for (uint256 c = 2; c <= 3; ++c) {
            if (c == 3) OpsVault(payable(h.addr("OpsVault"))).fundBudget{value: 1 ether}(1); // one launch per budget
            V3LaunchFactory factory = V3LaunchFactory(h.addr("V3LaunchFactory"));
            vm.prank(creator);
            V3LaunchFactory.Launch memory l = factory.launch(
                "Lane", "LANE", 0, bytes32(c), creator, V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)), c
            );
            assertEq(V3RewardToken(payable(l.token)).defaultRewardAsset(), stocks[c - 1], "holder payout = choice");
            PoolKey memory key = PoolKey(
                Currency.wrap(address(0)), Currency.wrap(l.token), 0, 100, IHooks(h.addr("V3QuoteFeeHook"))
            );
            V3Router router = V3Router(payable(h.addr("V3Router")));
            vm.deal(whale, 3_000 ether);
            vm.prank(whale);
            router.swap{value: 3_000 ether}(
                V3Router.SwapRequest(key, true, -3_000 ether, 0, 1, 3_000 ether, whale, block.timestamp)
            );
            keys[c - 2] = staking.poolLane(l.poolId);
            chosen[c - 2] = stocks[c - 1];
            assertTrue(keys[c - 2] != bytes32(0), "staking lane registered on the first fee");
        }
        vm.warp((epoch + 1) * 1 days + 15 minutes);
        for (uint256 i; i < keys.length; ++i) {
            address asset = staking.sourceAsset(keys[i], epoch);
            assertEq(asset, chosen[i], "staking 5% follows the coin's payout choice");
            StakingRewardSource src = StakingRewardSource(payable(staking.createEntrySource(keys[i])));
            (bytes32 assetId, uint32 version, bytes32 policy, uint8 mode) = src.rewardPolicy(epoch, 0);
            StockAdapterRegistry.Route memory route =
                StockAdapterRegistry(h.addr("StockAdapterRegistry")).resolve(assetId, version);
            assertEq(route.asset, asset, "registered route for the lane asset");
            uint256 entryId = manager.seal(address(src), epoch, 0, assetId, version, policy, mode);
            assertGt(manager.entry(entryId).budget18, 0, "staking budget sealed");
        }
    }

    function _underlyings() internal view returns (address[] memory t, address[] memory u) {
        (t,) = h.stocks();
        u = new address[](t.length);
        for (uint256 i; i < t.length; ++i) {
            u[i] = SolonStockToken(t[i]).underlying();
        }
    }

    function _desk() internal {
        DeskNFT desk = DeskNFT(payable(h.addr("DeskNFT")));
        V3StandInToken solon = V3StandInToken(h.addr("standin_SOLON"));
        vm.deal(creator, 10_000 ether);
        vm.startPrank(creator);
        solon.mint(creator, 100_000 ether);
        solon.approve(address(desk), type(uint256).max);
        desk.mint{value: desk.surchargeUSDC18()}(1, creator);
        OpsVault(payable(h.addr("OpsVault"))).fundBudget{value: 1 ether}(1);
        vm.stopPrank();
    }

    function _buy(V3RewardToken token, address stock, address who, uint256 amount) internal {
        bool quote0 = stock < address(token);
        PoolKey memory key = PoolKey(
            Currency.wrap(quote0 ? stock : address(token)),
            Currency.wrap(quote0 ? address(token) : stock),
            0,
            100,
            IHooks(h.addr("V3QuoteFeeHook"))
        );
        V3Router router = V3Router(payable(h.addr("V3Router")));
        vm.prank(h.addr("SolonStockHub"));
        SolonStockToken(stock).mint(who, amount);
        vm.startPrank(who);
        IERC20(stock).approve(address(router), amount);
        router.swap(V3Router.SwapRequest(key, true, -int256(amount), 0, 1, amount, who, block.timestamp));
        vm.stopPrank();
        assertGt(token.balanceOf(who), 0);
    }
}
