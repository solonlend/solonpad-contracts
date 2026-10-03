// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SolonStockOracle} from "./SolonStockOracle.sol";

interface IRefTickVault {
    struct PriceQuote {
        int24 refTick;
        uint24 maxDeviation;
        uint256 deadline;
        uint256 nonce;
    }

    function token() external view returns (address);
    function quoteDigest(PriceQuote memory q) external view returns (bytes32);
}

/// @title OracleRefTickSigner — the pool-A "price signer" backed by SolonStockOracle (design r7 §12.2)
/// @notice `StockPoolVault` accepts a reference tick only with a valid signature from its fixed `priceSigner`
///         (OpenZeppelin SignatureChecker, which falls back to ERC-1271 for contracts). Deploying the vault with
///         this contract as `priceSigner` replaces the off-chain signed price with the oracle's execution price
///         without changing the vault: the "signature" is the ABI-encoded quote itself, and it is valid only if
///         - it is the exact quote the calling vault (msg.sender of the static call) is checking, and
///         - its refTick is within `TICK_TOLERANCE` of the tick implied by `execPrice(vault.token())` (Live only).
///         The keeper still chooses when to act, the range and `maxDeviation` (vault-capped at 200 ticks); it can no
///         longer choose the reference price.
contract OracleRefTickSigner {
    bytes4 private constant MAGIC = 0x1626ba7e;
    /// @notice Rounding room between the keeper's tick and the on-chain one (~0.1%).
    int24 public constant TICK_TOLERANCE = 10;

    SolonStockOracle public immutable oracle;

    constructor(SolonStockOracle oracle_) {
        require(address(oracle_) != address(0));
        oracle = oracle_;
    }

    /// @notice Pool-A tick (currency0 native USDC, currency1 STOCK.sol, both 18 dp) of the oracle price:
    ///         price = STOCK.sol per USDC = 1e18 / priceUsd18. Reverts unless the oracle is Live.
    function refTickOf(address stockToken) public view returns (int24) {
        (uint256 p,) = oracle.execPrice(stockToken);
        uint256 ratioX192 = FullMath.mulDiv(uint256(1) << 192, 1e18, p);
        uint256 sqrtP = Math.sqrt(ratioX192);
        require(sqrtP >= TickMath.MIN_SQRT_PRICE && sqrtP < TickMath.MAX_SQRT_PRICE, "price range");
        return TickMath.getTickAtSqrtPrice(uint160(sqrtP));
    }

    /// @notice The encoded signature a keeper passes for quote `q`.
    function encode(IRefTickVault.PriceQuote calldata q) external pure returns (bytes memory) {
        return abi.encode(q);
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        IRefTickVault.PriceQuote memory q = abi.decode(signature, (IRefTickVault.PriceQuote));
        IRefTickVault vault = IRefTickVault(msg.sender);
        if (vault.quoteDigest(q) != hash) return 0xffffffff;
        int24 t = refTickOf(vault.token());
        int24 gap = q.refTick > t ? q.refTick - t : t - q.refTick;
        return gap <= TICK_TOLERANCE ? MAGIC : bytes4(0xffffffff);
    }
}
