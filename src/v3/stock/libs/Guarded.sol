// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Guarded — a circuit breaker with two hands
/// @notice Forked from ArcStocks v2 `src/v2/libs/Guarded.sol` (MIT). The guardian (a Safe with no
///         delay) can stop new inflows at once; only the owner (a timelock) can start them again.
///         Outflows — redemptions, deliveries, claims — never sit behind `whenNotPaused`, so a pause
///         can only ever slow growth, never trap holders.
/// @dev Solon change: the OpenZeppelin `Pausable` base is inlined (same storage flag, same
///      `Paused`/`Unpaused` events and `EnforcedPause` error) because the repository's OpenZeppelin
///      copy does not ship it and a second OpenZeppelin tree would duplicate `Context`.
abstract contract Guarded {
    address public guardian;
    bool private _paused;

    event GuardianSet(address guardian);
    event Paused(address account);
    event Unpaused(address account);

    error NotGuardian();
    error NotOwnerOfGuard();
    error EnforcedPause();
    error ExpectedPause();

    modifier whenNotPaused() {
        if (_paused) revert EnforcedPause();
        _;
    }

    function paused() public view returns (bool) {
        return _paused;
    }

    function pause() external {
        if (msg.sender != guardian && msg.sender != _guardOwner()) revert NotGuardian();
        if (_paused) revert EnforcedPause();
        _paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external {
        if (msg.sender != _guardOwner()) revert NotOwnerOfGuard();
        if (!_paused) revert ExpectedPause();
        _paused = false;
        emit Unpaused(msg.sender);
    }

    function setGuardian(address guardian_) external {
        if (msg.sender != _guardOwner()) revert NotOwnerOfGuard();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    /// @dev The account that can unpause and reassign the guardian: the timelock.
    function _guardOwner() internal view virtual returns (address);
}
