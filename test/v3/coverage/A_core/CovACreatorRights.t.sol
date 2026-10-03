// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {CreatorRightsNFT} from "../../../../src/v3/CreatorRightsNFT.sol";
import {V3FeeLedger} from "../../../../src/v3/V3FeeLedger.sol";
import {LedgerReceiver, LedgerStock, NativeUsdcView} from "../../V3FeeLedger.t.sol";
import {CreatorEligibilityPolicy} from "../../CreatorRights.t.sol";

/// @dev ERC1271 seller that accepts ERC721 but rejects the native sale proceeds.
contract CovARejectingSeller {
    bytes32 public digest;

    function authorize(bytes32 d) external {
        digest = d;
    }

    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return hash == digest ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    receive() external payable {
        revert("no proceeds");
    }
}

contract CovARejectingOwner {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    receive() external payable {
        revert("reject");
    }
}

/// @notice Branch coverage for CreatorRightsNFT payout guards, delivery failures and signed sale arms.
contract CovACreatorRightsTest is Test {
    using stdStorage for StdStorage;
    CreatorRightsNFT nft;
    V3FeeLedger ledger;
    address seller = address(0xA11CE);
    address buyer = address(0xB0B);
    bytes32 constant POOL = keccak256("cov-creator-native");
    address[6] beneficiaries;

    event CreatorClaimFailed(uint256 indexed tokenId, uint256 amountRaw);

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

    function _stockPool(bytes32 pool, CreatorRightsNFT rights) internal returns (LedgerStock stock, uint256 id) {
        stock = new LedgerStock();
        address[6] memory b = beneficiaries;
        b[1] = address(rights);
        ledger.registerPool(pool, address(stock), 1, address(this), b);
        id = rights.mint(pool, seller);
        stock.mint(address(this), 10000);
        stock.approve(address(ledger), 10000);
        ledger.creditStock(pool, 10000);
    }

    function testConstructorRejectsZeroFactoryOrCodelessLedger() public {
        vm.expectRevert(bytes("Invalid configuration"));
        new CreatorRightsNFT(address(0), ledger, address(0));
        vm.expectRevert(bytes("Invalid configuration"));
        new CreatorRightsNFT(address(this), V3FeeLedger(payable(address(0x1234))), address(0));
    }

    // line 90 false arm: USDC6 view requested for a stock-quoted right.
    function testUsdc6ModeRejectedForStockRight() public {
        (LedgerStock stock, uint256 id) = _stockPool(keccak256("stock-usdc6"), nft);
        vm.prank(seller);
        vm.expectRevert(bytes("Invalid USDC view"));
        nft.claimCreator(id, address(stock), 1000, 1);
        assertEq(nft.claimable(id), 1000);
        assertEq(nft.paid(id), 0);
    }

    // line 90 false arm: USDC6 view requested on a ledger with the view disabled.
    function testUsdc6ModeRejectedWhenLedgerViewDisabled() public {
        V3FeeLedger plain = new V3FeeLedger(address(this), address(0));
        CreatorRightsNFT rights = new CreatorRightsNFT(address(this), plain, address(0));
        address[6] memory b = beneficiaries;
        b[1] = address(rights);
        plain.registerPool(POOL, address(0), 0, address(this), b);
        uint256 id = rights.mint(POOL, seller);
        plain.creditNative{value: 10000e12}(POOL);
        vm.prank(seller);
        vm.expectRevert(bytes("Invalid USDC view"));
        rights.claimCreator(id, address(0), 1000e12, 1);
        assertEq(rights.claimable(id), 1000e12);
        // mode 0 still works (true arm of line 90 not taken, mode 0 path)
        vm.prank(seller);
        assertTrue(rights.claimCreator(id, address(0), 1000e12, 0));
        assertEq(seller.balance, 1000e12);
    }

    // line 111 both arms: eligibility disabled -> pass; enabled+ineligible -> blocked; enabled+eligible -> pass.
    function testEligibilityPolicyArmsOnStockDelivery() public {
        CreatorEligibilityPolicy policy = new CreatorEligibilityPolicy();
        CreatorRightsNFT rights = new CreatorRightsNFT(address(this), ledger, address(policy));
        (LedgerStock stock, uint256 id) = _stockPool(keccak256("policy-arms"), rights);
        policy.configure(false, false);
        vm.prank(seller);
        assertTrue(rights.claimCreator(id, address(stock), 100, 0));
        policy.configure(true, false);
        // precise reason via the self-only boundary
        vm.prank(address(rights));
        vm.expectRevert(bytes("Delivery blocked"));
        rights.executePayment(id, seller, 1, 0);
        vm.prank(seller);
        assertFalse(rights.claimCreator(id, address(stock), 100, 0));
        assertEq(rights.claimable(id), 900);
        policy.configure(true, true);
        vm.prank(seller);
        assertTrue(rights.claimCreator(id, address(stock), 900, 0));
        assertEq(stock.balanceOf(seller), 1000);
        assertEq(rights.claimable(id), 0);
    }

    // line 116 false arm: the ledger pull itself fails (taxed stock into the NFT) -> whole claim rolled back.
    function testLedgerPullFailureRollsBackClaim() public {
        (LedgerStock stock, uint256 id) = _stockPool(keccak256("ledger-pull-fails"), nft);
        stock.configure(false, true, false); // taxed: ledger's own exactness check fails
        bytes32 pool = keccak256("ledger-pull-fails");
        vm.expectEmit(true, false, false, true, address(nft));
        emit CreatorClaimFailed(id, 1000);
        vm.prank(seller);
        assertFalse(nft.claimCreator(id, address(stock), 1000, 0));
        assertEq(nft.paid(id), 0);
        assertEq(ledger.accrued(pool, 1), 1000);
        assertEq(stock.balanceOf(address(nft)), 0);
        assertEq(stock.balanceOf(seller), 0);
        // exact reason: simulate the in-flight debit and call the self-only boundary directly
        stdstore.target(address(nft)).sig("paid(uint256)").with_key(id).checked_write(uint256(1000));
        vm.prank(address(nft));
        vm.expectRevert(bytes("Ledger payment failed"));
        nft.executePayment(id, seller, 1000, 0);
        stdstore.target(address(nft)).sig("paid(uint256)").with_key(id).checked_write(uint256(0));
        stock.configure(false, false, false);
        vm.prank(seller);
        assertTrue(nft.claimCreator(id, address(stock), 1000, 0));
        assertEq(stock.balanceOf(seller), 1000);
        assertEq(ledger.accrued(pool, 1), 0);
    }

    // line 123 false arm: owner rejects native payment (exact reason via self-only boundary).
    function testNativeOwnerRejectionReason() public {
        CovARejectingOwner owner = new CovARejectingOwner();
        uint256 id = nft.mint(POOL, address(owner));
        ledger.creditNative{value: 10000}(POOL);
        assertTrue(ledger.claim(POOL, 1, 1000)); // pre-delivered: needed == 0 arm of line 116
        vm.prank(address(nft));
        vm.expectRevert(bytes("Payment failed"));
        nft.executePayment(id, address(owner), 1000, 0);
        vm.prank(address(owner));
        assertFalse(nft.claimCreator(id, address(0), 1000, 0));
        assertEq(address(nft).balance, 1000);
        assertEq(nft.claimable(id), 1000);
    }

    // line 130 false arm: taxed outgoing stock transfer -> "Inexact transfer".
    function testTaxedOutgoingStockReason() public {
        bytes32 pool = keccak256("taxed-out");
        (LedgerStock stock, uint256 id) = _stockPool(pool, nft);
        assertTrue(ledger.claim(pool, 1, 1000));
        assertEq(stock.balanceOf(address(nft)), 1000);
        stock.configure(false, true, false);
        vm.prank(address(nft));
        vm.expectRevert(bytes("Inexact transfer"));
        nft.executePayment(id, seller, 1000, 0);
        assertEq(stock.balanceOf(address(nft)), 1000);
    }

    function _sign(uint256 key, CreatorRightsNFT.Purchase memory order) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, nft.purchaseDigest(order));
        return abi.encodePacked(r, s, v);
    }

    // line 182 both arms: wrong signer rejected, right signer accepted.
    function testPurchaseSignatureArms() public {
        uint256 key = 0xC0FFEE;
        seller = vm.addr(key);
        uint256 id = nft.mint(POOL, seller);
        CreatorRightsNFT.Purchase memory order =
            CreatorRightsNFT.Purchase(id, seller, buyer, address(0), 0, block.timestamp + 60, 0, 0);
        bytes memory wrongSig = _sign(0xBEEF, order);
        bytes memory goodSig = _sign(key, order);
        vm.prank(buyer);
        vm.expectRevert(bytes("Invalid signature"));
        nft.purchase(order, wrongSig);
        assertEq(nft.ownerOf(id), seller);
        vm.prank(buyer);
        nft.purchase(order, goodSig); // zero price: line 187 false arm
        assertEq(nft.ownerOf(id), buyer);
        assertEq(nft.nonces(id), 1);
    }

    // line 185 both arms: accrued exactly at the floor passes, one wei above fails.
    function testPurchaseAccruedFloorBoundary() public {
        uint256 key = 0xC0FFEE;
        seller = vm.addr(key);
        uint256 id = nft.mint(POOL, seller);
        ledger.creditNative{value: 10000}(POOL);
        CreatorRightsNFT.Purchase memory order =
            CreatorRightsNFT.Purchase(id, seller, buyer, address(0), 0, block.timestamp + 60, 1001, 0);
        bytes memory sig = _sign(key, order);
        vm.prank(buyer);
        vm.expectRevert(bytes("Accrued below signed floor"));
        nft.purchase(order, sig);
        order.minAccrued = 1000;
        sig = _sign(key, order);
        vm.prank(buyer);
        nft.purchase(order, sig);
        assertEq(nft.ownerOf(id), buyer);
        assertEq(nft.claimable(id), 1000);
    }

    // line 189 false arm: seller rejects proceeds -> whole sale reverts, buyer keeps funds.
    function testPurchaseSellerRejectsProceeds() public {
        CovARejectingSeller smart = new CovARejectingSeller();
        uint256 id = nft.mint(POOL, address(smart));
        CreatorRightsNFT.Purchase memory order =
            CreatorRightsNFT.Purchase(id, address(smart), buyer, address(0), 0, block.timestamp + 60, 0, 1 ether);
        smart.authorize(nft.purchaseDigest(order));
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(bytes("Sale payment failed"));
        nft.purchase{value: 1 ether}(order, hex"01");
        assertEq(nft.ownerOf(id), address(smart));
        assertEq(buyer.balance, 1 ether);
        assertEq(nft.nonces(id), 0);
    }

    // line 200: only the ledger may send native value; ledger sends succeed.
    function testReceiveOnlyFromLedger() public {
        (bool ok,) = address(nft).call{value: 1}("");
        assertFalse(ok);
        bytes memory err;
        (ok, err) = address(nft).call{value: 1}("");
        assertEq(bytes4(err), CreatorRightsNFT.Unauthorized.selector);
        vm.deal(address(ledger), 5);
        vm.prank(address(ledger));
        (ok,) = address(nft).call{value: 5}("");
        assertTrue(ok);
        assertEq(address(nft).balance, 5);
    }
}
