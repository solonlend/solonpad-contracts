// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Origin} from "../../src/v3/stock/lz/OApp.sol";
import {DeployV3} from "../../script/v3/DeployV3.s.sol";
import {MockLzEndpoint} from "./helpers/StockMocks.sol";
import {V3LaunchFactory} from "../../src/v3/V3LaunchFactory.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {V3Router} from "../../src/v3/V3Router.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {LaunchPayoutChoice} from "../../src/v3/LaunchPayoutChoice.sol";
import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";
import {RewardBatcher} from "../../src/v3/RewardBatcher.sol";
import {RewardDistributor} from "../../src/v3/RewardDistributor.sol";
import {StockAdapterRegistry} from "../../src/v3/StockAdapterRegistry.sol";
import {SolonStockAdapter} from "../../src/v3/adapters/SolonStockAdapter.sol";
import {SolonStockHub} from "../../src/v3/stock/SolonStockHub.sol";
import {HubSettlement} from "../../src/v3/stock/HubSettlement.sol";
import {OrderScheduler} from "../../src/v3/stock/OrderScheduler.sol";
import {RelayFundingRoute} from "../../src/v3/stock/RelayFundingRoute.sol";
import {ArcUsdcViewStub} from "./helpers/ArcUsdcViewStub.sol";
import {RelayDepositoryV2Stub} from "./StockRoutes.t.sol";
import {Messages} from "../../src/v3/stock/libs/Messages.sol";
import {SolonStockOracle} from "../../src/v3/oracle/SolonStockOracle.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {OpsVault} from "../../src/v3/OpsVault.sol";
import {V3StandInToken} from "../../script/v3/V3LocalStandIns.sol";

/// @dev DeployV3 itself, local stand-ins (chainId 31337). Pool A is pinned to the script's r9 defaults instead of
///      the POOL_A_* env vars, which DeployV3PoolATest mutates process-wide while tests run in parallel.
contract DeployV3PayoutHarness is DeployV3 {
    function _loadPoolAConfig() internal override {
        (cfg.poolAPoolUsd, cfg.poolAStockUsd, cfg.poolAReserveUsd, cfg.poolASeedStockRaw) = (1000, 1000, 1000, 0);
        cfg.poolASeedUsd = 3000;
    }

    function addr(string memory name) external view returns (address a) {
        a = deployed[name];
        require(a != address(0), name);
    }

    function stocks() external view returns (address[] memory t, string[] memory tickers) {
        t = new address[](1 + cfg.extraTokens.length);
        tickers = new string[](t.length);
        (t[0], tickers[0]) = (cfg.rewardAsset, cfg.stockTicker);
        for (uint256 i; i < cfg.extraTokens.length; ++i) {
            (t[i + 1], tickers[i + 1]) = (cfg.extraTokens[i], cfg.extraTickers[i]);
        }
    }

    function manifest() external view returns (string memory) {
        return manifestJson;
    }

    function reward() external view returns (uint32 version, bytes32 policy) {
        return (cfg.rewardVersion, cfg.rewardPricePolicy);
    }
}

