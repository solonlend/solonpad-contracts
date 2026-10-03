// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {DeskProtocolFixture} from "./helpers/DeskProtocolFixture.sol";
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {DeskRewards} from "../../src/v3/DeskRewards.sol";
import {ProtocolDeskVault} from "../../src/v3/ProtocolDeskVault.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {SolonStakingV2} from "../../src/v3/SolonStakingV2.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {V3Governance} from "../../src/v3/governance/V3Governance.sol";
import {LedgerStock} from "./V3FeeLedger.t.sol";
import {DeskRewardStub} from "./Desk.t.sol";
import {DeskOpsFixture} from "./ProtocolDesk.t.sol";

/// @notice r9: cumulative primary-mint cap per receiving address (default 50 = 1% of 5000).
contract DeskMintCapTest is Test {
    DeskNFT nft;
    LedgerStock solon;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 fee;

    function setUp() public {
        solon = new LedgerStock();
        nft = new DeskNFT(
            address(this),
            address(solon),
            address(0xD00D),
            address(new DeskRewardStub()),
            address(new DeskProtocolFixture()),
            address(0),
            DeskNFT.Quote(2e18, 1e18, block.timestamp, 1, keccak256("quote"))
        );
        fee = nft.surchargeUSDC18();
        for (uint160 i = 1; i <= 3; ++i) {
            address a = i == 1 ? alice : i == 2 ? bob : address(this);
            solon.mint(a, 1_000_000_000e18);
            vm.deal(a, 1_000_000e18);
            vm.prank(a);
            solon.approve(address(nft), type(uint256).max);
        }
    }

    function _mint(address payer, uint256 count, address to) internal {
        vm.prank(payer);
        nft.mint{value: fee * count}(count, to);
    }

    function testDefaultIsOnePercentOfSupply() public view {
        assertEq(nft.mintCapPerAddress(), 50);
        assertEq(nft.mintCapPerAddress() * 100, nft.MAX_SUPPLY());
    }

    function testCapIsCumulativePerRecipient() public {
        _mint(alice, 20, alice);
        _mint(alice, 20, alice);
        _mint(alice, 10, alice);
        assertEq(nft.mintedTo(alice), 50);
        vm.prank(alice);
        vm.expectRevert(bytes("address mint cap"));
        nft.mint{value: fee}(1, alice);
        // transfers out do not reset the primary-mint counter
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(bytes("address mint cap"));
        nft.mint{value: fee}(1, alice);
        // another recipient has its own allowance even with the same payer
        _mint(alice, 20, bob);
        assertEq(nft.mintedTo(bob), 20);
        assertEq(nft.mintedTo(alice), 50);
    }

    function testSponsoredGrantCountsAgainstRecipientNotSponsor() public {
        _mint(bob, 20, bob);
        _mint(bob, 20, bob);
        _mint(bob, 10, bob);
        vm.prank(alice);
        nft.authorizeSponsored{value: fee}(bob);
        vm.expectRevert(bytes("address mint cap"));
        nft.grantSponsored(bob, alice);
        address carol = address(0xCA201);
        vm.prank(alice);
        nft.authorizeSponsored{value: fee}(carol);
        nft.grantSponsored(carol, alice);
        assertEq(nft.mintedTo(carol), 1);
        assertEq(nft.mintedTo(alice), 0, "sponsor does not receive the card");
    }

    function testGovernanceSetsAnyValueGuardianPathOnlyLowers() public {
        vm.prank(alice);
        vm.expectRevert(bytes("mint cap"));
        nft.setMintCapPerAddress(10);
        vm.prank(alice);
        vm.expectRevert(bytes("mint cap"));
        nft.tightenMintCapPerAddress(10);
        vm.expectRevert(bytes("mint cap"));
        nft.setMintCapPerAddress(5001);
        vm.expectRevert(bytes("mint cap"));
        nft.tightenMintCapPerAddress(50);
        nft.tightenMintCapPerAddress(10);
        assertEq(nft.mintCapPerAddress(), 10);
        nft.setMintCapPerAddress(100);
        assertEq(nft.mintCapPerAddress(), 100);
        assertTrue(nft.guardianTightenOnly(DeskNFT.tightenMintCapPerAddress.selector));
        assertFalse(nft.guardianTightenOnly(DeskNFT.setMintCapPerAddress.selector));
    }

    function testLoweredCapBlocksFurtherMintsOnly() public {
        _mint(alice, 20, alice);
        nft.tightenMintCapPerAddress(10);
        vm.prank(alice);
        vm.expectRevert(bytes("address mint cap"));
        nft.mint{value: fee}(1, alice);
        assertEq(nft.balanceOf(alice), 20, "existing cards untouched");
        nft.tightenMintCapPerAddress(0); // emergency: no primary mints at all
        vm.prank(bob);
        vm.expectRevert(bytes("address mint cap"));
        nft.mint{value: fee}(1, bob);
    }

    function testFuzzCapHolds(uint8 cap, uint8[6] calldata counts) public {
        uint256 c = uint256(cap) % 120;
        nft.setMintCapPerAddress(c);
        uint256 total;
        for (uint256 i; i < counts.length; ++i) {
            uint256 n = uint256(counts[i]) % 20 + 1;
            address to = i % 2 == 0 ? alice : bob;
            uint256 before = nft.mintedTo(to);
            vm.prank(alice);
            if (before + n > c) {
                vm.expectRevert(bytes("address mint cap"));
                nft.mint{value: fee * n}(n, to);
            } else {
                nft.mint{value: fee * n}(n, to);
                total += n;
            }
            assertLe(nft.mintedTo(to), c);
        }
        assertEq(nft.mintedTo(alice) + nft.mintedTo(bob), total);
        assertEq(nft.totalSupply(), total);
    }
}

