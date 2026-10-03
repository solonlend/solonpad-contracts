// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable ERC20 whose transfers can be made lossy per sender/recipient (fee-on-transfer):
///         the recipient gets n-1 and 1 is burned to 0xdead, while the sender is debited the full n.
contract CovBTaxToken is ERC20 {
    mapping(address => bool) public taxTo;
    mapping(address => bool) public taxFrom;

    constructor() ERC20("CovB", "COVB") {}

    function mint(address to, uint256 n) external {
        _mint(to, n);
    }

    function setTaxTo(address a, bool b) external {
        taxTo[a] = b;
    }

    function setTaxFrom(address a, bool b) external {
        taxFrom[a] = b;
    }

    function _update(address from, address to, uint256 n) internal override {
        if (from != address(0) && to != address(0) && n > 0 && (taxTo[to] || taxFrom[from])) {
            super._update(from, to, n - 1);
            super._update(from, address(0xdead), 1);
        } else {
            super._update(from, to, n);
        }
    }
}

/// @notice Contract that rejects every native transfer.
contract CovBEthRejecter {
    receive() external payable {
        revert("no eth");
    }
}

/// @notice Contract with code that accepts anything (generic sink / payout stand-in).
contract CovBSink {
    receive() external payable {}
}

/// @notice IEligibilityStatus stand-in for EligibilityController (A-mode).
contract CovBStatus {
    bytes32 public constant POLICY = keccak256("covb-policy");
    mapping(address => bool) public ok;

    function set(address w, bool b) external {
        ok[w] = b;
    }

    function policyOf(address) external pure returns (bytes32) {
        return POLICY;
    }

    function status(address w, uint8, uint256) external view returns (bool) {
        return ok[w];
    }
}
