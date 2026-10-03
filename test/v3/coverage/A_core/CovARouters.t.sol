// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {HookFixture} from "../../helpers/HookFixture.sol";
import {HookToken} from "../../helpers/HookHarness.sol";
import {V3Router, IV3TradeEligibility} from "../../../../src/v3/V3Router.sol";
import {V3Quoter} from "../../../../src/v3/V3Quoter.sol";
import {V3MultiHopRouter, IV3HopEligibility} from "../../../../src/v3/V3MultiHopRouter.sol";
import {V3QuoteFeeHook} from "../../../../src/v3/V3QuoteFeeHook.sol";
import {StockPoolVault} from "../../../../src/v3/stock/StockPoolVault.sol";
import {RestockHub} from "../../StockPool.t.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @dev Caller without a payable fallback: any native refund to it fails.
contract CovANoReceive {
    function routerSwap(V3Router router, V3Router.SwapRequest calldata r) external payable {
        router.swap{value: msg.value}(r);
    }

    function quoterQuote(V3Quoter q, V3Router.SwapRequest calldata r) external payable {
        q.quote{value: msg.value}(r, address(this));
    }

    function hopQuote(V3MultiHopRouter hop, V3MultiHopRouter.HopRequest calldata r) external payable {
        hop.quote{value: msg.value}(r, address(this));
    }
}

contract CovAGate is IV3TradeEligibility, IV3HopEligibility {
    bool public open;

    function setOpen(bool o) external {
        open = o;
    }

    function checkTrade(bytes32, address, address, address, bool)
        external
        view
        override(IV3TradeEligibility, IV3HopEligibility)
    {
        require(open, "gate closed");
    }
}