/// @dev Same protocol-staking wiring as ProtocolDeskTest (ProtocolDeskVault.mintAvailable requires it).
abstract contract DeskStakingWiring {
    function _wireStaking(V3FeeLedger ledger, DeskRewards rewards, LedgerStock solon) internal {
        EligibilityController controller = new EligibilityController(address(this));
        SolonStakingV2 staking = new SolonStakingV2(address(solon), address(ledger), controller);
        staking.configureProtocolDesk(
            address(rewards), address(new LedgerStock()), bytes32("STOCK"), 1, bytes32("price")
        );
        rewards.configureProtocolStaking(address(staking));
    }
}

/// @notice The protocol Desk vault is exempt (own 1000-card cap, non-transferable, never paid out).
contract DeskMintCapProtocolTest is Test, DeskStakingWiring {
    function testProtocolVaultIsExempt() public {
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        DeskRewards rewards = new DeskRewards(ledger, address(this));
        LedgerStock solon = new LedgerStock();
        DeskOpsFixture ops = new DeskOpsFixture();
        DeskNFT nft = new DeskNFT(
            address(this),
            address(solon),
            address(0xDEAD),
            address(rewards),
            address(new DeskProtocolFixture()),
            address(0),
            DeskNFT.Quote(2e18, 1e18, block.timestamp, 1, keccak256("quote"))
        );
        rewards.configureNFT(nft);
        ProtocolDeskVault vault = new ProtocolDeskVault(nft, solon, address(0xDEAD), address(this), address(ops));
        nft.configureProtocolVault(address(vault));
        _wireStaking(ledger, rewards, solon);
        vm.deal(address(ops), 10000e18);
        solon.mint(address(this), 600000000e18);
        solon.approve(address(vault), type(uint256).max);
        vault.depositBuyback(bytes32("large-buyback"), 6_000_000e18);
        uint256 minted;
        for (uint256 i; i < 4; ++i) {
            minted += vault.mintAvailable(20);
        }
        assertEq(minted, 60);
        assertGt(nft.balanceOf(address(vault)), nft.mintCapPerAddress());
        assertEq(nft.mintedTo(address(vault)), 0);
    }
}

/// @notice The guardian reaches tightenMintCapPerAddress through V3Governance only after the 48h allowlisting, and
///         can never reach setMintCapPerAddress (DeskNFT does not declare it tighten-only).
contract DeskMintCapGovernanceTest is Test {
    function testGuardianTightensThroughGovernance() public {
        address multisig = address(0x5AFE);
        address guardian = address(0x6A2D);
        vm.warp(100 days);
        V3Governance gov = new V3Governance(multisig, guardian, address(this), vm.getBlockTimestamp() + 1 days);
        LedgerStock solon = new LedgerStock();
        DeskNFT nft = new DeskNFT(
            address(gov),
            address(solon),
            address(0xD00D),
            address(new DeskRewardStub()),
            address(new DeskProtocolFixture()),
            address(0),
            DeskNFT.Quote(2e18, 1e18, block.timestamp, 1, keccak256("quote"))
        );
        bytes memory allow =
            abi.encodeCall(V3Governance.setGuardianAction, (address(nft), DeskNFT.tightenMintCapPerAddress.selector, true));
        vm.prank(multisig);
        gov.schedule(address(gov), 0, allow, 0, 0, 48 hours);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        gov.execute(address(gov), 0, allow, 0, 0);
        vm.prank(guardian);
        gov.guardianCall(address(nft), abi.encodeCall(DeskNFT.tightenMintCapPerAddress, (20)));
        assertEq(nft.mintCapPerAddress(), 20);
        vm.prank(guardian);
        vm.expectRevert(bytes("mint cap"));
        gov.guardianCall(address(nft), abi.encodeCall(DeskNFT.tightenMintCapPerAddress, (30)));
        vm.prank(guardian);
        vm.expectRevert();
        gov.guardianCall(address(nft), abi.encodeCall(DeskNFT.setMintCapPerAddress, (500)));
        bytes memory grantSet =
            abi.encodeCall(V3Governance.setGuardianAction, (address(nft), DeskNFT.setMintCapPerAddress.selector, true));
        vm.prank(multisig);
        gov.schedule(address(gov), 0, grantSet, 0, bytes32(uint256(1)), 48 hours);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert();
        gov.execute(address(gov), 0, grantSet, 0, bytes32(uint256(1)));
        // raising is an ordinary 48h operation
        bytes memory raise = abi.encodeCall(DeskNFT.setMintCapPerAddress, (100));
        vm.prank(multisig);
        gov.schedule(address(nft), 0, raise, 0, 0, 48 hours);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        gov.execute(address(nft), 0, raise, 0, 0);
        assertEq(nft.mintCapPerAddress(), 100);
    }
}

