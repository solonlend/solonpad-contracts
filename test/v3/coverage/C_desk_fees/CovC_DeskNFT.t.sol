// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {DeskNFT} from "../../../../src/v3/DeskNFT.sol";
import {DeskProtocolFixture} from "../../helpers/DeskProtocolFixture.sol";
import {CovCToken, CovCNoReceive} from "./CovCMocks.sol";

/// @notice NOTE: written against the DeskNFT source in this worktree (feat/v3-cov); DeskNFT is being changed
/// on another branch, so these tests must be revisited when that lands.

/// @notice Programmable IDeskRewards used to isolate DeskNFT's own branches.
contract CovCNftRewards {
    mapping(bytes32 => address) public asset;
    mapping(bytes32 => uint256) public revision;
    uint256 public claimableAmt;
    uint256 public payAmt = 1;
    uint256 public revertId;
    bool public rejects;
    uint256 public surcharges;
    uint256 public pays;

    function setDelivery(bytes32 k, address a, uint256 r) external {
        asset[k] = a;
        revision[k] = r;
    }

    function setClaimable(uint256 c) external {
        claimableAmt = c;
    }

    function setPay(uint256 p, uint256 revertOn) external {
        payAmt = p;
        revertId = revertOn;
    }

    function setRejects(bool r) external {
        rejects = r;
    }

    function deliveryInfo(bytes32 k) external view returns (address, uint256) {
        return (asset[k], revision[k]);
    }

    function recordMintSurcharge() external payable {
        surcharges += msg.value;
    }

    function claimable(uint256, bytes32) external view returns (uint256) {
        return claimableAmt;
    }

    function pay(uint256 id, bytes32[] calldata, address) external returns (uint256) {
        require(id != revertId, "pay blocked");
        pays++;
        return payAmt;
    }

    receive() external payable {
        require(!rejects, "rewards rejects");
    }
}

contract CovCNftController {
    mapping(address => bool) public blocked;

    function setBlocked(address w, bool b) external {
        blocked[w] = b;
    }

    function canReceiveStock(address, address wallet) external view returns (bool) {
        return !blocked[wallet];
    }
}

contract CovCNftOracle {
    uint256 public price = 1e18;
    uint256 public at;

    function set(uint256 p, uint256 a) external {
        price = p;
        at = a;
    }

    function priceUSD18(address) external view returns (uint256, uint256) {
        return (price, at == 0 ? block.timestamp : at);
    }
}

contract CovCNftPolicy {
    address public oracle;
    uint256 public oracleMaxAge = 1 hours;
    uint256 public minimumUSD18;

    constructor(address o) {
        oracle = o;
    }

    function setMinimum(uint256 m) external {
        minimumUSD18 = m;
    }
}

