// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

// Uniswap V4 base
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

// Pons V2 suite (verified production sources)
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2LaunchDeployer} from "../src/v2/PonsV2LaunchDeployer.sol";
import {PonsV2GraduationExecutor} from "../src/v2/PonsV2GraduationExecutor.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {PonsV2LaunchLocker} from "../src/v2/PonsV2LaunchLocker.sol";
import {PonsV2BuybackVault} from "../src/v2/PonsV2BuybackVault.sol";
import {PonsV2FeeEscrow} from "../src/v2/PonsV2FeeEscrow.sol";
import {PonsV2MemeHook} from "../src/v2/hooks/PonsV2MemeHook.sol";
import {IPonsV2FeeEscrow} from "../src/v2/interfaces/ILaunchpadV2.sol";

/// Full-lifecycle integration test of the Pons V2 port on a local EVM:
/// deploy V4 base + Pons suite exactly as we will on Arc testnet, then
/// launch → snipe-tax window → curve buys/sells → fee sweep + buyback lock →
/// graduating buy → createGraduatedPool → V4 swap through the meme hook →
/// escrow claims. Quote asset is the native coin (on Arc: native USDC).
contract PonsV2IntegrationTest is Test {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Arc test parameters: production curve shape (4.2 : 1.68 = 20 : 8),
    // scaled so a faucet wallet can graduate a launch.
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant PHANTOM = 8e18;
    uint256 constant GRADUATION = 20e18;
    uint256 constant LAUNCH_FEE = 1e18;

    PoolManager poolManager;
    PositionManager positionManager;
    PoolSwapTest swapRouter;
    PonsV2FeeEscrow feeEscrow;
    PonsV2MemeHook hook;
    PonsV2BuybackVault vault;
    PonsV2LaunchLocker locker;
    PonsV2LaunchFactory factory;
    PonsV2GraduationExecutor executor;
    PonsV2LaunchDeployer deployer;

    address owner = makeAddr("owner");
    address protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    address token;
    address curve;

    function setUp() public virtual {
        // Canonical Permit2, etched from Arc testnet bytecode at its real address.
        vm.etch(PERMIT2, vm.parseBytes(vm.trim(vm.readFile("test/permit2.bytecode"))));

        vm.startPrank(owner);
        poolManager = new PoolManager(owner);
        positionManager = new PositionManager(
            IPoolManager(address(poolManager)),
            IAllowanceTransfer(PERMIT2),
            300_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0))
        );
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        feeEscrow = new PonsV2FeeEscrow();

        // Hook address must encode its permission flags in the low 14 bits.
        uint160 flags =
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory hookInitcode = abi.encodePacked(
            type(PonsV2MemeHook).creationCode,
            abi.encode(IPoolManager(address(poolManager)), feeEscrow, protocolFeeRecipient, owner)
        );
        bytes32 salt = _mineHookSalt(owner, hookInitcode, flags);
        hook = new PonsV2MemeHook{salt: salt}(
            IPoolManager(address(poolManager)), feeEscrow, protocolFeeRecipient, owner
        );
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, flags, "hook flags");

        vault = new PonsV2BuybackVault(owner, hook, feeEscrow);
        locker = new PonsV2LaunchLocker(owner, address(positionManager));
        factory = new PonsV2LaunchFactory(
            owner,
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(PERMIT2),
            locker,
            hook,
            feeEscrow,
            vault,
            LAUNCH_FEE
        );
        executor = new PonsV2GraduationExecutor(
            IPositionManager(address(positionManager)), IAllowanceTransfer(PERMIT2), locker, address(factory)
        );
        deployer = new PonsV2LaunchDeployer(address(factory));

        factory.setGraduationExecutor(executor);
        factory.setLaunchDeployer(deployer);
        hook.setFactory(address(factory));
        hook.setBuybackVault(vault);
        locker.setFactory(address(factory));
        vault.setFactory(address(factory));

        factory.addLaunchConfig(
            PonsV2LaunchFactory.LaunchConfig({
                supply: SUPPLY,
                curveFeeBps: 100,
                phantomQuote: PHANTOM,
                graduationThreshold: GRADUATION,
                poolFee: 0,
                tickSpacing: 200,
                enabled: true
            })
        );
        factory.setLaunchEnabled(true);
        vm.stopPrank();

        vm.deal(creator, 100e18);
        vm.deal(alice, 100e18);
        vm.deal(bob, 100e18);

        vm.prank(creator);
        (token, curve) = factory.launchToken{value: LAUNCH_FEE}(_params(bytes32(uint256(1))), 0, address(0));
    }

    function _params(bytes32 salt) internal view returns (PonsV2LaunchFactory.TokenParams memory) {
        return PonsV2LaunchFactory.TokenParams({
            name: "Pons Arc Test",
            symbol: "PARC",
            logo: "",
            description: "port smoke",
            socials: PonsV2LauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: creator,
            creatorTaxBps: 0,
            buybackEnabled: true,
            expectedEconomics: bytes32(0),
            salt: salt
        });
    }

    function _mineHookSalt(address create2Deployer, bytes memory initcode, uint160 flags)
        internal
        view
        returns (bytes32)
    {
        bytes32 initHash = keccak256(initcode);
        for (uint256 i = 0; i < 200_000; i++) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), create2Deployer, salt, initHash))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags && predicted.code.length == 0) {
                return salt;
            }
        }
        revert("no salt found");
    }

    function test_launchState() public view {
        PonsV2BondingCurve c = PonsV2BondingCurve(curve);
        assertEq(address(c.token()), token);
        assertEq(c.trackedTokens(), SUPPLY);
        assertEq(c.phantomQuote(), PHANTOM);
        assertEq(c.graduationThreshold(), GRADUATION);
        assertGt(c.reservedTokens(), 0); // pool allocation reserved, never sold
        assertFalse(c.graduated());
        assertEq(PonsV2LauncherToken(token).totalSupply(), SUPPLY);
        assertEq(PonsV2LauncherToken(token).balanceOf(curve), SUPPLY);
    }

    function test_snipeTaxWindow() public {
        PonsV2BondingCurve c = PonsV2BondingCurve(curve);
        // launch second: non-exempt wallet faces the 99% tax, creator is exempt
        assertGt(c.currentSnipeTaxBps(alice), 9_000);
        assertEq(c.currentSnipeTaxBps(creator), 0);
        // decays to zero after the window
        vm.warp(block.timestamp + 16);
        assertEq(c.currentSnipeTaxBps(alice), 0);
    }

    function test_curveTrading_feesAndBuyback() public {
        vm.warp(block.timestamp + 16);
        PonsV2BondingCurve c = PonsV2BondingCurve(curve);

        vm.prank(alice);
        uint256 out = c.buy{value: 5e18}(5e18, 0, alice);
        assertGt(out, 0);
        assertEq(PonsV2LauncherToken(token).balanceOf(alice), out);
        assertGt(c.quoteFeeBalance(), 0);

        // sell a quarter back
        vm.startPrank(alice);
        PonsV2LauncherToken(token).approve(curve, out / 4);
        uint256 quoteBack = c.sell(out / 4, 0, alice);
        vm.stopPrank();
        assertGt(quoteBack, 0);

        // sweep: protocol share → escrow, buyback share → bought on curve and
        // locked in the five-year vault, creator share → escrow
        vm.prank(owner); // feeSweepOperator defaults to hook owner
        c.sweepFees(1);
        assertGt(feeEscrow.balanceOf(protocolFeeRecipient), 0, "protocol escrow");
        assertGt(feeEscrow.balanceOf(creator), 0, "creator escrow");
        assertGt(vault.totalLocked(token), 0, "buyback locked");

        // escrow claim pays native quote out
        uint256 before = protocolFeeRecipient.balance;
        vm.prank(protocolFeeRecipient);
        uint256 claimed = feeEscrow.claim();
        assertGt(claimed, 0);
        assertEq(protocolFeeRecipient.balance, before + claimed);
    }

    function test_graduation_and_v4Swap() public {
        vm.warp(block.timestamp + 16);
        PonsV2BondingCurve c = PonsV2BondingCurve(curve);

        // one oversized buy exhausts the sellable allocation (excess refunded)
        // and auto-graduates the curve
        vm.prank(alice);
        c.buy{value: 40e18}(40e18, 0, alice);
        assertTrue(c.graduated(), "graduated");
        assertEq(c.sellableTokens(), 0, "sellable exhausted");

        // phase 2: seed the locked full-range V4 pool (retryable; the crossing
        // buy may or may not have already run it via auto-graduation)
        if (!locker.isLocked(token)) {
            factory.createGraduatedPool(token);
        }
        assertTrue(locker.isLocked(token), "position locked");

        // trade on the graduated V4 pool through the meme hook
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        uint256 tokBefore = PonsV2LauncherToken(token).balanceOf(bob);
        vm.prank(bob);
        swapRouter.swap{value: 1e18}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 bought = PonsV2LauncherToken(token).balanceOf(bob) - tokBefore;
        assertGt(bought, 0, "v4 swap through hook");

        // and the reverse direction: token → native quote
        vm.startPrank(bob);
        PonsV2LauncherToken(token).approve(address(swapRouter), bought / 2);
        uint256 nativeBefore = bob.balance;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(bought / 2),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertGt(bob.balance, nativeBefore, "sell side through hook");
    }
}
