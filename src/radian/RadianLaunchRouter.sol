// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PonsV2LaunchFactory} from "../v2/PonsV2LaunchFactory.sol";
import {Clones1167} from "./lib/Clones1167.sol";
import {WallTreasury} from "./wall/WallTreasury.sol";
import {WallStaking} from "./wall/WallStaking.sol";
import {PoFVault} from "./pof/PoFVault.sol";
import {PoFRouter} from "./pof/PoFRouter.sol";

interface IRadianCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);
}

/// @title RadianLaunchRouter
/// @notice The factory's trusted `launchForwarder`, and the home of launch
///         templates. Every path is one transaction for the user:
///         - `launchAndBuy`: a standard launch plus the creator's opening buy.
///         - `launchWall`: a "stock treasury" launch — creator fees flow to a
///           per-launch WallTreasury (never sold, defends book value on the
///           curve) and a WallStaking pool that pays stakers in the quote asset.
///         - `launchPoF`: a Proof-of-Fee launch — creator fees buy the token
///           back and the buybacks are distributed by round to the traders who
///           paid the fees, through PoFRouter.
///         Launches are attributed to the real user (creator, CREATE2 namespace,
///         snipe-tax exemption); the router holds nothing between calls.
contract RadianLaunchRouter {
    using SafeERC20 for IERC20;

    PonsV2LaunchFactory public immutable factory;
    address public immutable wallTreasuryImpl;
    address public immutable wallStakingImpl;
    address public immutable pofVaultImpl;
    PoFRouter public immutable pofRouter;
    address public keeper; // platform keeper for template treasuries (defend / claimAndBuy)

    uint256 private _lock = 1;

    event LaunchedAndBought(
        address indexed deployer, address indexed token, address indexed curve, address pairToken, uint256 quoteIn, uint256 tokensOut
    );
    event WallLaunched(address indexed deployer, address indexed token, address curve, address treasury, address staking, address pairToken);
    event PoFLaunched(address indexed deployer, address indexed token, address curve, address vault, address pairToken);
    event KeeperSet(address keeper);

    error BadValue(uint256 expected, uint256 actual);
    error RefundFailed();
    error NotOwner();

    modifier nonReentrant() {
        require(_lock == 1, "reentrancy");
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(PonsV2LaunchFactory factory_, address wallTreasuryImpl_, address wallStakingImpl_, address pofVaultImpl_) {
        require(address(factory_) != address(0), "zero");
        factory = factory_;
        wallTreasuryImpl = wallTreasuryImpl_;
        wallStakingImpl = wallStakingImpl_;
        pofVaultImpl = pofVaultImpl_;
        pofRouter = new PoFRouter(address(this));
    }

    function platformOwner() public view returns (address) {
        return factory.owner();
    }

    function setKeeper(address k) external {
        if (msg.sender != platformOwner()) revert NotOwner();
        keeper = k;
        emit KeeperSet(k);
    }

    // ---- standard launch ----

    function launchAndBuy(
        PonsV2LaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 buyAmount,
        uint256 minTokensOut,
        address[] calldata snipeTaxExemptions
    ) external payable nonReentrant returns (address token, address curve, uint256 tokensOut) {
        uint256 fee = _checkValue(pairToken, buyAmount);
        (token, curve) = factory.launchTokenFor{value: fee}(params, launchConfigId, pairToken, msg.sender, snipeTaxExemptions);
        tokensOut = _openingBuy(curve, pairToken, buyAmount, minTokensOut);
        _sweep();
        emit LaunchedAndBought(msg.sender, token, curve, pairToken, buyAmount, tokensOut);
    }

    // ---- template: stock treasury (The Wall) ----

    function predictWall(address creator, bytes32 salt) public view returns (address treasury, address staking) {
        bytes32 s = keccak256(abi.encode(creator, salt, "wall"));
        treasury = Clones1167.predict(wallTreasuryImpl, s, address(this));
        staking = Clones1167.predict(wallStakingImpl, keccak256(abi.encode(s, "staking")), address(this));
    }

    function launchWall(
        PonsV2LaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 buyAmount,
        uint256 minTokensOut,
        address[] calldata snipeTaxExemptions,
        WallTreasury.Config calldata cfg
    ) external payable nonReentrant returns (address token, address curve, address treasury, address staking) {
        uint256 fee = _checkValue(pairToken, buyAmount);
        bytes32 s = keccak256(abi.encode(msg.sender, params.salt, "wall"));
        treasury = Clones1167.clone(wallTreasuryImpl, s);
        staking = Clones1167.clone(wallStakingImpl, keccak256(abi.encode(s, "staking")));

        PonsV2LaunchFactory.TokenParams memory p = params;
        p.creatorFeeRecipient = treasury;
        p.buybackEnabled = false; // the creator share must reach the treasury, not the platform vault
        (token, curve) = factory.launchTokenFor{value: fee}(p, launchConfigId, pairToken, msg.sender, snipeTaxExemptions);

        WallStaking(payable(staking)).initialize(token, pairToken, treasury);
        WallTreasury(payable(treasury)).initialize(
            address(this), token, curve, pairToken, address(factory.feeEscrow()), address(factory.buybackVault()), staking, cfg
        );
        _openingBuy(curve, pairToken, buyAmount, minTokensOut);
        _sweep();
        emit WallLaunched(msg.sender, token, curve, treasury, staking, pairToken);
    }

    // ---- template: Proof-of-Fee ----

    function predictPoF(address creator, bytes32 salt) public view returns (address vault) {
        vault = Clones1167.predict(pofVaultImpl, keccak256(abi.encode(creator, salt, "pof")), address(this));
    }

    function launchPoF(
        PonsV2LaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 buyAmount,
        uint256 minTokensOut,
        address[] calldata snipeTaxExemptions,
        PoFVault.Config calldata cfg
    ) external payable nonReentrant returns (address token, address curve, address vault) {
        uint256 fee = _checkValue(pairToken, buyAmount);
        vault = Clones1167.clone(pofVaultImpl, keccak256(abi.encode(msg.sender, params.salt, "pof")));

        PonsV2LaunchFactory.TokenParams memory p = params;
        p.creatorFeeRecipient = vault;
        p.buybackEnabled = false;
        (token, curve) = factory.launchTokenFor{value: fee}(p, launchConfigId, pairToken, msg.sender, snipeTaxExemptions);

        PoFVault(payable(vault)).initialize(address(this), token, curve, pairToken, address(factory.feeEscrow()), address(pofRouter), cfg);
        pofRouter.register(token, vault, curve, pairToken);

        // The opening buy goes through the official path so it earns Work.
        if (buyAmount > 0) {
            if (pairToken == address(0)) {
                pofRouter.buyFor{value: buyAmount}(token, buyAmount, minTokensOut, msg.sender);
            } else {
                IERC20 quote = IERC20(pairToken);
                quote.safeTransferFrom(msg.sender, address(this), buyAmount);
                quote.forceApprove(address(pofRouter), buyAmount);
                pofRouter.buyFor(token, buyAmount, minTokensOut, msg.sender);
                quote.forceApprove(address(pofRouter), 0);
                uint256 left = quote.balanceOf(address(this));
                if (left > 0) quote.safeTransfer(msg.sender, left);
            }
        }
        _sweep();
        emit PoFLaunched(msg.sender, token, curve, vault, pairToken);
    }

    // ---- internals ----

    function _checkValue(address pairToken, uint256 buyAmount) private view returns (uint256 fee) {
        fee = factory.launchFee();
        uint256 expected = fee + (pairToken == address(0) ? buyAmount : 0);
        if (msg.value != expected) revert BadValue(expected, msg.value);
    }

    function _openingBuy(address curve, address pairToken, uint256 buyAmount, uint256 minTokensOut) private returns (uint256 tokensOut) {
        if (buyAmount == 0) return 0;
        if (pairToken == address(0)) {
            tokensOut = IRadianCurve(curve).buy{value: buyAmount}(buyAmount, minTokensOut, msg.sender);
        } else {
            IERC20 quote = IERC20(pairToken);
            quote.safeTransferFrom(msg.sender, address(this), buyAmount);
            quote.forceApprove(curve, buyAmount);
            tokensOut = IRadianCurve(curve).buy(buyAmount, minTokensOut, msg.sender);
            quote.forceApprove(curve, 0);
            uint256 left = quote.balanceOf(address(this));
            if (left > 0) quote.safeTransfer(msg.sender, left);
        }
    }

    /// @dev A clamped fill refunds the buyer (this contract) — pass it straight on.
    function _sweep() private {
        uint256 dust = address(this).balance;
        if (dust > 0) {
            (bool ok,) = msg.sender.call{value: dust}("");
            if (!ok) revert RefundFailed();
        }
    }

    receive() external payable {}
}
