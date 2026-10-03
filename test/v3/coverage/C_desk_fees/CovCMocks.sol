// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V3FeeLedger} from "../../../../src/v3/V3FeeLedger.sol";

/// @notice ERC20 with address-scoped misbehaviour switches used to reach exact-delta guards.
///  - shortFrom: transfers whose `from` is this address deliver 1 unit less to the recipient (fee-on-transfer).
///  - extraFrom: transfers whose `from` is this address burn 1 extra unit from the sender.
///  - blocked:   every non-mint transfer reverts.
contract CovCToken is ERC20 {
    address public shortFrom;
    address public extraFrom;
    bool public blocked;

    constructor() ERC20("CovC", "COVC") {}

    function mint(address to, uint256 n) external {
        _mint(to, n);
    }

    function setShortFrom(address a) external {
        shortFrom = a;
    }

    function setExtraFrom(address a) external {
        extraFrom = a;
    }

    function setBlocked(bool b) external {
        blocked = b;
    }

    function _update(address from, address to, uint256 n) internal override {
        require(!blocked || from == address(0), "Frozen");
        super._update(from, to, n);
        if (from == address(0) || to == address(0) || n == 0) return;
        if (from == shortFrom) super._update(to, address(0), 1);
        if (from == extraFrom) super._update(from, address(0), 1);
    }
}

/// @notice Programmable stand-in for V3FeeLedger (only the surface used by the fee modules).
contract CovCMockLedger {
    mapping(bytes32 => V3FeeLedger.Pool) internal pools;
    mapping(bytes32 => mapping(uint8 => bool)) public controlledClaim;
    mapping(bytes32 => mapping(uint256 => uint256)) public accrued;
    bool public claimReturns = true;
    uint256 public payShort; // pay `amount - payShort`
    uint256 public payExtra; // pay `amount + payExtra`
    // claimStockLot behaviour
    uint256 public lotReturn;
    uint256 public lotPay;

    function setPool(bytes32 id, address quote, uint8 kind, address hook, address[6] memory b) external {
        pools[id] = V3FeeLedger.Pool(quote, kind, hook, b);
    }

    function setControlled(bytes32 id, uint8 bucket, bool v) external {
        controlledClaim[id][bucket] = v;
    }

    function setAccrued(bytes32 id, uint8 bucket, uint256 v) external {
        accrued[id][bucket] = v;
    }

    function setClaimBehaviour(bool returns_, uint256 short_, uint256 extra_) external {
        claimReturns = returns_;
        payShort = short_;
        payExtra = extra_;
    }

    function setLot(uint256 ret, uint256 pay) external {
        lotReturn = ret;
        lotPay = pay;
    }

    function poolInfo(bytes32 id) external view returns (V3FeeLedger.Pool memory) {
        return pools[id];
    }

    function enableControlledClaim(bytes32 id, uint8 bucket) external {
        require(msg.sender == pools[id].beneficiaries[bucket], "mock: not beneficiary");
        controlledClaim[id][bucket] = true;
    }

    function enableStockLotCustody(bytes32, uint8) external {}

    function claim(bytes32 id, uint8 bucket, uint256 amount) external returns (bool) {
        if (!claimReturns) return false;
        if (accrued[id][bucket] >= amount) accrued[id][bucket] -= amount;
        uint256 pay = amount + payExtra - payShort;
        if (pools[id].quote == address(0)) {
            (bool ok,) = msg.sender.call{value: pay}("");
            require(ok, "mock: native pay");
        } else {
            IERC20(pools[id].quote).transfer(msg.sender, pay);
        }
        return true;
    }

    function claimStockLot(bytes32 id, uint256, uint8) external returns (uint256) {
        if (lotPay != 0) IERC20(pools[id].quote).transfer(msg.sender, lotPay);
        return lotReturn;
    }

    receive() external payable {}
}

/// @notice Plain ETH receiver whose acceptance can be switched off.
contract CovCSwitchReceiver {
    bool public rejects;

    function setRejects(bool v) external {
        rejects = v;
    }

    receive() external payable {
        require(!rejects, "CovC: rejected");
    }
}

/// @notice Contract with code but no payable entry points (any ETH push reverts).
contract CovCNoReceive {
    function ping() external pure returns (uint256) {
        return 1;
    }
}