/// @notice The configuration DeployV3 actually produces, end to end: a creator launches a native-USDC coin with
///         payout choice 1 (NVDA), 2 (AAPL) or 3 (TSLA); a holder earns from a later buy's fee; the reward round
///         seals, buys the chosen stock through the real adapter -> hub -> Relay route, and the holder claims it.
///         Earlier tests used hand-built fixtures (AAPL bound by the test itself), so the missing AAPL/TSLA
///         `EligibilityController.bindAsset` in DeployV3 ("unbound eligibility asset" at launch) went unnoticed.
///         [SIM] like script/v3/e2e-pool-a-local.sh: no Robinhood Chain and no LayerZero locally, so the Arc
///         endpoint stand-in is replaced by a recording mock and the RH vault's BuyFilled is delivered by the
///         endpoint into the hub's lzReceive. Everything on Arc is the deployed code with the deployed wiring.
contract DeployV3PayoutTest is Test {
    uint256 constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // anvil #0
    uint256 constant SIGNER_PK = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba; // anvil #5

    DeployV3PayoutHarness h;
    address creator = address(0xC12EA7);
    address holder = address(0x401DE2);
    address whale = address(0x3A1E);

    function setUp() public {
        vm.chainId(31337);
        vm.setEnv("LOCAL_STANDINS", "true");
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_PK)));
        vm.warp(1_790_000_000); // a fixed weekday morning (UTC), well past genesis
        vm.deal(vm.addr(DEPLOYER_PK), 100_000 ether);
        h = new DeployV3PayoutHarness();
        h.run();
        assertEq(vm.addr(SIGNER_PK), RelayFundingRoute(h.addr("RelayFundingRoute")).signer(), "local signer");
    }

    /// @dev [SIM] the local LayerZero stand-in reverts every send; record packets instead (after any VerifyV3 run,
    ///      which checks the deployed code hashes).
    function _recordLzPackets() internal {
        vm.etch(h.addr("local_ArcLzEndpoint"), address(new MockLzEndpoint(30417)).code);
    }

    function test_choice1Nvda() public {
        _payout(1);
    }

    function test_choice2Aapl() public {
        _payout(2);
    }

    function test_choice3Tsla() public {
        _payout(3);
    }

    function _payout(uint256 choiceId) internal {
        _recordLzPackets();
        (address[] memory stocks, string[] memory tickers) = h.stocks();
        address asset = stocks[choiceId - 1];
        bytes32 assetId = keccak256(bytes(tickers[choiceId - 1]));
        LaunchPayoutChoice.Choice memory c = LaunchPayoutChoice(h.addr("LaunchPayoutChoice")).choice(choiceId);
        assertEq(c.asset, asset, "choice order = hub listing order");
        assertEq(c.assetId, assetId);

        // Before cc6ee75 this reverted "unbound eligibility asset" for choices 2/3 (DeployV3 bound only NVDA.sol).
        V3RewardToken token = _launch(choiceId);
        assertEq(
            EligibilityController(h.addr("EligibilityController")).assetIds(asset),
            uint16(choiceId), // stored as id + 1; ids follow the hub listing order
            "eligibility id = listing index"
        );
        assertEq(token.defaultRewardAsset(), asset);
        uint256 epoch = vm.getBlockTimestamp() / 1 days; // not block.timestamp: via-IR re-reads it after the warp
        _trade(token);

        // Next UTC day: seal the holders' budget, batch it, buy the stock through the deployed route.
        vm.warp((epoch + 1) * 1 days + 15 minutes);
        (uint32 version, bytes32 policy) = h.reward();
        RewardRoundManager manager = RewardRoundManager(payable(h.addr("RewardRoundManager")));
        uint256 entryId = manager.seal(address(token), epoch, 0, assetId, version, policy, 0);
        uint256 budget = manager.entry(entryId).budget18;
        assertGe(budget, 100 ether, "holder bucket above the round minimum");
        uint256 roundId = _startRound(manager, entryId, asset, budget);
        RewardRoundManager.Round memory r = manager.round(roundId);
        assertEq(r.asset, asset);

        SolonStockHub hub = SolonStockHub(payable(h.addr("SolonStockHub")));
        uint256 hubId = hub.orderCount() - 1;
        _launchFunding(hub, hubId);
        manager.poke(roundId);
        manager.submit(roundId);
        uint256 raw = r.minRawOut + 1;
        _fill(hub, hubId, raw);
        manager.finalize(roundId, "");
        assertEq(uint8(manager.round(roundId).status), uint8(RewardRoundManager.Status.Settled));

        // The holder claims the chosen stock. Round-settled coins pay through the RewardVault, whose allocation id is
        // the sealed entry id (the token's own claim is closed once a rounds manager is bound).
        uint256[] memory ids = new uint256[](1);
        ids[0] = entryId;
        address[] memory assets = new address[](1);
        assets[0] = asset;
        RewardDistributor distributor = RewardDistributor(h.addr("RewardDistributor"));
        address vault = address(manager.vault());
        vm.prank(holder);
        distributor.claim(vault, ids, assets);
        uint256 paid = IERC20(asset).balanceOf(holder);
        assertGt(paid, 0, "holder paid in the chosen stock");
        assertLe(paid, raw);
        for (uint256 i; i < stocks.length; ++i) {
            if (stocks[i] != asset) assertEq(IERC20(stocks[i]).balanceOf(holder), 0, "no other stock");
        }
    }

    function _launch(uint256 choiceId) internal returns (V3RewardToken) {
        DeskNFT desk = DeskNFT(payable(h.addr("DeskNFT")));
        OpsVault ops = OpsVault(payable(h.addr("OpsVault")));
        V3StandInToken solon = V3StandInToken(h.addr("standin_SOLON"));
        vm.deal(creator, 10_000 ether);
        vm.startPrank(creator);
        solon.mint(creator, 100_000 ether);
        solon.approve(address(desk), type(uint256).max);
        if (ops.paidDeskCount() == 0) desk.mint{value: desk.surchargeUSDC18()}(1, creator);
        ops.fundBudget{value: 1 ether}(1);
        V3LaunchFactory.Launch memory l = V3LaunchFactory(h.addr("V3LaunchFactory")).launch(
            "Payout", "PAY", 0, bytes32(choiceId), creator, V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)), choiceId
        );
        vm.stopPrank();
        return V3RewardToken(payable(l.token));
    }

    /// @dev The holder buys first; a later $30k buy's 1% fee pays the holder bucket (57.5% = $172.5).
    function _trade(V3RewardToken token) internal {
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 0, 100, IHooks(h.addr("V3QuoteFeeHook")));
        V3Router router = V3Router(payable(h.addr("V3Router")));
        vm.deal(holder, 100 ether);
        vm.prank(holder);
        router.swap{value: 100 ether}(
            V3Router.SwapRequest(key, true, -100 ether, 0, 1, 100 ether, holder, block.timestamp)
        );
        vm.deal(whale, 30_000 ether);
        vm.prank(whale);
        router.swap{value: 30_000 ether}(
            V3Router.SwapRequest(key, true, -30_000 ether, 0, 1, 30_000 ether, whale, block.timestamp)
        );
        assertGt(token.balanceOf(holder), 0);
    }

    function _startRound(RewardRoundManager manager, uint256 entryId, address asset, uint256 budget)
        internal
        returns (uint256 roundId)
    {
        RewardBatcher batcher = RewardBatcher(h.addr("RewardBatcher"));
        batcher.enqueue(entryId);
        uint256 minRaw = SolonStockOracle(h.addr("SolonStockOracle")).rawFor(asset, budget);
        uint256 deadline = block.timestamp + 1 hours;
        uint256[] memory ids = new uint256[](1);
        ids[0] = entryId;
        // The keeper signs the adapter quote for the order id reserveBatch will derive (RewardRoundManager).
        bytes32 entriesHash = keccak256(abi.encode(bytes32(0), manager.entry(entryId), budget));
        bytes32 orderId = keccak256(
            abi.encode(block.chainid, address(manager), entriesHash, minRaw, deadline, manager.executionNonce(entriesHash))
        );
        StockAdapterRegistry.Route memory route =
            StockAdapterRegistry(h.addr("StockAdapterRegistry")).resolve(manager.entry(entryId).assetId, manager.entry(entryId).adapterVersion);
        assertEq(route.asset, asset, "registered route for the chosen stock");
        SolonStockAdapter adapter = SolonStockAdapter(payable(route.adapter));
        // r12 (F4): fixedCost18 = external cost (Relay + LZ) <= budget/200; fees18 = hub 25 bps + that external cost.
        uint256 external18 = budget / 200;
        uint256 fees = (budget * 25) / 10_000 + external18;
        adapter.depositFees{value: fees}(orderId);
        SolonStockAdapter.SignedQuote memory q =
            SolonStockAdapter.SignedQuote(orderId, budget, minRaw, deadline, uint256(orderId), fees, external18);
        (uint8 v, bytes32 rs, bytes32 ss) = vm.sign(SIGNER_PK, adapter.quoteDigest(q));
        roundId = batcher.executeAndStart(ids, budget, minRaw, deadline, abi.encode(q, abi.encodePacked(rs, ss, v)));
        assertEq(manager.round(roundId).orderId, orderId);
    }

    /// @dev The scheduler launches the reward order over the fixed Relay route with a signed funding quote.
    function _launchFunding(SolonStockHub hub, uint256 hubId) internal {
        RelayFundingRoute route = RelayFundingRoute(h.addr("RelayFundingRoute"));
        // [SIM] r14: the route deposits Arc USDC through its 0x3600 ERC-20 view into the Relay depository; the local
        // config only has placeholder addresses there, so install behaviour-identical stubs at those addresses.
        vm.etch(route.nativeToken(), address(new ArcUsdcViewStub()).code);
        vm.etch(route.depository(), address(new RelayDepositoryV2Stub()).code);
        uint256 amountIn = hub.getOrder(hubId).amountIn;
        uint256 routeFee = 0.3 ether;
        RelayFundingRoute.Quote memory q =
            RelayFundingRoute.Quote(keccak256(abi.encode("relay", hubId)), block.timestamp + 1 hours, hubId + 1);
        (uint8 v, bytes32 rs, bytes32 ss) =
            vm.sign(SIGNER_PK, route.quoteDigest(bytes32(hubId), amountIn, routeFee, amountIn / 1e12, q));
        OrderScheduler(h.addr("OrderScheduler")).launchNext(
            hubId, abi.encode(routeFee, abi.encode(q, abi.encodePacked(rs, ss, v)))
        );
    }

    /// @dev [SIM] the RH vault's BuyFilled for the order, delivered by the Arc endpoint.
    function _fill(SolonStockHub hub, uint256 hubId, uint256 raw) internal {
        address ep = h.addr("local_ArcLzEndpoint");
        assertGt(MockLzEndpoint(payable(ep)).packetCount(), 0, "order sent to the RH vault");
        HubSettlement.Order memory o = hub.getOrder(hubId);
        bytes memory message = abi.encode(
            uint8(2),
            Messages.Result(bytes32(hubId), o.underlying, Messages.Outcome.Bought, uint128(o.amountIn / 1e12), uint128(raw), 1)
        );
        Origin memory origin = Origin(30416, bytes32(uint256(uint160(h.addr("ReserveVault")))), 1);
        vm.prank(ep);
        hub.lzReceive(origin, bytes32(hubId), message, address(0), "");
    }
}