/// @notice Branch coverage for V3Router and V3Quoter request validation, native-value and refund arms,
/// plus the router-side delta checks that only a misbehaving manager can reach.
contract CovARouterTest is HookFixture {
    V3Router internal official;
    address internal recipient = address(0xCAFE);

    function setUp() public {
        _setUp();
        official = new V3Router(manager, hook, IV3TradeEligibility(address(0)));
        for (uint256 i; i < 3; ++i) {
            _launch(i);
            HookToken(memes[i]).approve(address(official), type(uint256).max);
            if (quotes[i] != address(0)) HookToken(quotes[i]).approve(address(official), type(uint256).max);
        }
    }

    function _request(uint256 layout, bool buy, int256 specified) internal view returns (V3Router.SwapRequest memory) {
        return V3Router.SwapRequest(keys[layout], buy, specified, 0, 1, 1e24, recipient, block.timestamp);
    }

    // line 82: every constructor dependency arm
    function testRouterConstructorDependencies() public {
        vm.expectRevert(V3Router.InvalidDependency.selector);
        new V3Router(IPoolManager(address(0xDEAD)), hook, IV3TradeEligibility(address(0)));
        vm.expectRevert(V3Router.InvalidDependency.selector);
        new V3Router(manager, V3QuoteFeeHook(payable(address(0xDEAD))), IV3TradeEligibility(address(0)));
        PoolManager other = new PoolManager(address(this));
        vm.expectRevert(V3Router.InvalidDependency.selector);
        new V3Router(other, hook, IV3TradeEligibility(address(0)));
        vm.expectRevert(V3Router.InvalidDependency.selector);
        new V3Router(manager, hook, IV3TradeEligibility(address(0xDEAD)));
        CovAGate gate = new CovAGate();
        V3Router gated = new V3Router(manager, hook, gate);
        assertEq(address(gated.eligibility()), address(gate));
        assertEq(gated.factory(), hook.factory());
    }

    // line 97: every InvalidRequest arm
    function testValidateRequestInvalidArms() public {
        V3Router.SwapRequest memory r = _request(0, true, -10001);
        vm.expectRevert(V3Router.InvalidRequest.selector);
        official.validateRequest(r, address(0));
        r.recipient = address(0);
        vm.expectRevert(V3Router.InvalidRequest.selector);
        official.validateRequest(r, address(this));
        r.recipient = address(official);
        vm.expectRevert(V3Router.InvalidRequest.selector);
        official.validateRequest(r, address(this));
        r = _request(0, true, 0);
        vm.expectRevert(V3Router.InvalidRequest.selector);
        official.validateRequest(r, address(this));
        r.amountSpecified = int256(type(int128).max) + 1;
        vm.expectRevert(V3Router.InvalidRequest.selector);
        official.validateRequest(r, address(this));
        r.amountSpecified = -int256(type(int128).max) - 1;
        vm.expectRevert(V3Router.InvalidRequest.selector);
        official.validateRequest(r, address(this));
        r = _request(0, true, -10001);
        r.maxIn = 0;
        vm.expectRevert(V3Router.InvalidRequest.selector);
        official.validateRequest(r, address(this));
        r.maxIn = uint256(uint128(type(int128).max)) + 1;
        vm.expectRevert(V3Router.InvalidRequest.selector);
        official.validateRequest(r, address(this));
        // boundaries accepted
        r.maxIn = uint256(uint128(type(int128).max));
        r.amountSpecified = -int256(type(int128).max);
        V3Router.PoolMetadata memory p = official.validateRequest(r, address(this));
        assertTrue(p.zeroForOne);
        r.amountSpecified = int256(type(int128).max);
        p = official.validateRequest(r, address(this));
        assertEq(p.quoteAsset, address(0));
    }

    // line 142: both NativeValueMismatch arms
    function testNativeValueMismatchArms() public {
        vm.expectRevert(V3Router.NativeValueMismatch.selector);
        official.swap{value: 10000}(_request(0, true, -10001)); // native input underfunded
        vm.expectRevert(V3Router.NativeValueMismatch.selector);
        official.swap{value: 1}(_request(1, true, -10001)); // ERC20 input with value
        vm.expectRevert(V3Router.NativeValueMismatch.selector);
        official.swap{value: 1}(_request(0, false, -10001)); // native pool sell: meme input
        assertEq(address(ledger).balance, 0);
    }

    // line 208: overpayment refund to a payer that cannot receive
    function testRefundFailureRevertsWholeSwap() public {
        CovANoReceive payer = new CovANoReceive();
        vm.deal(address(payer), 0);
        vm.expectRevert(V3Router.NativeRefundFailed.selector);
        payer.routerSwap{value: 20002}(official, _request(0, true, -10001));
        assertEq(HookToken(memes[0]).balanceOf(recipient), 0);
        // exact funding needs no refund
        payer.routerSwap{value: 10001}(official, _request(0, true, -10001));
        assertGt(HookToken(memes[0]).balanceOf(recipient), 0);
    }

    // line 176: a manager returning a non-negative input / non-positive output delta
    function testInvalidDeltaFromMisbehavingManager() public {
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), abi.encode(toBalanceDelta(0, 5)));
        vm.expectRevert(V3Router.InvalidDelta.selector);
        official.swap{value: 10001}(_request(0, true, -10001));
        vm.mockCall(
            address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), abi.encode(toBalanceDelta(-10001, 0))
        );
        vm.expectRevert(V3Router.InvalidDelta.selector);
        official.swap{value: 10001}(_request(0, true, -10001));
        vm.clearMockedCalls();
        official.swap{value: 10001}(_request(0, true, -10001));
    }

    // line 179-181: router-side full-fill check (the hook's identical check is bypassed by the mock)
    function testRouterPartialFillCheckBothModes() public {
        vm.mockCall(
            address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), abi.encode(toBalanceDelta(-10000, 50))
        );
        vm.expectRevert(V3Router.PartialFillUnsupported.selector);
        official.swap{value: 10001}(_request(0, true, -10001)); // exact in, short input
        vm.mockCall(
            address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), abi.encode(toBalanceDelta(-500, 10000))
        );
        vm.expectRevert(V3Router.PartialFillUnsupported.selector);
        official.swap{value: 1e24}(_request(0, true, 10001)); // exact out, short output
        vm.clearMockedCalls();
    }

    // V3Quoter line 51-52: a non-SimulationResult failure inside the simulation is bubbled verbatim
    // (the router wraps it in SimulationFailure). Line 49 is unreachable: V3Router.simulate reverts on both
    // paths (line 120 SimulationResult on success, line 124 SimulationFailure on failure), so the quoter's
    // try-success arm can never run.
    function testQuoterBubblesSimulationFailureVerbatim() public {
        V3Quoter quoter = new V3Quoter(official);
        // validateRequest (quoter line 47) does not check msg.value; _execute does (router line 142)
        bytes memory inner = abi.encodeWithSelector(V3Router.NativeValueMismatch.selector);
        vm.expectRevert(abi.encodeWithSelector(V3Router.SimulationFailure.selector, inner));
        quoter.quote{value: 10000}(_request(0, true, -10001), address(this));
        V3Router.SwapRequest memory r = _request(0, true, -10001);
        r.minOut = 1e30;
        inner = abi.encodeWithSelector(V3Router.SlippageExceeded.selector);
        vm.expectRevert(abi.encodeWithSelector(V3Router.SimulationFailure.selector, inner));
        quoter.quote{value: 10001}(r, address(this));
        assertEq(address(quoter).balance, 0);
        assertEq(address(official).balance, 0);
        assertEq(ledger.totalReceived(PoolId.unwrap(keys[0].toId())), 0);
    }

    // V3Quoter line 37 and line 81
    function testQuoterConstructorAndRefundFailure() public {
        vm.expectRevert(V3Quoter.InvalidRouter.selector);
        new V3Quoter(V3Router(payable(address(0xDEAD))));
        V3Quoter quoter = new V3Quoter(official);
        CovANoReceive caller = new CovANoReceive();
        vm.expectRevert(V3Quoter.NativeRefundFailed.selector);
        caller.quoterQuote{value: 10001}(quoter, _request(0, true, -10001));
        // value-free quote needs no refund (line 79 false arm)
        HookToken(quotes[1]).mint(address(caller), 0);
        V3Quoter.Quote memory q = quoter.quote(_request(1, false, -10001), address(this));
        assertGt(q.minOut, 0);
    }
}

