// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "../../../lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {
    ERC20Permit
} from "../../../lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title SolonStockToken — the `.sol` token (NVDA.sol, …)
/// @notice Forked from ArcStocks v2 `ArcStockV2` (MIT, verified Arc 0x0A2dd716…65f2). One token = one raw
///         unit of the underlying Robinhood Chain Stock Token held in the Solon reserve vault on
///         `reserveChainId`. Supply moves only through the hub, and the hub mints only inside the two
///         callbacks that carry a proof from the vault. There is no other minter and no owner.
/// @dev Solon changes: name "Solon <TICKER>", symbol "<TICKER>.sol". Corporate-action multipliers change
///      shares-per-token on the reserve chain, never this raw balance (design §8.4 / A13).
contract SolonStockToken is ERC20, ERC20Permit {
    /// @notice The hub that may mint and burn. Fixed at deployment.
    address public immutable hub;
    /// @notice The stock token this derivative is backed by, on `reserveChainId`.
    address public immutable underlying;
    uint256 public immutable reserveChainId;
    /// @notice Plain ticker, e.g. "NVDA".
    string public ticker;

    error NotHub();

    modifier onlyHub() {
        if (msg.sender != hub) revert NotHub();
        _;
    }

    constructor(string memory ticker_, address underlying_, uint256 reserveChainId_, address hub_)
        ERC20(string.concat("Solon ", ticker_), string.concat(ticker_, ".sol"))
        ERC20Permit(string.concat(ticker_, ".sol"))
    {
        ticker = ticker_;
        underlying = underlying_;
        reserveChainId = reserveChainId_;
        hub = hub_;
    }

    /// @notice The hub, under the name integrators read it by (`IArcStockView.vault` in the original).
    function vault() external view returns (address) {
        return hub;
    }

    function mint(address to, uint256 amount) external onlyHub {
        _mint(to, amount);
    }

    /// @notice Burns from `from` without an allowance: the hub only calls this inside a request the
    ///         holder signed themselves (`requestSell`, `canonicalRedeem`).
    function burn(address from, uint256 amount) external onlyHub {
        _burn(from, amount);
    }
}