/// @notice Protocol vault actor: mints protocol cards and attempts approvals.
contract CovCProtocolActor {
    function mintP(DeskNFT nft, CovCToken solon, uint256 count) external payable returns (uint256) {
        solon.approve(address(nft), type(uint256).max);
        return nft.mintProtocol{value: msg.value}(count);
    }

    function approveAll(DeskNFT nft, address op) external {
        nft.setApprovalForAll(op, true);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @notice ERC1271 seller whose ETH acceptance can be switched off.
contract CovC1271Seller {
    bool public rejects;

    function setRejects(bool r) external {
        rejects = r;
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        require(!rejects, "seller rejects");
    }
}

contract CovCDeskNFTTest is Test {
    DeskNFT nft;
    CovCNftRewards rewards;
    CovCToken solon;
    CovCProtocolActor pv;
    address sink = address(0xDEAD);
    uint256 constant SELLER_KEY = 0x5E11;
    address seller;
    address buyer = address(0xB0B);
    uint256 constant FEE = 1e18;
    CovCNftOracle oracle;
    CovCNftPolicy policy;

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function setUp() public {
        vm.warp(100 days + 1 hours);
        solon = new CovCToken();
        rewards = new CovCNftRewards();
        nft = _deploy(address(0));
        pv = new CovCProtocolActor();
        nft.configureProtocolVault(address(pv));
        solon.mint(address(this), 10_000_000e18);
        solon.approve(address(nft), type(uint256).max);
        solon.mint(address(pv), 1_000_000e18);
        seller = vm.addr(SELLER_KEY);
        vm.deal(address(this), 1000 ether);
        vm.deal(buyer, 1000 ether);
        vm.deal(address(pv), 1000 ether);
    }

    function _deploy(address controller) internal returns (DeskNFT n) {
        n = new DeskNFT(
            address(this),
            address(solon),
            sink,
            address(rewards),
            address(new DeskProtocolFixture()),
            controller,
            DeskNFT.Quote(2e18, 1e18, vm.getBlockTimestamp(), 1, keccak256("quote"))
        );
    }

    function _order(uint256 id, address s, uint256 minUnclaimed, uint256 price)
        internal
        view
        returns (DeskNFT.Purchase memory o)
    {
        o = DeskNFT.Purchase(id, s, buyer, keccak256("stream"), nft.nonces(id), vm.getBlockTimestamp() + 1 hours, minUnclaimed, price);
    }

    function _sign(DeskNFT.Purchase memory o, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, nft.purchaseDigest(o));
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------- constructor / mint

    /// L93 false arm: a quote whose half-surcharge rounds to zero is rejected.
    function test_ConstructorZeroSurcharge() public {
        address r = address(rewards);
        address p = address(new DeskProtocolFixture());
        vm.expectRevert(bytes("surcharge"));
        new DeskNFT(address(this), address(solon), sink, r, p, address(0), DeskNFT.Quote(1, 1e18, vm.getBlockTimestamp(), 1, keccak256("q")));
        DeskNFT ok =
            new DeskNFT(address(this), address(solon), sink, r, p, address(0), DeskNFT.Quote(2, 1e18, vm.getBlockTimestamp(), 1, keccak256("q")));
        assertEq(ok.surchargeUSDC18(), 1);
    }

    /// L382 both arms; L388 both arms.
    function test_MintGuards() public {
        vm.expectRevert(bytes("protocol mint only"));
        nft.mint{value: FEE}(1, address(pv));
        vm.expectRevert(bytes("surcharge payment"));
        nft.mint{value: FEE - 1}(1, address(this));
        vm.expectRevert(bytes("surcharge payment"));
        nft.mint{value: FEE}(2, address(this));
        uint256 first = nft.mint{value: 2 * FEE}(2, address(0xA1));
        assertEq(first, 1);
        assertEq(nft.ownerOf(2), address(0xA1));
        assertEq(solon.balanceOf(sink), 200000e18);
        assertEq(rewards.surcharges(), 1.8e18);
    }

    /// L393 false arm: fee-on-transfer burn is rejected.
    function test_MintSinkDelta() public {
        solon.setShortFrom(address(this));
        vm.expectRevert(bytes("sink delta"));
        nft.mint{value: FEE}(1, address(this));
        solon.setShortFrom(address(0));
        solon.setExtraFrom(address(this));
        vm.expectRevert(bytes("sink delta"));
        nft.mint{value: FEE}(1, address(this));
        assertEq(nft.totalSupply(), 0);
    }

    /// L159 false arm: controller gate on mint and transfer.
    function test_EligibilityGate() public {
        CovCNftController ctl = new CovCNftController();
        DeskNFT gated = _deploy(address(ctl));
        solon.approve(address(gated), type(uint256).max);
        ctl.setBlocked(address(0xA1), true);
        vm.expectRevert(bytes("Desk eligibility"));
        gated.mint{value: FEE}(1, address(0xA1));
        gated.mint{value: FEE}(1, address(0xA2));
        ctl.setBlocked(address(0xA2), true);
        vm.prank(address(0xA2));
        vm.expectRevert(bytes("Desk eligibility"));
        gated.transferFrom(address(0xA2), address(0xA3), 1);
        ctl.setBlocked(address(0xA2), false);
        vm.prank(address(0xA2));
        gated.transferFrom(address(0xA2), address(0xA3), 1);
        assertEq(gated.ownerOf(1), address(0xA3));
    }

    // ---------------------------------------------------------------- protocol vault

    function _protocolCard() internal returns (uint256 id) {
        id = pv.mintP{value: FEE}(nft, solon, 1);
        assertEq(nft.ownerOf(id), address(pv));
    }

    /// L164 both arms; L169 both arms.
    function test_ProtocolApprovalsBlocked() public {
        uint256 pid = _protocolCard();
        nft.mint{value: FEE}(1, address(this));
        vm.expectRevert(bytes("protocol approval"));
        nft.approve(address(0xA1), pid);
        nft.approve(address(0xA1), 2);
        assertEq(nft.getApproved(2), address(0xA1));
        vm.expectRevert(bytes("protocol approval"));
        pv.approveAll(nft, address(0xA1));
        nft.setApprovalForAll(address(0xA1), true);
        assertTrue(nft.isApprovedForAll(address(this), address(0xA1)));
    }

    /// L357 both arms.
    function test_ClaimProtocolDelegated() public {
        uint256 pid = _protocolCard();
        nft.mint{value: FEE}(1, address(this));
        bytes32[] memory keys = new bytes32[](1);
        vm.expectRevert(bytes("protocol delegated"));
        nft.claim(pid, keys);
        rewards.setPay(7, 0);
        assertEq(nft.claim(2, keys), 7);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        nft.claim(2, keys);
    }

    // ---------------------------------------------------------------- sponsorship

    /// L206 both arms.
    function test_GrantSponsored() public {
        address sponsor = address(0x5905);
        solon.mint(sponsor, 100000e18);
        vm.prank(sponsor);
        solon.approve(address(nft), type(uint256).max);
        vm.deal(sponsor, 10 ether);
        vm.expectRevert(bytes("sponsor consent"));
        nft.grantSponsored(address(0xA1), sponsor);
        vm.prank(sponsor);
        nft.authorizeSponsored{value: FEE}(address(0xA1));
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("governance/recipient"));
        nft.grantSponsored(address(0xA1), sponsor);
        assertEq(nft.grantSponsored(address(0xA1), sponsor), 1);
        assertEq(nft.ownerOf(1), address(0xA1));
        assertEq(nft.sponsorEscrow(sponsor, address(0xA1)), 0);
        assertEq(solon.balanceOf(sponsor), 0);
        vm.expectRevert(bytes("sponsor consent"));
        nft.grantSponsored(address(0xA1), sponsor);
    }

    // ---------------------------------------------------------------- secondary sale

    /// L130 both arms; L131 false arm; L135 both arms (free transfer vs priced sale with royalty split).
    function test_PurchaseSignatureFloorAndSplit() public {
        nft.mint{value: FEE}(1, seller);
        DeskNFT.Purchase memory o = _order(1, seller, 0, 0);
        bytes memory bad = _sign(o, SELLER_KEY + 1);
        vm.prank(buyer);
        vm.expectRevert(bytes("sale signature"));
        nft.purchase(o, bad);
        o.minUnclaimed = 5;
        rewards.setClaimable(4);
        bytes memory sig = _sign(o, SELLER_KEY);
        vm.prank(buyer);
        vm.expectRevert(bytes("unclaimed below floor"));
        nft.purchase(o, sig);
        rewards.setClaimable(5);
        vm.prank(buyer);
        nft.purchase(o, sig); // price 0: no payments
        assertEq(nft.ownerOf(1), buyer);
        assertEq(nft.nonces(1), 1);
        // priced resale back to the seller key holder path: mint a fresh card for the seller
        nft.mint{value: FEE}(1, seller);
        o = _order(2, seller, 0, 10 ether);
        sig = _sign(o, SELLER_KEY);
        uint256 rBefore = address(rewards).balance;
        vm.prank(buyer);
        nft.purchase{value: 10 ether}(o, sig);
        assertEq(address(rewards).balance - rBefore, 0.5 ether);
        assertEq(seller.balance, 9.5 ether);
        // replaying the consumed order fails: card moved and nonce bumped
        vm.prank(buyer);
        vm.expectRevert(bytes("stale order"));
        nft.purchase{value: 10 ether}(o, sig);
    }

    /// L138 both arms: rewards refusing the royalty reverts the sale.
    function test_PurchaseRoyaltyPaymentFails() public {
        nft.mint{value: FEE}(1, seller);
        DeskNFT.Purchase memory o = _order(1, seller, 0, 1 ether);
        bytes memory sig = _sign(o, SELLER_KEY);
        rewards.setRejects(true);
        vm.prank(buyer);
        vm.expectRevert(bytes("royalty payment"));
        nft.purchase{value: 1 ether}(o, sig);
        assertEq(nft.ownerOf(1), seller);
        rewards.setRejects(false);
        vm.prank(buyer);
        nft.purchase{value: 1 ether}(o, sig);
        assertEq(nft.ownerOf(1), buyer);
    }

    /// L140 both arms: an ERC1271 seller refusing ETH reverts the sale.
    function test_PurchaseSellerPaymentFails() public {
        CovC1271Seller s = new CovC1271Seller();
        nft.mint{value: FEE}(1, address(s));
        DeskNFT.Purchase memory o = _order(1, address(s), 0, 1 ether);
        s.setRejects(true);
        vm.prank(buyer);
        vm.expectRevert(bytes("sale payment"));
        nft.purchase{value: 1 ether}(o, hex"00");
        assertEq(nft.ownerOf(1), address(s));
        s.setRejects(false);
        vm.prank(buyer);
        nft.purchase{value: 1 ether}(o, hex"00");
        assertEq(address(s).balance, 0.95 ether);
        assertEq(nft.ownerOf(1), buyer);
    }

    // ---------------------------------------------------------------- service queues

    function _policy() internal {
        oracle = new CovCNftOracle();
        policy = new CovCNftPolicy(address(oracle));
        nft.configureServicePolicy(address(policy));
    }

    /// L227 false arm.
    function test_ServicePolicyOracleMustHaveCode() public {
        CovCNftPolicy p = new CovCNftPolicy(address(0x1234));
        vm.expectRevert(bytes("service oracle"));
        nft.configureServicePolicy(address(p));
        _policy();
        assertTrue(nft.servicePolicy() != address(0));
    }

    /// L251 / L256 / L260 both arms; deskQueueStreams view.
    function test_OpenDeskQueueGuards() public {
        _policy();
        bytes32 k1 = keccak256("k1");
        bytes32 k2 = keccak256("k2");
        bytes32 k3 = keccak256("k3");
        rewards.setDelivery(k1, address(0xA55E7), 1);
        rewards.setDelivery(k2, address(0xA55E7), 2);
        rewards.setDelivery(k3, address(0xB0), 1);
        bytes32[] memory dup = new bytes32[](2);
        dup[0] = k1;
        dup[1] = k1;
        vm.expectRevert(bytes("duplicate stream"));
        nft.openDeskQueue(dup);
        bytes32[] memory mixed = new bytes32[](2);
        mixed[0] = k1;
        mixed[1] = k3;
        vm.expectRevert(bytes("same asset"));
        nft.openDeskQueue(mixed);
        bytes32[] memory pair = new bytes32[](2);
        pair[0] = k1;
        pair[1] = k2;
        assertEq(nft.openDeskQueue(pair), 0);
        (bytes32[] memory ks, uint256[] memory revs) = nft.deskQueueStreams(0);
        assertEq(ks.length, 2);
        assertEq(ks[1], k2);
        assertEq(revs[0], 1);
        assertEq(revs[1], 2);
        vm.expectRevert(bytes("queue exists"));
        nft.openDeskQueue(pair);
        // a new revision is a new queue
        rewards.setDelivery(k2, address(0xA55E7), 3);
        assertEq(nft.openDeskQueue(pair), 1);
    }

    function _queueWithCards() internal returns (uint256 qid) {
        _policy();
        nft.mint{value: FEE}(1, address(0xA1)); // 1
        _protocolCard(); // 2
        nft.mint{value: 3 * FEE}(3, address(0xA3)); // 3,4,5
        bytes32 k = keccak256("k");
        rewards.setDelivery(k, address(0xA55E7), 1);
        rewards.setClaimable(1e18);
        qid = nft.openDeskQueue(k);
    }

    /// L286 true arm (protocol card skipped), L289 catch arm, and paid accounting.
    function test_AutomaticBatchSkipsProtocolAndCountsFailures() public {
        uint256 qid = _queueWithCards();
        rewards.setPay(1, 3);
        (uint256 paid, uint256 failed) = nft.batchDistributeDesk(qid, 5);
        assertEq(paid, 3); // 1, 4, 5
        assertEq(failed, 1); // 3
        assertEq(rewards.pays(), 3);
        (,,, uint256 cursor, uint256 nextScanAt) = nft.deskQueues(qid);
        assertEq(cursor, 5);
        assertEq(nextScanAt, (vm.getBlockTimestamp() / 1 days + 1) * 1 days + 10 minutes);
        vm.expectRevert(bytes("scan schedule"));
        nft.batchDistributeDesk(qid, 5);
    }

    /// L306 true arm: zero / stale / future price -> no push; L312: below minimum -> no push. Each scan covers
    /// the whole queue (5 cards incl. one protocol card), then the schedule rolls to the next day.
    function test_AutomaticPushPriceGates() public {
        uint256 qid = _queueWithCards();
        oracle.set(0, 0);
        _scanAll(qid, 0);
        oracle.set(1e18, vm.getBlockTimestamp() - 1 hours - 1);
        _scanAll(qid, 0);
        oracle.set(1e18, vm.getBlockTimestamp() + 1);
        _scanAll(qid, 0);
        oracle.set(1e18, 0);
        policy.setMinimum(1e18 + 1);
        _scanAll(qid, 0);
        assertEq(rewards.pays(), 0);
        policy.setMinimum(1e18);
        oracle.set(1e18, vm.getBlockTimestamp() - 1 hours);
        _scanAll(qid, 4);
        assertEq(rewards.pays(), 4);
    }

    function _scanAll(uint256 qid, uint256 expectPaid) internal {
        (uint256 paid, uint256 failed) = nft.batchDistributeDesk(qid, 5);
        assertEq(paid, expectPaid);
        assertEq(failed, 0);
        (,,,, uint256 nextScanAt) = nft.deskQueues(qid);
        vm.warp(nextScanAt);
    }

    /// L279 true arm: not enough gas for one push -> (0,0) and the cursor does not move.
    /// L284 true arm: gas runs below the reserve mid-page -> break with a partial cursor.
    function test_AutomaticBatchGasReserve() public {
        uint256 qid = _queueWithCards();
        (uint256 paid, uint256 failed) = nft.batchDistributeDesk{gas: 400000}(qid, 5);
        assertEq(paid + failed, 0);
        (,,, uint256 cursor,) = nft.deskQueues(qid);
        assertEq(cursor, 0);
        nft.batchDistributeDesk{gas: 660000}(qid, 5);
        (,,, cursor,) = nft.deskQueues(qid);
        assertGt(cursor, 0);
        assertLt(cursor, 5);
    }

    /// L302 / L342 both arms: push entry points are self-only.
    function test_PushEntryPointsSelfOnly() public {
        uint256 qid = _queueWithCards();
        vm.expectRevert(bytes("self"));
        nft.executeAutomaticPush(1, qid);
        vm.expectRevert(bytes("self"));
        nft.executePush(1, keccak256("k"));
    }

    /// L330 true arm (gas floor), L348 both arms (protocol card fails inside the try, ordinary card pays).
    function test_ManualBatch() public {
        _queueWithCards();
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = keccak256("k");
        (uint256 paid, uint256 failed) = nft.batchDistributeDesk{gas: 400000}(ids, keys);
        assertEq(paid + failed, 0);
        (paid, failed) = nft.batchDistributeDesk(ids, keys);
        assertEq(paid, 1);
        assertEq(failed, 1);
        bytes32[] memory five = new bytes32[](5);
        vm.expectRevert(bytes("batch page"));
        nft.batchDistributeDesk(ids, five);
    }
}

