// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IV2StakingBudget {
    function notifyV2Budget(bytes32 id, uint256 amount) external payable;
}

interface IV2BuybackBudget {
    function fundV2(bytes32 id, bool protocolDesk) external payable;
}

interface IV2ConverterBinding {
    function router() external view returns (address);
    function sellRoute() external view returns (address);
}

interface IV2RouteAsset {
    function asset() external view returns (address);
}

interface IV2FeeConversion {
    function convert(bytes32 id, address token, uint256 amount, bytes calldata quoteData) external returns (uint256);
}

/// @notice Immutable platform-only policies. Native USDC rights vest during fundLot; raw fees only after actual conversion.
contract V2PlatformRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public constant SOLON = 0xd36687146385F7Dc84A18FEA3D00319d39D6d1a0;
    address public immutable governance;
    address public immutable ingress;
    address public immutable staking;
    address public immutable buyback;
    address public immutable burnSink;
    address public converter;
    mapping(bytes32 => uint8) public state;

    struct Pending {
        address token;
        uint256 raw;
        uint8 kind;
    }
    mapping(bytes32 => Pending) public pending;
    mapping(address => uint256) public rawLiability;
    event RawFunded(bytes32 indexed lot, address token, uint256 raw, uint8 kind);
    event FeeTokenBurned(bytes32 indexed lot, uint256 actualRaw);
    event Converted(bytes32 indexed lot, uint256 actualUSDC18, uint8 kind);

    constructor(address gov, address i, address s, address b, address sink) {
        require(gov != address(0) && i != address(0) && s != address(0) && b != address(0) && sink != address(0));
        governance = gov;
        ingress = i;
        staking = s;
        buyback = b;
        burnSink = sink;
    }

    receive() external payable {
        require(msg.sender == converter || registeredConverter[msg.sender]);
    }

    function setConverter(address c) external {
        require(msg.sender == governance && converter == address(0) && c.code.length != 0);
        converter = c;
    }

    function onFunded(bytes32 id, uint8 kind, address token, uint256 amount) external payable nonReentrant {
        require(msg.sender == ingress && state[id] == 0 && amount != 0 && (kind == 1 || kind == 2));
        if (token == address(0)) {
            require(amount == msg.value);
            state[id] = 4;
            _nativePolicy(id, kind, amount);
        } else {
            require(msg.value == 0 && (kind != 1 || token == SOLON));
            require(IERC20(token).balanceOf(address(this)) >= rawLiability[token] + amount);
            rawLiability[token] += amount;
            state[id] = 1;
            pending[id] = Pending(token, amount, kind);
            emit RawFunded(id, token, amount, kind);
        }
    }

    function _nativePolicy(bytes32 id, uint8 kind, uint256 amount) private {
        if (kind == 1) {
            uint256 stockBudget = _stockHalf(address(0), amount);
            if (stockBudget != 0) IV2StakingBudget(staking).notifyV2Budget{value: stockBudget}(id, stockBudget);
            if (amount > stockBudget) IV2BuybackBudget(buyback).fundV2{value: amount - stockBudget}(id, false);
        } else {
            IV2BuybackBudget(buyback).fundV2{value: amount}(id, true);
        }
    }

    function routeLot(bytes32 id) external nonReentrant {
        require(state[id] == 1);
        Pending storage p = pending[id];
        state[id] = 2;
        if (p.kind == 1) {
            uint256 stock = _stockHalf(p.token, p.raw);
            uint256 burn = p.raw - stock;
            p.raw = stock;
            rawLiability[p.token] -= burn;
            IERC20 token = IERC20(p.token);
            uint256 beforeSelf = token.balanceOf(address(this));
            uint256 beforeSink = token.balanceOf(burnSink);
            token.safeTransfer(burnSink, burn);
            require(
                token.balanceOf(address(this)) == beforeSelf - burn && token.balanceOf(burnSink) == beforeSink + burn
            );
            emit FeeTokenBurned(id, burn);
            if (stock == 0) state[id] = 4;
        }
    }
    mapping(bytes32 => uint256) public conversionCount;
    mapping(bytes32 => bytes32) public conversionParent;
    event ConversionSlice(bytes32 indexed sourceLot, bytes32 indexed conversionId, uint256 raw, uint256 residual);

    function nextConversionId(bytes32 id) public view returns (bytes32) {
        return conversionCount[id] == 0 ? id : keccak256(abi.encode("V2ConversionSlice", id, conversionCount[id]));
    }

    function convertLot(bytes32 id, bytes calldata quoteData) external nonReentrant {
        _convertLot(id, pending[id].raw, quoteData);
    }

    function convertLot(bytes32 id, uint256 raw, bytes calldata quoteData) external nonReentrant {
        _convertLot(id, raw, quoteData);
    }

    function _convertLot(bytes32 id, uint256 raw, bytes calldata quoteData) private {
        require(state[id] == 2);
        Pending storage p = pending[id];
        address selected = assetConverter[p.token];
        if (selected == address(0)) selected = converter;
        require(selected != address(0));
        require(raw != 0 && raw <= p.raw);
        state[id] = 3;
        bytes32 slice = nextConversionId(id);
        conversionCount[id]++;
        conversionParent[slice] = id;
        IERC20 token = IERC20(p.token);
        uint256 beforeRaw = token.balanceOf(address(this));
        uint256 beforeNative = address(this).balance;
        token.forceApprove(selected, raw);
        uint256 actual = IV2FeeConversion(selected).convert(slice, p.token, raw, quoteData);
        token.forceApprove(selected, 0);
        require(
            actual != 0 && address(this).balance == beforeNative + actual
                && token.balanceOf(address(this)) == beforeRaw - raw
        );
        rawLiability[p.token] -= raw;
        p.raw -= raw;
        state[id] = p.raw == 0 ? 4 : 2;
        if (p.kind == 1) IV2StakingBudget(staking).notifyV2Budget{value: actual}(slice, actual);
        else IV2BuybackBudget(buyback).fundV2{value: actual}(slice, true);
        emit ConversionSlice(id, slice, raw, p.raw);
        emit Converted(slice, actual, p.kind);
    }
    mapping(address => uint8) public halfRemainder;

    function _stockHalf(address asset, uint256 amount) private returns (uint256 stock) {
        uint256 fraction = (amount % 2) + halfRemainder[asset];
        stock = amount / 2 + fraction / 2;
        halfRemainder[asset] = uint8(fraction % 2);
    }
    mapping(address => address) public assetConverter;
    mapping(address => bool) public registeredConverter;
    mapping(bytes32 => uint256) public converterActivation;
    event AssetConverterScheduled(address indexed asset, address indexed converter, uint256 executableAt);
    event AssetConverterActivated(address indexed asset, address indexed converter);

    function _checkConverter(address token, address c) private view {
        require(token.code.length != 0 && c.code.length != 0 && assetConverter[token] == address(0));
        require(IV2ConverterBinding(c).router() == address(this));
        require(IV2RouteAsset(IV2ConverterBinding(c).sellRoute()).asset() == token);
    }

    function scheduleAssetConverter(address token, address c) external {
        require(msg.sender == governance);
        _checkConverter(token, c);
        uint256 at = block.timestamp + 48 hours;
        converterActivation[keccak256(abi.encode(token, c))] = at;
        emit AssetConverterScheduled(token, c, at);
    }

    function activateAssetConverter(address token, address c) external {
        bytes32 id = keccak256(abi.encode(token, c));
        uint256 at = converterActivation[id];
        require(at != 0 && block.timestamp >= at);
        _checkConverter(token, c);
        delete converterActivation[id];
        assetConverter[token] = c;
        registeredConverter[c] = true;
        emit AssetConverterActivated(token, c);
    }
}
