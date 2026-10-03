// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {CreatorRightsNFT} from "../../src/v3/CreatorRightsNFT.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {LedgerReceiver, LedgerStock, NativeUsdcView} from "./V3FeeLedger.t.sol";

contract CreatorRightsTest is Test {
    CreatorRightsNFT nft;
    V3FeeLedger ledger;
    address seller = address(0xA11CE);
    address buyer = address(0xB0B);
    bytes32 constant POOL = keccak256("creator-native");
    address[6] beneficiaries;

    function setUp() public {
        ledger = new V3FeeLedger(address(this), address(new NativeUsdcView()));
        nft = new CreatorRightsNFT(address(this), ledger, address(0));
        for (uint256 i; i < 6; ++i) {
            beneficiaries[i] = address(new LedgerReceiver());
        }
        beneficiaries[1] = address(nft);
        ledger.registerPool(POOL, address(0), 0, address(this), beneficiaries);
        vm.deal(address(this), 100 ether);
    }

    function testMintCreatesOneRightForRegisteredPool() public {
        uint256 id = nft.mint(POOL, seller);
        assertGt(id, 0);
        assertEq(nft.ownerOfPool(POOL), seller);
        assertEq(nft.ownerOf(id), seller);
        vm.expectRevert();
        nft.mint(POOL, buyer);
        vm.prank(buyer);
        vm.expectRevert();
        nft.mint(keccak256("another"), buyer);
        vm.expectRevert();
        nft.mint(keccak256("missing"), buyer);
    }

    function testHistoricalIncomeFollowsTransferAndOperatorPaysOnlyOwner() public {
        uint256 id = nft.mint(POOL, seller);
        ledger.creditNative{value: 10000}(POOL);
        assertEq(nft.claimable(id), 1000);
        vm.prank(seller);
        nft.transferFrom(seller, buyer, id);
        vm.prank(seller);
        vm.expectRevert();
        nft.claimCreator(id, address(0), 1000, 0);
        vm.prank(buyer);
        nft.approve(seller, id);
        vm.prank(seller);
        assertTrue(nft.claimCreator(id, address(0), 400, 0));
        assertEq(buyer.balance, 400);
        assertEq(seller.balance, 0);
        assertEq(nft.claimable(id), 600);
        vm.prank(buyer);
        assertTrue(nft.claimCreator(id, address(0), 600, 0));
        vm.prank(buyer);
        vm.expectRevert();
        nft.claimCreator(id, address(0), 1, 0);
    }

    function testClaimAndSafeTransferShareReentrancyBoundary() public {
        CreatorReentrantOwner receiver = new CreatorReentrantOwner(nft);
        uint256 id = nft.mint(POOL, address(receiver));
        receiver.configure(id, true, false);
        ledger.creditNative{value: 10000}(POOL);
        assertTrue(receiver.claim(100));
        assertFalse(receiver.entered());
        assertEq(nft.ownerOf(id), address(receiver));
        vm.prank(address(receiver));
        nft.transferFrom(address(receiver), seller, id);
        vm.prank(seller);
        nft.safeTransferFrom(seller, address(receiver), id);
        assertFalse(receiver.entered());
        assertEq(nft.claimable(id), 900);
    }

    function testStockRawDeliveryPreservesDebtWhileFrozen() public {
        LedgerStock stock = new LedgerStock();
        bytes32 pool = keccak256("stock-right");
        ledger.registerPool(pool, address(stock), 1, address(this), beneficiaries);
        uint256 id = nft.mint(pool, seller);
        stock.mint(address(this), 10000);
        stock.approve(address(ledger), 10000);
        ledger.creditStock(pool, 10000);
        stock.configure(true, false, false);
        vm.prank(seller);
        assertFalse(nft.claimCreator(id, address(stock), 1000, 0));
        assertEq(nft.claimable(id), 1000);
        stock.configure(false, false, false);
        vm.prank(seller);
        assertTrue(nft.claimCreator(id, address(stock), 1000, 0));
        assertEq(stock.balanceOf(seller), 1000);
        assertEq(nft.claimable(id), 0);
    }

    function testUsdcSixDecimalPayoutRetainsDust() public {
        uint256 id = nft.mint(POOL, seller);
        ledger.creditNative{value: 10000e12 + 10000}(POOL);
        vm.prank(seller);
        assertTrue(nft.claimCreator(id, address(0), 1000e12 + 1000, 1));
        assertEq(seller.balance, 1000e12);
        assertEq(nft.claimable(id), 1000);
        vm.prank(seller);
        assertTrue(nft.claimCreator(id, address(0), 1000, 0));
        assertEq(nft.claimable(id), 0);
    }

    function testPolicyModeSwitchFreezesOnlyStockDeliveryAndRetainsRights() public {
        CreatorEligibilityPolicy policy = new CreatorEligibilityPolicy();
        CreatorRightsNFT rights = new CreatorRightsNFT(address(this), ledger, address(policy));
        beneficiaries[1] = address(rights);
        LedgerStock stock = new LedgerStock();
        bytes32 pool = keccak256("policy");
        ledger.registerPool(pool, address(stock), 1, address(this), beneficiaries);
        uint256 id = rights.mint(pool, seller);
        stock.mint(address(this), 10000);
        stock.approve(address(ledger), 10000);
        ledger.creditStock(pool, 10000);
        vm.prank(seller);
        assertTrue(rights.claimCreator(id, address(stock), 100, 0));
        policy.configure(true, false);
        vm.prank(seller);
        assertFalse(rights.claimCreator(id, address(stock), 900, 0));
        assertEq(rights.claimable(id), 900);
        policy.configure(true, true);
        vm.prank(seller);
        assertTrue(rights.claimCreator(id, address(stock), 900, 0));
        bytes32 nativePool = keccak256("policy-native");
        ledger.registerPool(nativePool, address(0), 0, address(this), beneficiaries);
        uint256 nativeId = rights.mint(nativePool, seller);
        ledger.creditNative{value: 10000}(nativePool);
        policy.configure(true, false);
        vm.prank(seller);
        assertTrue(rights.claimCreator(nativeId, address(0), 1000, 0));
    }

    function testSignedPurchaseTransfersHistoricalIncomeAtAgreedFloor() public {
        uint256 key = 0x123456;
        seller = vm.addr(key);
        uint256 id = nft.mint(POOL, seller);
        ledger.creditNative{value: 10000}(POOL);
        CreatorRightsNFT.Purchase memory order =
            CreatorRightsNFT.Purchase(id, seller, buyer, address(0), 0, block.timestamp + 60, 1000, 1 ether);
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(key, nft.purchaseDigest(order));
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        nft.purchase{value: 1 ether}(order, abi.encodePacked(r, sigS, v));
        assertEq(nft.ownerOf(id), buyer);
        assertEq(nft.claimable(id), 1000);
        assertEq(seller.balance, 1 ether);
        assertEq(nft.nonces(id), 1);
    }

    function testSellerClaimBelowSignedFloorBlocksPurchase() public {
        uint256 key = 0x123456;
        seller = vm.addr(key);
        uint256 id = nft.mint(POOL, seller);
        ledger.creditNative{value: 10000}(POOL);
        CreatorRightsNFT.Purchase memory order =
            CreatorRightsNFT.Purchase(id, seller, buyer, address(0), 0, block.timestamp + 60, 1000, 1 ether);
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(key, nft.purchaseDigest(order));
        vm.prank(seller);
        assertTrue(nft.claimCreator(id, address(0), 1, 0));
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert();
        nft.purchase{value: 1 ether}(order, abi.encodePacked(r, sigS, v));
        assertEq(nft.ownerOf(id), seller);
        assertEq(buyer.balance, 1 ether);
        assertEq(nft.claimable(id), 999);
    }

    function testMetadataDisclosesUnclaimedIncomeTransfer() public {
        uint256 id = nft.mint(POOL, seller);
        string memory uri = nft.tokenURI(id);
        assertTrue(vm.contains(uri, "Transfer includes accrued unclaimed income"));
        vm.expectRevert();
        nft.tokenURI(id + 1);
    }

    function testPermissionlessLedgerSweepsStayIsolatedAcrossNativePools() public {
        bytes32 other = keccak256("other");
        ledger.registerPool(other, address(0), 0, address(this), beneficiaries);
        uint256 a = nft.mint(POOL, seller);
        uint256 b = nft.mint(other, buyer);
        ledger.creditNative{value: 10000}(POOL);
        ledger.creditNative{value: 20000}(other);
        vm.prank(address(99));
        assertTrue(ledger.claim(other, 1, 2000));
        vm.prank(address(99));
        assertTrue(ledger.claim(POOL, 1, 300));
        vm.deal(address(nft), address(nft).balance + 77);
        vm.prank(seller);
        assertTrue(nft.claimCreator(a, address(0), 1000, 0));
        assertEq(nft.claimable(b), 2000);
        vm.prank(buyer);
        assertTrue(nft.claimCreator(b, address(0), 2000, 0));
        assertEq(address(nft).balance, 77);
        assertEq(seller.balance, 1000);
        assertEq(buyer.balance, 2000);
    }

    function testSameStockPoolsAndDifferentAssetCannotShareCredits() public {
        LedgerStock stock = new LedgerStock();
        LedgerStock otherStock = new LedgerStock();
        for (uint256 i = 1; i <= 3; ++i) {
            address asset = i == 3 ? address(otherStock) : address(stock);
            ledger.registerPool(bytes32(i), asset, 1, address(this), beneficiaries);
            nft.mint(bytes32(i), i == 1 ? seller : buyer);
            LedgerStock(asset).mint(address(this), i * 10000);
            LedgerStock(asset).approve(address(ledger), i * 10000);
            ledger.creditStock(bytes32(i), i * 10000);
            assertTrue(ledger.claim(bytes32(i), 1, i * 1000));
        }
        vm.prank(seller);
        assertTrue(nft.claimCreator(1, address(stock), 1000, 0));
        vm.prank(buyer);
        vm.expectRevert();
        nft.claimCreator(3, address(stock), 3000, 0);
        vm.prank(buyer);
        assertTrue(nft.claimCreator(3, address(otherStock), 3000, 0));
        assertEq(nft.claimable(2), 2000);
        vm.prank(buyer);
        assertTrue(nft.claimCreator(2, address(stock), 2000, 0));
        assertEq(stock.balanceOf(seller), 1000);
        assertEq(stock.balanceOf(buyer), 2000);
        assertEq(otherStock.balanceOf(buyer), 3000);
    }

    function testNativeRejectRollsBackDebtAndLedgerPullThenRetries() public {
        CreatorReentrantOwner receiver = new CreatorReentrantOwner(nft);
        uint256 id = nft.mint(POOL, address(receiver));
        ledger.creditNative{value: 10000}(POOL);
        receiver.configure(id, false, true);
        assertFalse(receiver.claim(1000));
        assertEq(nft.paid(id), 0);
        assertEq(nft.claimable(id), 1000);
        assertEq(ledger.accrued(POOL, 1), 1000);
        receiver.configure(id, false, false);
        assertTrue(receiver.claim(1000));
        assertEq(address(receiver).balance, 1000);
    }

    function testTaxedOrFalseReturningStockKeepsPreDeliveredDebt() public {
        LedgerStock stock = new LedgerStock();
        bytes32 pool = keccak256("hostile-stock");
        ledger.registerPool(pool, address(stock), 1, address(this), beneficiaries);
        uint256 id = nft.mint(pool, seller);
        stock.mint(address(this), 10000);
        stock.approve(address(ledger), 10000);
        ledger.creditStock(pool, 10000);
        assertTrue(ledger.claim(pool, 1, 1000));
        stock.configure(false, true, false);
        vm.prank(seller);
        assertFalse(nft.claimCreator(id, address(stock), 1000, 0));
        stock.configure(false, false, true);
        vm.prank(seller);
        assertFalse(nft.claimCreator(id, address(stock), 1000, 0));
        assertEq(nft.claimable(id), 1000);
        assertEq(stock.balanceOf(seller), 0);
        assertEq(stock.balanceOf(address(nft)), 1000);
        stock.configure(false, false, false);
        vm.prank(seller);
        assertTrue(nft.claimCreator(id, address(stock), 1000, 0));
    }

    function testInvalidPayoutAssetModeAndDustRejected() public {
        uint256 id = nft.mint(POOL, seller);
        ledger.creditNative{value: 10000}(POOL);
        vm.prank(seller);
        vm.expectRevert();
        nft.claimCreator(id, address(1), 1000, 0);
        vm.prank(seller);
        vm.expectRevert();
        nft.claimCreator(id, address(0), 1000, 2);
        vm.prank(seller);
        vm.expectRevert();
        nft.claimCreator(id, address(0), 1000, 1);
        vm.prank(seller);
        vm.expectRevert();
        nft.claimCreator(id, address(0), 0, 0);
        vm.prank(seller);
        vm.expectRevert();
        nft.claimCreator(id, address(0), 1001, 0);
        vm.expectRevert();
        nft.executePayment(id, seller, 1000, 0);
        assertEq(nft.claimable(id), 1000);
    }

    function testMintRejectsWrongLedgerBeneficiaryAndUnsafeRecipient() public {
        bytes32 other = keccak256("wrong-beneficiary");
        beneficiaries[1] = seller;
        ledger.registerPool(other, address(0), 0, address(this), beneficiaries);
        vm.expectRevert();
        nft.mint(other, seller);
        vm.expectRevert();
        nft.mint(POOL, address(this));
        assertEq(nft.tokenOfPool(POOL), 0);
        nft.mint(POOL, seller);
    }

    function testSignedPurchaseRejectsMutatedFieldsReplayAndOwnershipRoundtrip() public {
        uint256 key = 0x123456;
        seller = vm.addr(key);
        uint256 id = nft.mint(POOL, seller);
        ledger.creditNative{value: 10000}(POOL);
        CreatorRightsNFT.Purchase memory order =
            CreatorRightsNFT.Purchase(id, seller, buyer, address(0), 0, block.timestamp + 60, 1000, 1 ether);
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(key, nft.purchaseDigest(order));
        bytes memory sig = abi.encodePacked(r, sigS, v);
        vm.deal(buyer, 3 ether);
        order.minAccrued = 999;
        vm.prank(buyer);
        vm.expectRevert();
        nft.purchase{value: 1 ether}(order, sig);
        order.minAccrued = 1000;
        vm.prank(address(99));
        vm.expectRevert();
        nft.purchase(order, sig);
        vm.prank(buyer);
        vm.expectRevert();
        nft.purchase{value: 2 ether}(order, sig);
        vm.prank(seller);
        nft.transferFrom(seller, address(99), id);
        vm.prank(address(99));
        nft.transferFrom(address(99), seller, id);
        vm.prank(buyer);
        vm.expectRevert();
        nft.purchase{value: 1 ether}(order, sig);
        order.nonce = nft.nonces(id);
        (v, r, sigS) = vm.sign(key, nft.purchaseDigest(order));
        sig = abi.encodePacked(r, sigS, v);
        vm.prank(buyer);
        nft.purchase{value: 1 ether}(order, sig);
        vm.prank(buyer);
        vm.expectRevert();
        nft.purchase{value: 1 ether}(order, sig);
    }

    function testExpiredAndCrossChainPurchaseSignaturesRejected() public {
        uint256 key = 0x123456;
        seller = vm.addr(key);
        uint256 id = nft.mint(POOL, seller);
        CreatorRightsNFT.Purchase memory order =
            CreatorRightsNFT.Purchase(id, seller, buyer, address(0), 0, block.timestamp + 60, 0, 0);
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(key, nft.purchaseDigest(order));
        bytes memory sig = abi.encodePacked(r, sigS, v);
        uint256 originalChain = block.chainid;
        vm.chainId(originalChain + 1);
        vm.prank(buyer);
        vm.expectRevert();
        nft.purchase(order, sig);
        vm.chainId(originalChain);
        vm.warp(order.deadline + 1);
        vm.prank(buyer);
        vm.expectRevert();
        nft.purchase(order, sig);
    }

    function testContractSellerERC1271SignatureAccepted() public {
        CreatorContractSeller smart = new CreatorContractSeller();
        uint256 id = nft.mint(POOL, address(smart));
        CreatorRightsNFT.Purchase memory order =
            CreatorRightsNFT.Purchase(id, address(smart), buyer, address(0), 0, block.timestamp + 60, 0, 1 ether);
        smart.authorize(nft.purchaseDigest(order));
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        nft.purchase{value: 1 ether}(order, hex"1234");
        assertEq(nft.ownerOf(id), buyer);
        assertEq(address(smart).balance, 1 ether);
    }

    function testFuzzNativeEntitlementSurvivesSplitFeesAndExternalPull(uint64 raw, uint64 swept) public {
        uint256 amount = bound(uint256(raw), 10, 1e18);
        uint256 id = nft.mint(POOL, seller);
        ledger.creditNative{value: amount / 2}(POOL);
        ledger.creditNative{value: amount - amount / 2}(POOL);
        uint256 due = amount / 10;
        uint256 pre = bound(uint256(swept), 0, due);
        if (pre != 0) assertTrue(ledger.claim(POOL, 1, pre));
        assertEq(nft.claimable(id), due);
        vm.prank(seller);
        assertTrue(nft.claimCreator(id, address(0), due, 0));
        assertEq(seller.balance, due);
        assertEq(nft.claimable(id), 0);
    }

    function testUnsafeUsdcViewCannotEraseNativeDebt() public {
        LedgerStock unrelated = new LedgerStock();
        V3FeeLedger wrong = new V3FeeLedger(address(this), address(unrelated));
        CreatorRightsNFT rights = new CreatorRightsNFT(address(this), wrong, address(0));
        beneficiaries[1] = address(rights);
        wrong.registerPool(POOL, address(0), 0, address(this), beneficiaries);
        uint256 id = rights.mint(POOL, seller);
        wrong.creditNative{value: 10000e12}(POOL);
        unrelated.mint(address(rights), 1000);
        vm.prank(seller);
        assertFalse(rights.claimCreator(id, address(0), 1000e12, 1));
        assertEq(rights.claimable(id), 1000e12);
        assertEq(wrong.accrued(POOL, 1), 1000e12);
        assertEq(unrelated.balanceOf(seller), 0);
    }

    function testMintCallbackCannotClaimAlreadyAccruedIncome() public {
        CreatorReentrantOwner receiver = new CreatorReentrantOwner(nft);
        receiver.configure(0, true, false);
        ledger.creditNative{value: 10000}(POOL);
        uint256 id = nft.mint(POOL, address(receiver));
        assertFalse(receiver.entered());
        assertEq(nft.claimable(id), 1000);
    }
}

