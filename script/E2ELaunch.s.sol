// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {PonsV2LaunchLocker} from "../src/v2/PonsV2LaunchLocker.sol";
import {PonsV2BuybackVault} from "../src/v2/PonsV2BuybackVault.sol";
import {PonsV2FeeEscrow} from "../src/v2/PonsV2FeeEscrow.sol";
import {PonsV2MemeHook} from "../src/v2/hooks/PonsV2MemeHook.sol";

/// End-to-end lifecycle on Arc testnet against the deployed Pons V2 stack:
/// launch → curve buy → fee sweep (buyback+lock) → graduating buy →
/// createGraduatedPool → V4 swaps through the meme hook.
/// The deployer is the creator, so it is snipe-tax-exempt and can run the
/// whole flow back-to-back.
contract E2ELaunch is Script {
    address constant FACTORY = 0x90022cC2107De9c070F889E3A67009FcA270E4E2;
    address constant LOCKER = 0x7efb5B773BBbf69Bd163b52b1BA88C529a0f123c;
    address constant VAULT = 0xe84D81C3d4f3E12123C9F934AB3Cb8238772b39e;
    address constant ESCROW = 0x6133392C976d5160CBDE63815f7cd63122f3841C;
    address constant HOOK = 0x15eB3aeE2f96A199165dc58e6C8dc3Ce2e02e044;
    address constant SWAP_ROUTER = 0xD29ee84A8ad72A510D9dF9cB7A5021546431D97E;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        PonsV2LaunchFactory factory = PonsV2LaunchFactory(payable(FACTORY));

        vm.startBroadcast(pk);

        // 1. launch (native USDC quote → pairToken = 0)
        (address token, address curve) = factory.launchToken{value: 1e18}(
            PonsV2LaunchFactory.TokenParams({
                name: "Arc Pons One",
                symbol: "APONE",
                logo: "",
                description: "first Pons V2 launch on Arc",
                socials: PonsV2LauncherToken.Socials("", "", "", "", ""),
                creatorFeeRecipient: me,
                creatorTaxBps: 0,
                buybackEnabled: true,
                expectedEconomics: bytes32(0),
                salt: bytes32(uint256(0xA5C1))
            }),
            0,
            address(0)
        );
        PonsV2BondingCurve c = PonsV2BondingCurve(curve);

        // 2. curve buy: 5 native USDC
        uint256 out1 = c.buy{value: 5e18}(5e18, 0, me);

        // 3. sweep curve fees while the curve is live: protocol+creator →
        //    escrow, buyback slice bought on-curve and locked in the vault
        c.sweepFees(1);

        // 4. graduating buy: oversized, excess refunds, auto-graduates
        c.buy{value: 30e18}(30e18, 0, me);

        // 5. phase 2 if the auto-graduation didn't seed the pool yet
        if (!PonsV2LaunchLocker(LOCKER).isLocked(token)) {
            factory.createGraduatedPool(token);
        }

        // 6. V4 swaps through the meme hook: buy then sell
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(HOOK)
        });
        PoolSwapTest(SWAP_ROUTER).swap{value: 1e18}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        PonsV2LauncherToken(token).approve(SWAP_ROUTER, 10_000_000e18);
        PoolSwapTest(SWAP_ROUTER).swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -10_000_000e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        vm.stopBroadcast();

        console.log("token:", token);
        console.log("curve:", curve);
        console.log("curve buy out:", out1);
        console.log("graduated:", c.graduated());
        console.log("position locked:", PonsV2LaunchLocker(LOCKER).isLocked(token));
        console.log("vault locked tokens:", PonsV2BuybackVault(VAULT).totalLocked(token));
        console.log("escrow protocol bal:", PonsV2FeeEscrow(ESCROW).balanceOf(me));
        console.log("my token balance:", PonsV2LauncherToken(token).balanceOf(me));
    }
}