contract DeskMintCapHandler is Test {
    DeskNFT public nft;
    address public protocolVault;
    address[4] public actors = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
    mapping(address => uint256) public ghostMinted;
    uint256 public ghostMaxViolation; // set when a mint lands above the cap in force at that time
    uint256 public ghostProtocol;
    uint256 fee;
    ProtocolDeskVault pv;

    constructor(DeskNFT nft_, ProtocolDeskVault pv_, LedgerStock solon) {
        nft = nft_;
        pv = pv_;
        protocolVault = address(pv_);
        fee = nft.surchargeUSDC18();
        for (uint256 i; i < 4; ++i) {
            solon.mint(actors[i], 1_000_000_000e18);
            vm.deal(actors[i], 1_000_000e18);
            vm.prank(actors[i]);
            solon.approve(address(nft), type(uint256).max);
        }
    }

    function mint(uint256 payerSeed, uint256 toSeed, uint256 count) external {
        address payer = actors[payerSeed % 4];
        address to = actors[toSeed % 4];
        count = bound(count, 1, 20);
        if (nft.totalSupply() + count > nft.MAX_SUPPLY()) return;
        vm.prank(payer);
        try nft.mint{value: fee * count}(count, to) {
            ghostMinted[to] += count;
            if (nft.mintedTo(to) > nft.mintCapPerAddress()) ghostMaxViolation = 1;
        } catch {}
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 idSeed) external {
        uint256 supply = nft.totalSupply();
        if (supply == 0) return;
        uint256 id = bound(idSeed, 1, supply);
        address owner = nft.ownerOf(id);
        if (owner == protocolVault) return;
        address to = actors[toSeed % 4];
        fromSeed;
        if (to == owner) return;
        vm.prank(owner);
        nft.transferFrom(owner, to, id);
    }

    function setCap(uint256 cap) external {
        vm.prank(nft.governance());
        nft.setMintCapPerAddress(bound(cap, 0, 120));
    }

    function protocolMint(uint256 n) external {
        n = bound(n, 1, 20);
        if (nft.totalSupply() + n > nft.MAX_SUPPLY()) return;
        try pv.mintAvailable(n) returns (uint256 got) {
            ghostProtocol += got;
        } catch {}
    }

    function actorCount() external pure returns (uint256) {
        return 4;
    }
}

contract DeskMintCapInvariantTest is StdInvariant, Test, DeskStakingWiring {
    DeskNFT nft;
    DeskMintCapHandler handler;
    ProtocolDeskVault pv;

    function setUp() public {
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        DeskRewards rewards = new DeskRewards(ledger, address(this));
        LedgerStock solon = new LedgerStock();
        DeskOpsFixture ops = new DeskOpsFixture();
        nft = new DeskNFT(
            address(this),
            address(solon),
            address(0xDEAD),
            address(rewards),
            address(new DeskProtocolFixture()),
            address(0),
            DeskNFT.Quote(2e18, 1e18, block.timestamp, 1, keccak256("quote"))
        );
        rewards.configureNFT(nft);
        pv = new ProtocolDeskVault(nft, solon, address(0xDEAD), address(this), address(ops));
        nft.configureProtocolVault(address(pv));
        _wireStaking(ledger, rewards, solon);
        vm.deal(address(ops), 1_000_000e18);
        solon.mint(address(this), 600_000_000e18);
        solon.approve(address(pv), type(uint256).max);
        pv.depositBuyback(bytes32("buyback"), 100_000_000e18);
        handler = new DeskMintCapHandler(nft, pv, solon);
        targetContract(address(handler));
    }

    /// Every card is accounted to exactly one primary recipient: capped actors or the exempt protocol vault.
    function invariant_mintsAccounted() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address a = handler.actors(i);
            assertEq(nft.mintedTo(a), handler.ghostMinted(a));
            sum += nft.mintedTo(a);
        }
        assertEq(sum + nft.protocolMinted(), nft.totalSupply());
        assertEq(nft.mintedTo(address(pv)), 0);
    }

    /// No mint ever lands an address above the cap in force at that moment.
    function invariant_capNeverExceededAtMint() public view {
        assertEq(handler.ghostMaxViolation(), 0);
    }
}
