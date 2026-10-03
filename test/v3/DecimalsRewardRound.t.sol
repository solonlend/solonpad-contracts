// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Origin} from "../../src/v3/stock/lz/OApp.sol";
import {MockLzEndpoint} from "./helpers/StockMocks.sol";
import {V3LaunchFactory} from "../../src/v3/V3LaunchFactory.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {V3Router} from "../../src/v3/V3Router.sol";
import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";
import {RewardBatcher} from "../../src/v3/RewardBatcher.sol";
import {StockAdapterRegistry} from "../../src/v3/StockAdapterRegistry.sol";
import {SolonStockAdapter} from "../../src/v3/adapters/SolonStockAdapter.sol";
import {SolonStockHub} from "../../src/v3/stock/SolonStockHub.sol";
import {HubSettlement} from "../../src/v3/stock/HubSettlement.sol";
import {OrderScheduler} from "../../src/v3/stock/OrderScheduler.sol";
import {RelayFundingRoute} from "../../src/v3/stock/RelayFundingRoute.sol";
import {Messages} from "../../src/v3/stock/libs/Messages.sol";
import {SolonStockOracle} from "../../src/v3/oracle/SolonStockOracle.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {OpsVault} from "../../src/v3/OpsVault.sol";
import {V3StandInToken} from "../../script/v3/V3LocalStandIns.sol";
import {DeployV3PayoutHarness} from "./DeployV3Payout.t.sol";
import {ArcUsdcViewStub} from "./helpers/ArcUsdcViewStub.sol";
import {RelayDepositoryV2Stub} from "./StockRoutes.t.sol";

