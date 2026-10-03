// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {DeskProtocolFixture} from "../../helpers/DeskProtocolFixture.sol";
import {DeskOpsFixture} from "../../ProtocolDesk.t.sol";
import {DeskNFT} from "../../../../src/v3/DeskNFT.sol";
import {DeskRewards} from "../../../../src/v3/DeskRewards.sol";
import {ProtocolDeskVault} from "../../../../src/v3/ProtocolDeskVault.sol";
import {V3FeeLedger} from "../../../../src/v3/V3FeeLedger.sol";
import {SolonStakingV2} from "../../../../src/v3/SolonStakingV2.sol";
import {EligibilityController} from "../../../../src/v3/EligibilityController.sol";
import {LedgerStock} from "../../V3FeeLedger.t.sol";

/// @notice Ops that lies about the surcharge (returns cost, pays `cost - short`).
contract CovCShortOps {
    uint256 public short;

    function setShort(uint256 s) external {
        short = s;
    }

    function payDeskSurcharge(bytes32, uint256, uint256 cards, address desk) external returns (uint256 amount) {
        amount = DeskNFT(desk).surchargeUSDC18() * cards;
        (bool ok,) = msg.sender.call{value: amount - short}("");
        require(ok);
    }
    receive() external payable {}
}

/// @notice Misbehaving ops that front-runs the protocol mint with an ordinary card inside the callback.
contract CovCFrontRunOps {
    LedgerStock solon;

    constructor(LedgerStock s) {
        solon = s;
    }

    function payDeskSurcharge(bytes32, uint256, uint256 cards, address desk) external returns (uint256 amount) {
        DeskNFT nft = DeskNFT(desk);
        solon.approve(desk, type(uint256).max);
        nft.mint{value: nft.surchargeUSDC18()}(1, address(0xA11CE));
        amount = nft.surchargeUSDC18() * cards;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
    receive() external payable {}
}

contract CovCProtocolDeskVaultTest is Test {
    DeskNFT nft;
    DeskRewards rewards;
    ProtocolDeskVault vault;
    LedgerStock solon;
    LedgerStock stock;
    V3FeeLedger ledger;
    DeskOpsFixture ops;
    SolonStakingV2 staking;
    address sink = address(0xDEAD);

    function setUp() public {
        ledger = new V3FeeLedger(address(this), address(0));
        rewards = new DeskRewards(ledger, address(this));
        solon = new LedgerStock();
        stock = new LedgerStock();
        ops = new DeskOpsFixture();
        nft = new DeskNFT(
            address(this),
            address(solon),
            sink,
            address(rewards),
            address(new DeskProtocolFixture()),
            address(0),
            DeskNFT.Quote(2e18, 1e18, block.timestamp, 1, keccak256("quote"))
        );
        rewards.configureNFT(nft);
        EligibilityController controller = new EligibilityController(address(this));
        staking = new SolonStakingV2(address(solon), address(ledger), controller);
        staking.configureProtocolDesk(address(rewards), address(stock), bytes32("STOCK"), 1, bytes32("price"));
        rewards.configureProtocolStaking(address(staking));
        solon.mint(address(this), 600000000e18);
    }

    function _vault(address ops_) internal returns (ProtocolDeskVault v) {
        v = new ProtocolDeskVault(nft, solon, sink, address(this), ops_);
        nft.configureProtocolVault(address(v));
        solon.approve(address(v), type(uint256).max);
        vm.deal(ops_, 10000e18);
    }

    function _fillCap(ProtocolDeskVault v) internal {
        v.depositBuyback(bytes32("cap"), 100000000e18);
        for (uint256 i; i < 50; ++i) {
            v.mintAvailable(20);
        }
        assertEq(nft.protocolMinted(), 1000);
        assertEq(v.pendingSolon(), 0);
    }

    /// L32 false arm: each mis-wired constructor argument is rejected.
    function test_ConstructorConfiguration() public {
        vm.expectRevert(bytes("configuration"));
        new ProtocolDeskVault(nft, solon, sink, address(0), address(ops));
        vm.expectRevert(bytes("configuration"));
        new ProtocolDeskVault(nft, solon, address(0xBEEF), address(this), address(ops));
        vm.expectRevert(bytes("configuration"));
        new ProtocolDeskVault(nft, stock, sink, address(this), address(ops));
        vm.expectRevert(bytes("configuration"));
        new ProtocolDeskVault(nft, solon, sink, address(this), address(0x0123));
    }

    /// L48 false arm: fee-on-transfer receipt is rejected.
    function test_DepositDeltaRejected() public {
        ProtocolDeskVault v = _vault(address(ops));
        solon.configure(false, true, false);
        vm.expectRevert(bytes("deposit delta"));
        v.depositBuyback(bytes32("lot"), 100000e18);
        assertEq(v.pendingSolon(), 0);
        assertEq(v.deposits(bytes32("lot")), 0);
    }

    /// L68 false arm: ops reporting the cost but under-paying cannot mint.
    function test_OpsSurchargeMustBeExact() public {
        CovCShortOps bad = new CovCShortOps();
        ProtocolDeskVault v = _vault(address(bad));
        v.depositBuyback(bytes32("lot"), 100000e18);
        bad.setShort(1);
        vm.expectRevert(bytes("ops surcharge"));
        v.mintAvailable(1);
        assertEq(nft.totalSupply(), 0);
        assertEq(v.pendingSolon(), 100000e18);
        bad.setShort(0);
        assertEq(v.mintAvailable(1), 1);
        assertEq(nft.ownerOf(1), address(v));
    }

    /// L77 false arm: the token range moved between quote and mint (misbehaving ops) -> "mint receipt".
    function test_MintReceiptMustMatchFirstId() public {
        CovCFrontRunOps bad = new CovCFrontRunOps(solon);
        solon.mint(address(bad), 100000e18);
        ProtocolDeskVault v = _vault(address(bad));
        v.depositBuyback(bytes32("lot"), 100000e18);
        vm.expectRevert(bytes("mint receipt"));
        v.mintAvailable(1);
        assertEq(nft.totalSupply(), 0);
        assertEq(v.pendingSolon(), 100000e18);
    }

    /// L84 false arm; L86 true arm (capacity reached, nothing pending -> 0); L105 both arms.
    function test_SweepCapacityAndEmpty() public {
        ProtocolDeskVault v = _vault(address(ops));
        v.depositBuyback(bytes32("pre"), 1e18);
        vm.expectRevert(bytes("capacity available"));
        v.sweepOverflowToBurn();
        // receive: only ops
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(v).call{value: 1 ether}("");
        assertFalse(ok);
        vm.prank(address(ops));
        (ok,) = address(v).call{value: 1 ether}("");
        assertTrue(ok);
        _fillCapFrom(v, 1e18);
        assertEq(v.sweepOverflowToBurn(), 1e18);
        assertEq(v.sweepOverflowToBurn(), 0);
        assertEq(v.pendingSolon(), 0);
    }

    function _fillCapFrom(ProtocolDeskVault v, uint256 alreadyPending) internal {
        v.depositBuyback(bytes32("cap"), 100000000e18);
        for (uint256 i; i < 50; ++i) {
            v.mintAvailable(20);
        }
        assertEq(nft.protocolMinted(), 1000);
        assertEq(v.pendingSolon(), alreadyPending);
    }

    /// L91 false arm: a taxed sink transfer fails the exact sink delta.
    function test_SweepSinkDelta() public {
        ProtocolDeskVault v = _vault(address(ops));
        _fillCap(v);
        v.depositBuyback(bytes32("over"), 5e18);
        uint256 sinkBefore = solon.balanceOf(sink);
        solon.configure(false, true, false);
        vm.expectRevert(bytes("sink delta"));
        v.sweepOverflowToBurn();
        assertEq(v.pendingSolon(), 5e18);
        assertEq(solon.balanceOf(sink), sinkBefore);
    }
}
