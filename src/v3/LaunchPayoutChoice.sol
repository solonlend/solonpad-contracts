// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPayoutChoiceHub {
    function stockState(address token) external view returns (bool marketOpen, bool transferable, uint256 version);
    function underlyingOfToken(address token) external view returns (address);
}

/// @title LaunchPayoutChoice — the stock a coin's holders are paid in, chosen by its creator at launch (r7 §12.6)
/// @notice Forked from ArcStocks PayoutChoice (MIT, Arc 5042 0x5C16113b6e2262A2BEc1f8B76D74e92CdB430044, source in
///         arc-launchpad/docs/evidence/v3-stock-rewards/arcstocks-more/payoutChoice): a mapping to the chosen stock,
///         `choose` accepts only a stock the hub lists and trades (there: `getListing(u).enabled`; here the hub's
///         `stockState(token)`, which is the same listing flag minus a trading pause), a `Chosen` event and the
///         batch view `choicesOf`. What changed (2026-10-01: creator-chosen single stock before launch,
///         default NVDA; holder choice is phase 2):
///         - the chooser is the launch factory, once per coin, inside `launch`; the choice can never change;
///         - choices are a governance-approved list (timelock) of single-stock purchase policies (asset, assetId,
///           adapter version, price policy) — no free-form stock, so every choice has a registered adapter route;
///         - id 0 is "the factory default" (NVDA.sol) and is not recorded here.
///         Amounts are never decided here: the coin's holders are credited on-chain per fee as before.
contract LaunchPayoutChoice {
    struct Choice {
        address asset; // the Arc SolonStockToken holders receive
        bytes32 assetId; // StockAdapterRegistry route id
        uint32 version; // adapter version
        bytes32 pricePolicy;
        bool enabled; // new launches only; existing coins keep their choice
    }

    address public immutable governance; // timelock
    IPayoutChoiceHub public immutable hub;
    address public factory;

    Choice[] private _choices; // id = index + 1
    mapping(address token => uint256 id) public choiceOf;

    event FactoryBound(address factory);
    event ChoiceApproved(uint256 indexed id, address indexed asset, bytes32 assetId, uint32 version, bytes32 pricePolicy);
    event ChoiceEnabled(uint256 indexed id, bool enabled);
    event Chosen(address indexed token, uint256 indexed id, address indexed asset);

    error NotGovernance();
    error NotFactory();
    error NotListed(address asset);
    error BadChoice(uint256 id);
    error AlreadyChosen(address token);

    constructor(address governance_, address hub_) {
        require(governance_ != address(0) && hub_ != address(0));
        governance = governance_;
        hub = IPayoutChoiceHub(hub_);
    }

    function bindFactory(address factory_) external {
        if (msg.sender != governance) revert NotGovernance();
        require(factory == address(0) && factory_ != address(0));
        factory = factory_;
        emit FactoryBound(factory_);
    }

    /// @notice Approve a single-stock payout policy. The stock must be listed and trading on the hub.
    function approve(address asset, bytes32 assetId, uint32 version, bytes32 pricePolicy) external returns (uint256 id) {
        if (msg.sender != governance) revert NotGovernance();
        if (assetId == 0 || version == 0 || pricePolicy == 0) revert BadChoice(0);
        _requireListed(asset);
        _choices.push(Choice(asset, assetId, version, pricePolicy, true));
        id = _choices.length;
        emit ChoiceApproved(id, asset, assetId, version, pricePolicy);
    }

    function setEnabled(uint256 id, bool enabled) external {
        if (msg.sender != governance) revert NotGovernance();
        if (id == 0 || id > _choices.length) revert BadChoice(id);
        _choices[id - 1].enabled = enabled;
        emit ChoiceEnabled(id, enabled);
    }

    /// @notice Launch factory only: record `token`'s payout stock for good. Reverts on a disabled/unknown id or a
    ///         stock the hub no longer trades, so the launch fails instead of silently falling back.
    function choose(address token, uint256 id) external returns (Choice memory c) {
        if (msg.sender != factory) revert NotFactory();
        if (id == 0 || id > _choices.length) revert BadChoice(id);
        if (choiceOf[token] != 0) revert AlreadyChosen(token);
        c = _choices[id - 1];
        if (!c.enabled) revert BadChoice(id);
        _requireListed(c.asset);
        choiceOf[token] = id;
        emit Chosen(token, id, c.asset);
    }

    function choice(uint256 id) external view returns (Choice memory) {
        if (id == 0 || id > _choices.length) revert BadChoice(id);
        return _choices[id - 1];
    }

    function choiceCount() external view returns (uint256) {
        return _choices.length;
    }

    /// @notice Many coins' payout stocks at once (0 / address(0) = the factory default).
    function choicesOf(address[] calldata tokens) external view returns (uint256[] memory ids, address[] memory assets) {
        ids = new uint256[](tokens.length);
        assets = new address[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            ids[i] = choiceOf[tokens[i]];
            if (ids[i] != 0) assets[i] = _choices[ids[i] - 1].asset;
        }
    }

    function _requireListed(address asset) private view {
        (bool open,,) = hub.stockState(asset);
        if (!open) revert NotListed(asset);
    }
}
