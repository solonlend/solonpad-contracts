// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {DeskRewards, DeskRewardEntry} from "../../../../src/v3/DeskRewards.sol";
import {DeskNFT} from "../../../../src/v3/DeskNFT.sol";
import {V3FeeLedger} from "../../../../src/v3/V3FeeLedger.sol";
import {RewardRoundManager} from "../../../../src/v3/RewardRoundManager.sol";
import {CovCToken, CovCMockLedger} from "./CovCMocks.sol";

/// @notice Minimal DeskNFT surface used by DeskRewards (supply, protocol count, owners, controller).
contract CovCRwNFT {
    uint256 public totalSupply;
    uint256 public protocolMinted;
    address public solon;
    address public controller;
    mapping(uint256 => address) internal owners;

    constructor(address s) {
        solon = s;
    }

    function setSupply(uint256 n, uint256 np) external {
        totalSupply = n;
        protocolMinted = np;
    }

    function setController(address c) external {
        controller = c;
    }

    function setOwner(uint256 id, address o) external {
        owners[id] = o;
    }

    function ownerOf(uint256 id) external view returns (address o) {
        o = owners[id];
        require(o != address(0), "nonexistent");
    }

    function callPay(DeskRewards r, uint256 id, bytes32[] calldata keys, address owner) external returns (uint256) {
        return r.pay(id, keys, owner);
    }

    function callSurcharge(DeskRewards r) external payable {
        r.recordMintSurcharge{value: msg.value}();
    }
}

contract CovCRwController {
    address public registry;
    bool public eligibilityEnabled;
    uint256 public effectiveEpoch;
    bool public allow = true;

    constructor(address r) {
        registry = r;
    }

    function setAllow(bool a) external {
        allow = a;
    }

    function setMode(bool on, uint256 e) external {
        eligibilityEnabled = on;
        effectiveEpoch = e;
    }

    function canReceiveStock(address, address) external view returns (bool) {
        return allow;
    }
}

contract CovCRwVault {
    address public asset;

    function setAsset(address a) external {
        asset = a;
    }

    function queueAsset(uint256) external view returns (address) {
        return asset;
    }
}

contract CovCRwRounds {
    CovCRwVault public vault;
    mapping(uint256 => RewardRoundManager.Entry) internal entries;
    mapping(uint256 => uint256) public delivered;
    bool public rejects;
    uint256 public registered;

    constructor() {
        vault = new CovCRwVault();
    }

    function setEntry(uint256 id, RewardRoundManager.Entry memory e) external {
        entries[id] = e;
    }

    function setDelivered(uint256 id, uint256 v) external {
        delivered[id] = v;
    }

    function setRejects(bool r) external {
        rejects = r;
    }

    function entry(uint256 id) external view returns (RewardRoundManager.Entry memory) {
        return entries[id];
    }

    function registerSource(address, bytes32) external {
        registered++;
    }

    receive() external payable {
        require(!rejects, "rounds rejects");
    }
}

contract CovCRwPayout {
    function stageCredit(address, address, uint256[] calldata, address) external pure returns (uint256) {
        return 0;
    }

    function claimFor(address, address) external pure returns (uint256) {
        return 0;
    }

    function paidTotal(address, address) external pure returns (uint256) {
        return 0;
    }
}

contract CovCRwSchedule {
    function resolve(uint256) external pure returns (address, bytes32, uint32, bytes32) {
        return (address(0xA55E7), bytes32("asset"), 3, bytes32("price"));
    }
}

