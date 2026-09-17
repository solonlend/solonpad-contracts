// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20Minimal {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IFactoryView {
    function treasury() external view returns (address);
}

/// @title CurvePool
/// @notice Constant-product bonding curve quoted in Arc's NATIVE USDC.
///
///         Arc uses USDC as the native gas token; `msg.value` is denominated in
///         18-decimal native units (the 6-decimal figure is only the optional
///         ERC-20 display interface at 0x3600...0000 — same underlying balance).
///         All amounts in this contract are 18-decimal native USDC.
///
///         Pricing: virtual + real USDC reserve vs. token reserve, x*y=k.
///         The virtual reserve bootstraps the initial price without seed capital.
///         Liquidity is locked forever: nothing can withdraw reserve USDC or
///         reserve tokens — only accrued trading fees are claimable, and only
///         by the creator and the protocol treasury.
contract CurvePool {
    // ---- immutable config (set at launch, cannot be changed by anyone) ----
    address public immutable factory;
    address public immutable creator;
    uint256 public immutable virtualUsdc; // 18-dec native units
    uint256 public immutable graduationReserve; // real reserve that triggers graduation
    uint16 public immutable feeBps; // fee on each trade, e.g. 100 = 1%
    uint16 public immutable creatorShareBps; // creator's share of the fee, e.g. 5000 = 50%

    IERC20Minimal public token;

    // ---- state ----
    uint256 public realUsdc; // net USDC backing the curve (excludes fees)
    uint256 public tokenReserve; // tokens held by the curve
    uint256 public creatorFees; // claimable by creator
    uint256 public protocolFees; // claimable by factory.treasury()
    bool public graduated;

    uint256 private _lock = 1;

    event Buy(address indexed buyer, uint256 usdcIn, uint256 tokensOut, uint256 realUsdc, uint256 tokenReserve);
    event Sell(address indexed seller, uint256 tokensIn, uint256 usdcOut, uint256 realUsdc, uint256 tokenReserve);
    event Graduated(uint256 realUsdc, uint256 tokenReserve);
    event CreatorFeesClaimed(address indexed creator, uint256 amount);
    event ProtocolFeesClaimed(address indexed treasury, uint256 amount);

    modifier nonReentrant() {
        require(_lock == 1, "reentrancy");
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(
        address creator_,
        uint256 virtualUsdc_,
        uint256 graduationReserve_,
        uint16 feeBps_,
        uint16 creatorShareBps_
    ) {
        require(virtualUsdc_ > 0, "virtual reserve = 0");
        require(feeBps_ <= 1000, "fee > 10%");
        require(creatorShareBps_ <= 10_000, "creator share > 100%");
        factory = msg.sender;
        creator = creator_;
        virtualUsdc = virtualUsdc_;
        graduationReserve = graduationReserve_;
        feeBps = feeBps_;
        creatorShareBps = creatorShareBps_;
    }

    /// @notice Called once by the factory in the same transaction as deployment,
    ///         after the token has minted its full supply to this pool.
    function initialize(address token_) external {
        require(msg.sender == factory, "only factory");
        require(address(token) == address(0), "initialized");
        token = IERC20Minimal(token_);
        tokenReserve = token.balanceOf(address(this));
        require(tokenReserve > 0, "no supply");
    }

    // ---- trading ----

    /// @notice Buy tokens with native USDC (send as msg.value).
    function buy(uint256 minTokensOut, uint256 deadline) external payable nonReentrant returns (uint256 tokensOut) {
        require(block.timestamp <= deadline, "expired");
        require(msg.value > 0, "zero in");

        uint256 fee = (msg.value * feeBps) / 10_000;
        uint256 netIn = msg.value - fee;
        tokensOut = quoteBuy(netIn);
        require(tokensOut > 0 && tokensOut >= minTokensOut, "slippage");

        realUsdc += netIn;
        tokenReserve -= tokensOut;
        _accrueFee(fee);

        require(token.transfer(msg.sender, tokensOut), "token transfer failed");
        emit Buy(msg.sender, msg.value, tokensOut, realUsdc, tokenReserve);

        if (!graduated && realUsdc >= graduationReserve) {
            graduated = true;
            emit Graduated(realUsdc, tokenReserve);
        }
    }

    /// @notice Sell tokens back to the curve for native USDC. Requires prior approve().
    function sell(uint256 tokensIn, uint256 minUsdcOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 usdcOut)
    {
        require(block.timestamp <= deadline, "expired");
        require(tokensIn > 0, "zero in");

        uint256 gross = quoteSellGross(tokensIn);
        // Path-independence of x*y=k guarantees gross <= realUsdc up to rounding;
        // the explicit check makes draining the virtual reserve impossible.
        require(gross <= realUsdc, "exceeds real reserve");
        uint256 fee = (gross * feeBps) / 10_000;
        usdcOut = gross - fee;
        require(usdcOut >= minUsdcOut, "slippage");

        realUsdc -= gross;
        tokenReserve += tokensIn;
        _accrueFee(fee);

        require(token.transferFrom(msg.sender, address(this), tokensIn), "token pull failed");
        (bool ok,) = msg.sender.call{value: usdcOut}("");
        require(ok, "usdc send failed");
        emit Sell(msg.sender, tokensIn, usdcOut, realUsdc, tokenReserve);
    }

    // ---- fee claims (pull pattern) ----

    function claimCreatorFees() external nonReentrant {
        require(msg.sender == creator, "only creator");
        uint256 amount = creatorFees;
        require(amount > 0, "nothing to claim");
        creatorFees = 0;
        (bool ok,) = creator.call{value: amount}("");
        require(ok, "send failed");
        emit CreatorFeesClaimed(creator, amount);
    }

    function claimProtocolFees() external nonReentrant {
        address treasury = IFactoryView(factory).treasury();
        require(msg.sender == treasury, "only treasury");
        uint256 amount = protocolFees;
        require(amount > 0, "nothing to claim");
        protocolFees = 0;
        (bool ok,) = treasury.call{value: amount}("");
        require(ok, "send failed");
        emit ProtocolFeesClaimed(treasury, amount);
    }

    // ---- views ----

    /// @notice Tokens out for a given NET USDC input (fee already deducted).
    function quoteBuy(uint256 netUsdcIn) public view returns (uint256) {
        uint256 x = virtualUsdc + realUsdc;
        return (tokenReserve * netUsdcIn) / (x + netUsdcIn);
    }

    /// @notice Gross USDC out (before fee) for a given token input.
    function quoteSellGross(uint256 tokensIn) public view returns (uint256) {
        uint256 x = virtualUsdc + realUsdc;
        return (x * tokensIn) / (tokenReserve + tokensIn);
    }

    /// @notice Spot price in native USDC (18 dec) per whole token (1e18 units).
    function spotPrice() external view returns (uint256) {
        return ((virtualUsdc + realUsdc) * 1e18) / tokenReserve;
    }

    function _accrueFee(uint256 fee) internal {
        if (fee == 0) return;
        uint256 toCreator = (fee * creatorShareBps) / 10_000;
        creatorFees += toCreator;
        protocolFees += fee - toCreator;
    }
}