/// @notice Decimals fix H2 (docs/PLAN-v3-contracts.md "位数修复"): a holder budget sealed off the 6-dp grid
///         (any wei) goes through the deployed batcher -> manager -> adapter -> hub. Before the fix the batch total
///         was handed over unaligned and HubSettlement.beginReward rejected it (BadRewardOrder) for every caller
///         of the permissionless executeAndStart, not only the keeper. Now the batcher trims the sub-1e12 tail,
///         the hub accepts, the round settles, and the tail stays available in the entry.
contract DecimalsRewardRoundTest is Test {
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
        vm.warp(1_790_000_000);
        vm.deal(vm.addr(DEPLOYER_PK), 100_000 ether);
        h = new DeployV3PayoutHarness();
        h.run();
        vm.etch(h.addr("local_ArcLzEndpoint"), address(new MockLzEndpoint(30417)).code);
    }

    function test_unalignedSealedBudgetStartsAndSettles() public {
        (address[] memory stocks,) = h.stocks();
        address asset = stocks[0];
        V3RewardToken token = _launch();
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        // 30,000.000000123456789123 USDC: the holder bucket of its fee lands off the 6-dp grid.
        _trade(token, 30_000 ether + 123_456_789_123);

        vm.warp((epoch + 1) * 1 days + 15 minutes);
        (uint32 version, bytes32 policy) = h.reward();
        RewardRoundManager manager = RewardRoundManager(payable(h.addr("RewardRoundManager")));
        uint256 entryId = manager.seal(address(token), epoch, 0, keccak256(bytes("NVDA")), version, policy, 0);
        uint256 sealed18 = manager.entry(entryId).budget18;
        assertGt(sealed18 % 1e12, 0, "fixture: sealed budget is off the 6-dp grid");
        uint256 budget = _previewTotal(manager, entryId, sealed18);
        assertEq(budget, sealed18 - (sealed18 % 1e12), "batcher hands over the aligned total");

        uint256 roundId = _startRound(manager, entryId, asset, sealed18, budget);
        assertEq(manager.round(roundId).budget18, budget, "round budget on the 6-dp grid");
        assertEq(manager.available(entryId), sealed18 % 1e12, "sub-1e12 tail stays available");

        SolonStockHub hub = SolonStockHub(payable(h.addr("SolonStockHub")));
        uint256 hubId = hub.orderCount() - 1;
        HubSettlement.Order memory o = hub.getOrder(hubId);
        assertEq(o.amountIn % 1e12, 0);
        assertEq(o.amountIn, budget, "hub principal = aligned budget");
        _launchFunding(hub, hubId);
        manager.poke(roundId);
        manager.submit(roundId);
        uint256 raw = manager.round(roundId).minRawOut + 1;
        _fill(hub, hubId, raw);
        manager.finalize(roundId, "");
        assertEq(uint8(manager.round(roundId).status), uint8(RewardRoundManager.Status.Settled));
        assertEq(manager.available(entryId), sealed18 % 1e12, "tail still available after settlement");
    }

    function _launch() internal returns (V3RewardToken) {
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
            "Dec", "DEC", 0, bytes32(uint256(1)), creator, V3LaunchFactory.QuoteConfig(0, address(0), 0, address(0)), 1
        );
        vm.stopPrank();
        return V3RewardToken(payable(l.token));
    }

    function _trade(V3RewardToken token, uint256 whaleIn) internal {
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 0, 100, IHooks(h.addr("V3QuoteFeeHook")));
        V3Router router = V3Router(payable(h.addr("V3Router")));
        vm.deal(holder, 100 ether);
        vm.prank(holder);
        router.swap{value: 100 ether}(V3Router.SwapRequest(key, true, -100 ether, 0, 1, 100 ether, holder, block.timestamp));
        vm.deal(whale, whaleIn);
        vm.prank(whale);
        router.swap{value: whaleIn}(
            V3Router.SwapRequest(key, true, -int256(whaleIn), 0, 1, whaleIn, whale, block.timestamp)
        );
    }

    /// @dev What the batcher will reserve (the keeper signs exactly this).
    function _previewTotal(RewardRoundManager manager, uint256 entryId, uint256 maxBudget) internal returns (uint256 t) {
        RewardBatcher batcher = RewardBatcher(h.addr("RewardBatcher"));
        batcher.enqueue(entryId);
        (,, t) = batcher.previewBatch(manager.groupKey(entryId), maxBudget);
    }

    /// @dev The keeper signs for what the batcher will reserve; anyone may pass the raw sealed amount as maxBudget.
    function _startRound(RewardRoundManager manager, uint256 entryId, address asset, uint256 maxBudget, uint256 budget)
        internal
        returns (uint256 roundId)
    {
        RewardBatcher batcher = RewardBatcher(h.addr("RewardBatcher"));
        uint256 minRaw = SolonStockOracle(h.addr("SolonStockOracle")).rawFor(asset, budget);
        uint256 deadline = block.timestamp + 1 hours;
        uint256[] memory ids = new uint256[](1);
        ids[0] = entryId;
        bytes32 entriesHash = keccak256(abi.encode(bytes32(0), manager.entry(entryId), budget));
        bytes32 orderId = keccak256(
            abi.encode(block.chainid, address(manager), entriesHash, minRaw, deadline, manager.executionNonce(entriesHash))
        );
        StockAdapterRegistry.Route memory route = StockAdapterRegistry(h.addr("StockAdapterRegistry"))
            .resolve(manager.entry(entryId).assetId, manager.entry(entryId).adapterVersion);
        SolonStockAdapter adapter = SolonStockAdapter(payable(route.adapter));
        uint256 external18 = budget / 200;
        uint256 fees = (budget * 25) / 10_000 + external18;
        adapter.depositFees{value: fees}(orderId);
        SolonStockAdapter.SignedQuote memory q =
            SolonStockAdapter.SignedQuote(orderId, budget, minRaw, deadline, uint256(orderId), fees, external18);
        (uint8 v, bytes32 rs, bytes32 ss) = vm.sign(SIGNER_PK, adapter.quoteDigest(q));
        roundId = batcher.executeAndStart(ids, maxBudget, minRaw, deadline, abi.encode(q, abi.encodePacked(rs, ss, v)));
        assertEq(manager.round(roundId).orderId, orderId);
    }

    function _launchFunding(SolonStockHub hub, uint256 hubId) internal {
        RelayFundingRoute route = RelayFundingRoute(h.addr("RelayFundingRoute"));
        // [SIM] r14 (merged after this test was written): the route deposits through the 0x3600 ERC-20 view; the
        // local config only has placeholder addresses there, so install the same stubs as DeployV3Payout.t.sol.
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

    function _fill(SolonStockHub hub, uint256 hubId, uint256 raw) internal {
        address ep = h.addr("local_ArcLzEndpoint");
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
