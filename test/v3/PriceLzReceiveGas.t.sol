// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    VerifyV3PriceSender,
    PRICE_LZ_RECEIVE_GAS_DEFAULT,
    PRICE_LZ_RECEIVE_GAS_MIN,
    priceLzReceiveOptions
} from "../../script/v3/DeployV3Reserve.s.sol";

contract PriceSenderVerifierHarness is VerifyV3PriceSender {
    function optionGas(bytes memory b) external pure returns (uint128) {
        return _optionGas(b);
    }
}

/// @notice r10: the RH -> Arc price message's lzReceive gas. Testnet drill: the first delivery on Arc (3 stocks, cold
///         storage) used 477,031 gas for the whole tx; the old 300k default failed at the executor.
contract PriceLzReceiveGasTest is Test {
    uint256 constant MEASURED = 477_031;

    function test_defaultAndFloorAboveMeasured() public pure {
        assertGe(PRICE_LZ_RECEIVE_GAS_MIN, MEASURED * 12 / 10, "floor = measured + 20%");
        assertEq(PRICE_LZ_RECEIVE_GAS_DEFAULT, 600_000);
        assertGe(PRICE_LZ_RECEIVE_GAS_DEFAULT, PRICE_LZ_RECEIVE_GAS_MIN);
        assertLt(300_000, PRICE_LZ_RECEIVE_GAS_MIN, "the old default is refused");
    }

    function test_optionsEncodingAndVerifierDecode() public {
        PriceSenderVerifierHarness v = new PriceSenderVerifierHarness();
        bytes memory o = priceLzReceiveOptions(600_000);
        assertEq(o.length, 22);
        assertEq(o, abi.encodePacked(hex"000301001101", uint128(600_000)));
        assertEq(bytes6(o), bytes6(hex"000301001101"), "type 3, executor, 17 bytes, lzReceive");
        assertEq(v.optionGas(o), 600_000);
        assertEq(v.optionGas(priceLzReceiveOptions(PRICE_LZ_RECEIVE_GAS_MIN - 1)), PRICE_LZ_RECEIVE_GAS_MIN - 1);
    }
}