/// @notice Branch coverage for V3MultiHopRouter (fixture copied from StockPool.t.sol).
contract CovAMultiHopTest is HookFixture {
    uint256 constant SIGNER = 0x9A1C;
    StockPoolVault pool;
    V3MultiHopRouter hop;
    RestockHub restock;
    HookToken stock;
    HookToken meme;
    address keeper = address(0xB07);
    address governor = address(0x60F);
    address recipient = address(0xCAFE);

    function setUp() public {
        _setUp();
        _launch(1);
        stock = HookToken(quotes[1]);
        meme = HookToken(memes[1]);
        restock = new RestockHub();
        pool = new StockPoolVault(
            StockPoolVault.Config(
                manager,
                address(stock),
                address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC),
                address(restock),
                address(0x7EA5),
                keeper,
                vm.addr(SIGNER),
                governor,
                address(0x7EA6)
            )
        );
        vm.deal(address(pool), 1_000 ether);
        stock.mint(address(pool), 1_000 ether);
        vm.prank(governor);
        pool.initialize(uint160(1 << 96));
        StockPoolVault.PriceQuote memory q = StockPoolVault.PriceQuote(0, 100, block.timestamp + 60, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER, pool.quoteDigest(q));
        vm.prank(keeper);
        pool.rebalanceRange(-400, 400, q, abi.encodePacked(r, s, v));
        hop = new V3MultiHopRouter(manager, hook, pool.poolKey(), IV3HopEligibility(address(0)));
        meme.approve(address(hop), type(uint256).max);
    }

    function _req(bool buy, uint256 amountIn) internal view returns (V3MultiHopRouter.HopRequest memory) {
        return V3MultiHopRouter.HopRequest(keys[1], buy, amountIn, 1, recipient, block.timestamp);
    }

    // line 74: every constructor arm
    function testHopConstructorDependencies() public {
        PoolKey memory a = pool.poolKey();
        vm.expectRevert(V3MultiHopRouter.InvalidDependency.selector);
        new V3MultiHopRouter(IPoolManager(address(0xDEAD)), hook, a, IV3HopEligibility(address(0)));
        PoolManager other = new PoolManager(address(this));
        vm.expectRevert(V3MultiHopRouter.InvalidDependency.selector);
        new V3MultiHopRouter(other, hook, a, IV3HopEligibility(address(0)));
        PoolKey memory bad = a;
        bad.currency0 = Currency.wrap(address(stock));
        vm.expectRevert(V3MultiHopRouter.InvalidDependency.selector);
        new V3MultiHopRouter(manager, hook, bad, IV3HopEligibility(address(0)));
        bad = a;
        bad.hooks = IHooks(address(hook));
        vm.expectRevert(V3MultiHopRouter.InvalidDependency.selector);
        new V3MultiHopRouter(manager, hook, bad, IV3HopEligibility(address(0)));
        bad = a;
        bad.currency1 = Currency.wrap(address(0xDEAD));
        vm.expectRevert(V3MultiHopRouter.InvalidDependency.selector);
        new V3MultiHopRouter(manager, hook, bad, IV3HopEligibility(address(0)));
        vm.expectRevert(V3MultiHopRouter.InvalidDependency.selector);
        new V3MultiHopRouter(manager, hook, a, IV3HopEligibility(address(0xDEAD)));
    }

    // lines 128, 129, 119, 152
    function testHopRequestGuardsAndCallbacks() public {
        V3MultiHopRouter.HopRequest memory r = _req(true, 1 ether);
        r.deadline = block.timestamp - 1;
        vm.expectRevert(V3MultiHopRouter.DeadlineExpired.selector);
        hop.swapExactIn{value: 1 ether}(r);
        r = _req(true, 0);
        vm.expectRevert(V3MultiHopRouter.InvalidRequest.selector);
        hop.swapExactIn(r);
        r = _req(false, uint256(uint128(type(int128).max)) + 1);
        vm.expectRevert(V3MultiHopRouter.InvalidRequest.selector);
        hop.swapExactIn(r);
        r = _req(true, 1 ether);
        r.recipient = address(0);
        vm.expectRevert(V3MultiHopRouter.InvalidRequest.selector);
        hop.swapExactIn{value: 1 ether}(r);
        vm.expectRevert(V3MultiHopRouter.OnlySelf.selector);
        hop.simulationBody(_req(true, 1 ether), address(this));
        vm.expectRevert(V3MultiHopRouter.UnauthorizedCallback.selector);
        hop.unlockCallback(abi.encode(_req(true, 1 ether)));
        vm.prank(address(manager));
        vm.expectRevert(V3MultiHopRouter.UnauthorizedCallback.selector);
        hop.unlockCallback(abi.encode(_req(true, 1 ether)));
        assertEq(meme.balanceOf(recipient), 0);
    }

    // line 146: eligibility gate closed / open
    function testHopEligibilityGate() public {
        CovAGate gate = new CovAGate();
        V3MultiHopRouter gated = new V3MultiHopRouter(manager, hook, pool.poolKey(), gate);
        vm.expectRevert(bytes("gate closed"));
        gated.swapExactIn{value: 1 ether}(_req(true, 1 ether));
        gate.setOpen(true);
        uint256 out = gated.swapExactIn{value: 1 ether}(_req(true, 1 ether));
        assertEq(meme.balanceOf(recipient), out);
        assertGt(out, 0);
    }

    // line 110: funded quote refund to a caller that cannot receive
    function testHopQuoteRefundFailure() public {
        CovANoReceive caller = new CovANoReceive();
        vm.expectRevert(V3MultiHopRouter.NativeValueMismatch.selector);
        caller.hopQuote{value: 1 ether}(hop, _req(true, 1 ether));
        assertEq(address(hop).balance, 0);
    }

    // line 114: simulation fails for a non-SimulationResult reason -> SimulationFailure(inner bytes).
    // Line 99 is unreachable: simulationBody never returns normally - it either reverts early or ends
    // with `revert SimulationResult(...)` (V3MultiHopRouter.sol:121).
    function testHopQuoteWrapsInnerFailure() public {
        V3MultiHopRouter.HopRequest memory r = _req(true, 1 ether);
        r.deadline = block.timestamp - 1;
        bytes memory inner = abi.encodeWithSelector(V3MultiHopRouter.DeadlineExpired.selector);
        vm.expectRevert(abi.encodeWithSelector(V3MultiHopRouter.SimulationFailure.selector, inner));
        hop.quote{value: 1 ether}(r, address(this));
        r = _req(true, 1 ether);
        r.minOut = type(uint128).max; // reverts inside the unlock callback (line 169)
        inner = abi.encodeWithSelector(V3MultiHopRouter.SlippageExceeded.selector);
        vm.expectRevert(abi.encodeWithSelector(V3MultiHopRouter.SimulationFailure.selector, inner));
        hop.quote{value: 1 ether}(r, address(this));
        // value mismatch for a buy
        inner = abi.encodeWithSelector(V3MultiHopRouter.NativeValueMismatch.selector);
        vm.expectRevert(abi.encodeWithSelector(V3MultiHopRouter.SimulationFailure.selector, inner));
        hop.quote{value: 0.5 ether}(_req(true, 1 ether), address(this));
        assertEq(address(hop).balance, 0);
        assertEq(meme.balanceOf(recipient), 0);
    }

    // line 175: meme input taxed on the way into the manager
    function testHopSellInexactMemeSettlement() public {
        hop.swapExactIn{value: 10 ether}(_req(true, 10 ether));
        meme.mint(address(this), 1 ether);
        meme.setTaxRoute(address(this), address(manager));
        uint256 before = meme.balanceOf(address(this));
        vm.expectRevert(V3MultiHopRouter.PartialFillUnsupported.selector);
        hop.swapExactIn(_req(false, 1 ether));
        assertEq(meme.balanceOf(address(this)), before);
        meme.setTaxRoute(address(0), address(0));
        uint256 r0 = recipient.balance;
        uint256 out = hop.swapExactIn(_req(false, 1 ether));
        assertEq(recipient.balance - r0, out);
    }

    // line 194: pool A runs out of in-range liquidity -> partial fill rejected
    function testHopPoolAPartialFillRejected() public {
        uint256 before = address(this).balance;
        vm.expectRevert(V3MultiHopRouter.PartialFillUnsupported.selector);
        hop.swapExactIn{value: 1e30}(_req(true, 1e30));
        assertEq(address(this).balance, before);
        assertEq(meme.balanceOf(recipient), 0);
    }
}
