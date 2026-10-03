// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Bought SOLON can only move to the immutable no-exit sink.
contract BuybackVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable solon;
    address public immutable sink;
    address public immutable executor;
    enum State {
        None,
        BurnPending,
        Burned
    }

    struct Lot {
        uint256 amount;
        State state;
    }
    mapping(bytes32 => Lot) public lots;
    uint256 public totalPending;
    uint256 public totalBurned;
    event Bought(bytes32 indexed lotId, uint256 amount);
    event Burned(bytes32 indexed lotId, uint256 amount);
    event BurnDeferred(bytes32 indexed lotId);

    constructor(address token_, address sink_, address executor_) {
        require(token_.code.length != 0 && sink_.code.length != 0 && executor_ != address(0));
        solon = IERC20(token_);
        sink = sink_;
        executor = executor_;
    }

    function depositBuyback(bytes32 id, uint256 amount) external nonReentrant {
        require(msg.sender == executor && id != 0 && amount != 0 && lots[id].state == State.None, "Invalid lot");
        uint256 beforeBalance = solon.balanceOf(address(this));
        solon.safeTransferFrom(msg.sender, address(this), amount);
        require(solon.balanceOf(address(this)) == beforeBalance + amount, "Inexact receipt");
        lots[id] = Lot(amount, State.BurnPending);
        totalPending += amount;
        emit Bought(id, amount);
    }

    function burnPending(bytes32 id) external nonReentrant returns (bool) {
        Lot storage l = lots[id];
        require(l.state == State.BurnPending, "Not pending");
        try this.deliverToSink(l.amount) {
            l.state = State.Burned;
            totalPending -= l.amount;
            totalBurned += l.amount;
            emit Burned(id, l.amount);
            return true;
        } catch {
            emit BurnDeferred(id);
            return false;
        }
    }

    function deliverToSink(uint256 amount) external {
        require(msg.sender == address(this), "Self only");
        uint256 beforeSink = solon.balanceOf(sink);
        uint256 beforeSelf = solon.balanceOf(address(this));
        solon.safeTransfer(sink, amount);
        require(
            solon.balanceOf(sink) == beforeSink + amount && solon.balanceOf(address(this)) == beforeSelf - amount,
            "Inexact burn"
        );
    }
}