contract CovCRwStaking {
    uint256 public short;
    bool public reenter;
    uint256 public notified;

    function setShort(uint256 s) external {
        short = s;
    }

    function setReenter(bool r) external {
        reenter = r;
    }

    function notifyProtocolDeskCredit(bytes32, uint256, address, uint8, uint256 c) external returns (uint256) {
        notified += c;
        return c;
    }

    function fundProtocolDesk(bytes32, uint256, address asset, uint8 kind, uint256 amount) external payable {
        if (kind == 1) CovCToken(asset).transferFrom(msg.sender, address(this), amount - short);
        if (reenter) {
            (bool ok, bytes memory ret) = msg.sender.call{value: msg.value}("");
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

contract CovCDeskRewardsTest is Test {
    CovCMockLedger ml;
    DeskRewards rewards;
    CovCRwNFT nft;
    CovCToken solon;
    CovCToken stockA;
    CovCRwStaking staking;
    address alice = address(0xA11CE);

    function setUp() public {
        vm.warp(100 days);
        ml = new CovCMockLedger();
        rewards = new DeskRewards(V3FeeLedger(payable(address(ml))), address(this));
        solon = new CovCToken();
        stockA = new CovCToken();
        nft = new CovCRwNFT(address(solon));
        rewards.configureNFT(DeskNFT(address(nft)));
        staking = new CovCRwStaking();
        vm.deal(address(this), 1000 ether);
        vm.deal(address(ml), 1000 ether);
    }

    function _epoch() internal view returns (uint256) {
        return vm.getBlockTimestamp() / 1 days;
    }

    function _royaltyAsset() internal {
        address[] memory a = new address[](1);
        a[0] = address(stockA);
        rewards.configureRoyaltyAssets(a);
        stockA.mint(address(this), 1000);
        stockA.approve(address(rewards), type(uint256).max);
    }

    function _nativePool(bytes32 p) internal {
        address[6] memory b;
        b[2] = address(rewards);
        ml.setPool(p, address(0), 0, address(1), b);
    }

    function _stockPool(bytes32 p) internal {
        address[6] memory b;
        b[2] = address(rewards);
        ml.setPool(p, address(stockA), 1, address(1), b);
    }

    // ---------------------------------------------------------------- royalty assets

    /// L25 false arm (every conjunct) and L33 false arm (every conjunct).
    function test_ConfigureRoyaltyAssetsGuards() public {
        address[] memory a = new address[](1);
        a[0] = address(stockA);
        DeskRewards bare = new DeskRewards(V3FeeLedger(payable(address(ml))), address(this));
        vm.expectRevert(bytes("royalty configuration"));
        bare.configureRoyaltyAssets(a); // nft not configured
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("royalty configuration"));
        rewards.configureRoyaltyAssets(a);
        nft.setSupply(1, 0);
        vm.expectRevert(bytes("royalty configuration"));
        rewards.configureRoyaltyAssets(a);
        nft.setSupply(0, 0);
        a[0] = address(0x1234);
        vm.expectRevert(bytes("stock royalty asset"));
        rewards.configureRoyaltyAssets(a);
        a[0] = address(solon);
        vm.expectRevert(bytes("stock royalty asset"));
        rewards.configureRoyaltyAssets(a);
        address[] memory dup = new address[](2);
        dup[0] = address(stockA);
        dup[1] = address(stockA);
        vm.expectRevert(bytes("stock royalty asset"));
        rewards.configureRoyaltyAssets(dup);
        assertFalse(rewards.royaltyAssetsConfigured());
        a[0] = address(stockA);
        rewards.configureRoyaltyAssets(a);
        assertTrue(rewards.royaltyAsset(address(stockA)));
        vm.expectRevert(bytes("royalty configuration"));
        rewards.configureRoyaltyAssets(a);
    }

    /// L47 false arm (short receipt / extra payer debit) and the equal-split credit on success.
    function test_DepositRoyaltyDelta() public {
        _royaltyAsset();
        nft.setSupply(2, 0);
        nft.setOwner(1, alice);
        vm.expectRevert(bytes("stock royalty asset"));
        rewards.depositRoyalty(address(stockA), 0);
        vm.expectRevert(bytes("stock royalty asset"));
        rewards.depositRoyalty(address(solon), 1);
        stockA.setShortFrom(address(this));
        vm.expectRevert(bytes("royalty delta"));
        rewards.depositRoyalty(address(stockA), 10);
        stockA.setShortFrom(address(0));
        stockA.setExtraFrom(address(this));
        vm.expectRevert(bytes("royalty delta"));
        rewards.depositRoyalty(address(stockA), 10);
        stockA.setExtraFrom(address(0));
        rewards.depositRoyalty(address(stockA), 10);
        assertEq(rewards.rawCustody(address(stockA)), 10);
        bytes32 key = rewards.streamKey(rewards.ROYALTY(), _epoch(), address(stockA), 1);
        assertEq(rewards.claimable(1, key), 5);
    }

    /// L59 both arms; L63 both arms (new inventory credited once, nothing on re-sync).
    function test_SyncRoyalty() public {
        _royaltyAsset();
        nft.setSupply(1, 0);
        vm.expectRevert(bytes("stock royalty asset"));
        rewards.syncRoyalty(address(solon));
        stockA.transfer(address(rewards), 7);
        assertEq(rewards.syncRoyalty(address(stockA)), 7);
        assertEq(rewards.syncRoyalty(address(stockA)), 0);
        assertEq(rewards.rawCustody(address(stockA)), 7);
    }

    // ---------------------------------------------------------------- credit paths

    /// L233 both arms; L249 true arm (zero amount is a no-op); L251 both arms.
    function test_RecordMintSurchargeGuards() public {
        vm.expectRevert(bytes("nft"));
        rewards.recordMintSurcharge{value: 1 ether}();
        bytes32 key = rewards.streamKey(rewards.SURCHARGE(), _epoch(), address(0), 0);
        nft.callSurcharge{value: 0}(rewards);
        (,,,,,, uint256 supply,,) = rewards.streams(key);
        assertEq(supply, 0);
        vm.expectRevert(bytes("first Desk required"));
        nft.callSurcharge{value: 1 ether}(rewards);
        nft.setSupply(2, 0);
        nft.callSurcharge{value: 1 ether}(rewards);
        (,,,,,, uint256 s2, uint256 total, uint256 received) = rewards.streams(key);
        assertEq(s2, 2);
        assertEq(total, 1e45);
        assertEq(received, 1 ether);
        assertEq(address(rewards).balance, 1 ether);
    }

    /// L238 both arms; L240 false arm.
    function test_OnFeeCreditAuth() public {
        bytes32 p = keccak256("pool");
        _nativePool(p);
        nft.setSupply(1, 0);
        vm.expectRevert(bytes("ledger"));
        rewards.onFeeCredit(p, address(0), 0, 1 ether);
        vm.startPrank(address(ml));
        vm.expectRevert(bytes("source"));
        rewards.onFeeCredit(p, address(stockA), 0, 1 ether); // quote mismatch
        vm.expectRevert(bytes("source"));
        rewards.onFeeCredit(p, address(0), 1, 1 ether); // kind mismatch
        vm.expectRevert(bytes("source"));
        rewards.onFeeCredit(keccak256("other"), address(0), 0, 1 ether); // not bucket-2 beneficiary
        rewards.onFeeCredit(p, address(0), 0, 1 ether);
        vm.stopPrank();
        bytes32 key = rewards.streamKey(p, _epoch(), address(0), 0);
        assertEq(rewards.streamCreditTotal(key), 1e45);
    }

    /// L286 both arms: protocol cards require the fixed protocol staking sink.
    function test_ProtocolStakingRequired() public {
        nft.setSupply(2, 1);
        vm.expectRevert(bytes("protocol staking missing"));
        nft.callSurcharge{value: 1 ether}(rewards);
        rewards.configureProtocolStaking(address(staking));
        nft.callSurcharge{value: 1 ether}(rewards);
        bytes32 key = rewards.streamKey(rewards.SURCHARGE(), _epoch(), address(0), 0);
        assertEq(rewards.delegatedCredit27(key), 5e44);
        assertEq(staking.notified(), 5e44);
        assertEq(rewards.streamCreditTotal(key), 5e44);
    }

    // ---------------------------------------------------------------- delivery

    function _kind1Stream() internal returns (bytes32 key) {
        _royaltyAsset();
        nft.setSupply(1, 0);
        nft.setOwner(1, alice);
        rewards.depositRoyalty(address(stockA), 10);
        key = rewards.streamKey(rewards.ROYALTY(), _epoch(), address(stockA), 1);
    }

    /// L309 / L319 / L335 false arms, then exact delivery and the zero-amount continue.
    function test_PayGuards() public {
        bytes32 key = _kind1Stream();
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.expectRevert(bytes("claim"));
        rewards.pay(1, keys, alice);
        vm.expectRevert(bytes("claim"));
        nft.callPay(rewards, 1, keys, address(0xB0B));
        bytes32[] memory many = new bytes32[](21);
        vm.expectRevert(bytes("claim"));
        nft.callPay(rewards, 1, many, alice);
        CovCRwController ctl = new CovCRwController(address(this));
        nft.setController(address(ctl));
        ctl.setAllow(false);
        vm.expectRevert(bytes("delivery eligibility"));
        nft.callPay(rewards, 1, keys, alice);
        ctl.setAllow(true);
        stockA.setShortFrom(address(rewards));
        vm.expectRevert(bytes("delivery delta"));
        nft.callPay(rewards, 1, keys, alice);
        stockA.setShortFrom(address(0));
        assertEq(nft.callPay(rewards, 1, keys, alice), 10);
        assertEq(stockA.balanceOf(alice), 10);
        assertEq(rewards.rawCustody(address(stockA)), 0);
        assertEq(rewards.paidRaw(1, key), 10);
        assertEq(nft.callPay(rewards, 1, keys, alice), 0);
    }

    /// L349 false arm; L352 both arms (native); kind-1 ledger pull adds raw custody (L348/L351/L353).
    function test_LedgerPullGuards() public {
        bytes32 p = keccak256("native");
        _nativePool(p);
        nft.setSupply(2, 1);
        rewards.configureProtocolStaking(address(staking));
        vm.prank(address(ml));
        rewards.onFeeCredit(p, address(0), 0, 10 ether);
        ml.setAccrued(p, 2, 10 ether);
        bytes32 key = rewards.streamKey(p, _epoch(), address(0), 0);
        ml.setClaimBehaviour(false, 0, 0);
        vm.expectRevert(bytes("ledger pull"));
        rewards.fundProtocolDeskBudget(key);
        ml.setClaimBehaviour(true, 1, 0);
        vm.expectRevert(bytes("ledger delta"));
        rewards.fundProtocolDeskBudget(key);
        ml.setClaimBehaviour(true, 0, 0);
        assertEq(rewards.fundProtocolDeskBudget(key), 5 ether);
        assertEq(address(staking).balance, 5 ether);
        assertEq(address(rewards).balance, 5 ether);
        assertEq(rewards.fundProtocolDeskBudget(key), 0);

        bytes32 q = keccak256("stock");
        _stockPool(q);
        stockA.mint(address(ml), 10);
        vm.prank(address(ml));
        rewards.onFeeCredit(q, address(stockA), 1, 10);
        ml.setAccrued(q, 2, 10);
        bytes32 skey = rewards.streamKey(q, _epoch(), address(stockA), 1);
        assertEq(rewards.forwardProtocolDesk(skey), 5);
        assertEq(stockA.balanceOf(address(staking)), 5);
        assertEq(rewards.rawCustody(address(stockA)), 5);
        assertEq(stockA.balanceOf(address(rewards)), 5);
    }

    /// L217 false arm: protocol staking pulling less than forwarded.
    function test_ForwardDelta() public {
        _royaltyAsset();
        nft.setSupply(2, 1);
        rewards.configureProtocolStaking(address(staking));
        rewards.depositRoyalty(address(stockA), 10);
        bytes32 key = rewards.streamKey(rewards.ROYALTY(), _epoch(), address(stockA), 1);
        staking.setShort(1);
        vm.expectRevert(bytes("forward delta"));
        rewards.forwardProtocolDesk(key);
        staking.setShort(0);
        assertEq(rewards.forwardProtocolDesk(key), 5);
        assertEq(rewards.delegatedFunded(key), 5);
    }

    /// L357/L358 both arms: ledger pushes are not royalty; outsider pushes are; re-entrant pushes revert.
    function test_ReceivePaths() public {
        nft.setSupply(2, 1);
        rewards.configureProtocolStaking(address(staking));
        bytes32 key = rewards.streamKey(rewards.ROYALTY(), _epoch(), address(0), 0);
        vm.prank(address(ml));
        (bool ok,) = address(rewards).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(rewards.streamCreditTotal(key), 0);
        (ok,) = address(rewards).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(rewards.streamCreditTotal(key), 1e45);
        staking.setReenter(true);
        vm.expectRevert(bytes("reentrancy"));
        rewards.fundProtocolDeskBudget(key);
        staking.setReenter(false);
        assertEq(rewards.fundProtocolDeskBudget(key), 1 ether);
    }

    /// L224 false arm (no controller / wrong sender) and pass arm.
    function test_OnEligibilityChange() public {
        vm.expectRevert(bytes("registry"));
        rewards.onEligibilityChange(alice);
        CovCRwController ctl = new CovCRwController(address(0xEE));
        nft.setController(address(ctl));
        vm.expectRevert(bytes("registry"));
        rewards.onEligibilityChange(alice);
        vm.prank(address(0xEE));
        rewards.onEligibilityChange(alice);
    }

    // ---------------------------------------------------------------- round entries

    function _rounds() internal returns (CovCRwRounds r) {
        r = new CovCRwRounds();
        rewards.configureRounds(address(r), address(new CovCRwPayout()), address(new CovCRwSchedule()));
    }

    function _surchargeEntry(uint256 supply, uint256 value) internal returns (bytes32 key, DeskRewardEntry e) {
        nft.setSupply(supply, 0);
        nft.callSurcharge{value: value}(rewards);
        key = rewards.streamKey(rewards.SURCHARGE(), _epoch(), address(0), 0);
        e = DeskRewardEntry(payable(rewards.entrySource(key)));
    }

    /// L158 both arms (empty budget vs funded), L161 pass arm, L414 both arms, L437 pass arm.
    function test_SealEmptyAndFunded() public {
        CovCRwRounds r = _rounds();
        uint256 epoch = _epoch();
        (bytes32 key, DeskRewardEntry e) = _surchargeEntry(3, 1);
        assertEq(rewards.entrySource(key), address(e)); // second call returns the existing entry
        assertEq(r.registered(), 1);
        vm.prank(address(r));
        vm.expectRevert(bytes("seal")); // epoch not over
        e.sealReward(epoch, 0);
        vm.warp((epoch + 1) * 1 days);
        vm.prank(address(r));
        vm.expectRevert(bytes("empty budget"));
        e.sealReward(epoch, 0);

        // fresh day, funded stream
        (bytes32 key2, DeskRewardEntry e2) = _surchargeEntry(3, 3 ether);
        uint256 epoch2 = _epoch();
        vm.warp((epoch2 + 1) * 1 days);
        r.setRejects(true);
        vm.prank(address(r));
        vm.expectRevert();
        e2.sealReward(epoch2, 0);
        r.setRejects(false);
        vm.prank(address(r));
        (uint256 budget, uint256 total, uint8 kind) = e2.sealReward(epoch2, 0);
        assertEq(budget, 3 ether);
        assertEq(total, 3e45);
        assertEq(kind, 0);
        assertEq(address(r).balance, 3 ether);
        assertTrue(rewards.streamSealed(key2));
        vm.prank(address(r));
        vm.expectRevert(bytes("seal"));
        e2.sealReward(epoch2, 0);
        vm.expectRevert(bytes("seal"));
        rewards.sealDesk(key2); // not the entry
    }

    /// L161 false arm: credit not backed by any pulled cash (misbehaving ledger) cannot fund the entry.
    function test_SealFundEntryUnbacked() public {
        CovCRwRounds r = _rounds();
        bytes32 p = keccak256("native");
        _nativePool(p);
        nft.setSupply(1, 0);
        vm.prank(address(ml));
        rewards.onFeeCredit(p, address(0), 0, 2 ether);
        bytes32 key = rewards.streamKey(p, _epoch(), address(0), 0);
        DeskRewardEntry e = DeskRewardEntry(payable(rewards.entrySource(key)));
        uint256 epoch = _epoch();
        vm.warp((epoch + 1) * 1 days);
        assertEq(address(rewards).balance, 0);
        vm.prank(address(r));
        vm.expectRevert(bytes("fund entry"));
        e.sealReward(epoch, 0);
        assertFalse(rewards.streamSealed(key));
    }

    /// L411 false arm; L427 / L432 / L437 both arms; never-called views lastFeeAt / deliveryAllowed / participantAt.
    function test_EntryViewsAndGuards() public {
        CovCRwRounds r = _rounds();
        uint256 epoch = _epoch();
        (bytes32 key, DeskRewardEntry e) = _surchargeEntry(2, 1 ether);
        assertEq(e.key(), key);
        assertEq(e.lastFeeAt(), epoch * 1 days);
        assertTrue(e.deliveryAllowed(alice, address(0)));
        assertEq(e.participantAt(0), address(rewards));
        vm.expectRevert();
        e.participantAt(1);
        (uint256 a, uint256 b) = e.queueSnapshot(epoch);
        assertEq(a, 1);
        assertEq(b, 1);
        vm.expectRevert();
        e.queueSnapshot(epoch + 1);
        assertEq(e.creditOf(address(rewards), epoch, 0), 1e45);
        assertEq(e.creditOf(alice, epoch, 0), 0);
        assertEq(e.creditOf(address(rewards), epoch, 1), 0);
        (bytes32 id, uint32 version, bytes32 price, uint8 mode) = e.rewardPolicy(epoch, 0);
        assertEq(id, bytes32("asset"));
        assertEq(version, 3);
        assertEq(price, bytes32("price"));
        assertEq(mode, 0);
        CovCRwController ctl = new CovCRwController(address(1));
        ctl.setMode(true, epoch);
        nft.setController(address(ctl));
        (,,, mode) = e.rewardPolicy(epoch, 0);
        assertEq(mode, 1);
        ctl.setMode(true, epoch + 1);
        (,,, mode) = e.rewardPolicy(epoch, 0);
        assertEq(mode, 0);
        vm.expectRevert();
        e.rewardPolicy(epoch + 1, 0);
        vm.warp((epoch + 1) * 1 days);
        vm.expectRevert(); // not rounds
        e.sealReward(epoch, 0);
        vm.prank(address(r));
        vm.expectRevert();
        e.sealReward(epoch + 1, 0);
        vm.prank(address(r));
        vm.expectRevert();
        e.sealReward(epoch, 1);
        (bool ok,) = address(e).call{value: 1}("");
        assertFalse(ok);
    }

    /// L183 false arm: purchased delivery must be covered by actual held stock; then kind-0 pay draws it.
    function test_SyncPurchasedCoverage() public {
        CovCRwRounds r = _rounds();
        (bytes32 key, DeskRewardEntry e) = _surchargeEntry(1, 1 ether);
        nft.setOwner(1, alice);
        RewardRoundManager.Entry memory en;
        en.source = address(e);
        en.epoch = _epoch();
        r.setEntry(5, en);
        r.vault().setAsset(address(stockA));
        r.setDelivered(5, 10);
        vm.expectRevert(bytes("purchase coverage"));
        rewards.syncPurchased(key, 5);
        stockA.mint(address(rewards), 10);
        rewards.syncPurchased(key, 5);
        assertEq(rewards.purchasedRaw(key), 10);
        assertEq(rewards.purchasedOutstanding(address(stockA)), 10);
        (address asset, uint256 rev) = rewards.deliveryInfo(key);
        assertEq(asset, address(stockA));
        assertEq(rev, 10);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        assertEq(nft.callPay(rewards, 1, keys, alice), 10);
        assertEq(rewards.purchasedOutstanding(address(stockA)), 0);
        assertEq(rewards.purchasedSpent(address(stockA)), 10);
        // an entry from another source is rejected
        en.source = address(0xBAD);
        r.setEntry(6, en);
        vm.expectRevert(bytes("entry"));
        rewards.syncPurchased(key, 6);
    }
}