contract CreatorReentrantOwner {
    CreatorRightsNFT public nft;
    uint256 public id;
    bool public attack;
    bool public entered;
    bool public reject;

    constructor(CreatorRightsNFT nft_) {
        nft = nft_;
    }

    function configure(uint256 id_, bool attack_, bool reject_) external {
        id = id_;
        attack = attack_;
        reject = reject_;
    }

    function onERC721Received(address, address, uint256 id_, bytes calldata) external returns (bytes4) {
        id = id_;
        if (attack) {
            try nft.claimCreator(id, address(0), 100, 0) {
                entered = true;
            } catch {}
        }
        return this.onERC721Received.selector;
    }

    function claim(uint256 amount) external returns (bool) {
        return nft.claimCreator(id, address(0), amount, 0);
    }

    receive() external payable {
        require(!reject, "Reject");
        if (attack) {
            try nft.transferFrom(address(this), address(0xBAD), id) {
                entered = true;
            } catch {}
        }
    }
}

contract CreatorEligibilityPolicy {
    bool public eligibilityEnabled;
    bool public allowed;

    function configure(bool enabled_, bool allowed_) external {
        eligibilityEnabled = enabled_;
        allowed = allowed_;
    }

    function canReceiveStock(address, address) external view returns (bool) {
        return allowed;
    }
}

contract CreatorContractSeller {
    bytes32 public digest;

    function authorize(bytes32 digest_) external {
        digest = digest_;
    }

    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return hash == digest ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }
    receive() external payable {}
}
