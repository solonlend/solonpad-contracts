// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {V3LaunchFactory, IV3CreatorRights} from "../V3LaunchFactory.sol";
import {V3QuoteFeeHook} from "../V3QuoteFeeHook.sol";
import {EligibilityController} from "../EligibilityController.sol";
import {SolonStakingV2} from "../SolonStakingV2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Linked, immutable legacy admission logic; governance is the deployment's
/// published multisig, with an additional non-bypassable 48-hour per-registration delay.
library V3LegacyPools {
    struct State {
        mapping(address => bytes32) tokenCodeHash;
        mapping(bytes32 => uint256) readyAt;
    }

    struct Request {
        address token;
        address quote;
        address holderSink;
        address creatorRights;
        uint160 price;
    }
    error InvalidLegacyPool();
    event LegacyTokenWhitelisted(address indexed token, bytes32 codeHash);
    event LegacyPoolScheduled(bytes32 indexed action, uint256 readyAt);
    event LegacyPoolRegistered(bytes32 indexed pool, address indexed token, address indexed holderSink);

    function _governor(address controller) private view returns (address governor) {
        if (controller == address(0)) revert InvalidLegacyPool();
        governor = EligibilityController(controller).governance();
        if (msg.sender != governor) revert InvalidLegacyPool();
    }

    function whitelist(State storage s, address controller, address token) external {
        _governor(controller);
        if (token.code.length == 0 || s.tokenCodeHash[token] != 0) revert InvalidLegacyPool();
        s.tokenCodeHash[token] = token.codehash;
        emit LegacyTokenWhitelisted(token, token.codehash);
    }

    function schedule(State storage s, address controller, bytes32 action) external {
        _governor(controller);
        if (action == 0) revert InvalidLegacyPool();
        s.readyAt[action] = block.timestamp + 48 hours;
        emit LegacyPoolScheduled(action, s.readyAt[action]);
    }

    function register(
        State storage s,
        V3LaunchFactory.Components memory c,
        address controller,
        address converter,
        Request memory r,
        bytes32 action
    ) external returns (bytes32 pool) {
        address governor = _governor(controller);
        if (
            s.readyAt[action] == 0 || block.timestamp < s.readyAt[action] || s.tokenCodeHash[r.token] == 0
                || r.token.codehash != s.tokenCodeHash[r.token] || r.holderSink != c.modules[1]
                || r.creatorRights != governor || converter == address(0) || r.token == r.quote
                || r.price < TickMath.MIN_SQRT_PRICE || r.price >= TickMath.MAX_SQRT_PRICE
        ) {
            revert InvalidLegacyPool();
        }
        SolonStakingV2 sink = SolonStakingV2(payable(r.holderSink));
        if (address(sink.solon()) != r.token || sink.ledger() != address(c.ledger)) revert InvalidLegacyPool();
        delete s.readyAt[action];
        bool quote0 = r.quote < r.token;
        PoolKey memory key = PoolKey(
            Currency.wrap(quote0 ? r.quote : r.token),
            Currency.wrap(quote0 ? r.token : r.quote),
            0,
            100,
            IHooks(address(c.hook))
        );
        pool = PoolId.unwrap(key.toId());
        address[6] memory beneficiaries = [r.holderSink, c.rights, c.modules[0], c.modules[1], converter, converter];
        c.ledger.registerLegacyPool(pool, r.quote, address(c.hook), beneficiaries);
        c.hook
            .registerLegacyPool(
                key,
                V3QuoteFeeHook.PoolRegistration(
                    r.token, r.quote, 1, r.token.codehash, governor, address(c.positions), r.price, bytes32(uint256(1))
                )
            );
        IV3CreatorRights(c.rights).mint(pool, governor);
        emit LegacyPoolRegistered(pool, r.token, r.holderSink);
    }
}
