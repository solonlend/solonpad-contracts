// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {ProtocolDeskVault} from "../../src/v3/ProtocolDeskVault.sol";

contract BootstrapAsset is ERC20 {
    constructor() ERC20("SOLON", "SOLON") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BootstrapRewards {
    function recordMintSurcharge() external payable {}
}

contract BootstrapProtocol {
    function receiveDeskProtocol(bytes32) external payable {}
}

contract BootstrapOps {
    function payDeskSurcharge(bytes32, uint256, uint256 cards, address desk) external returns (uint256 amount) {
        amount = cards * DeskNFT(desk).surchargeUSDC18();
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
    receive() external payable {}
}

contract DeskBootstrapTest is Test {
    DeskNFT nft;
    ProtocolDeskVault vault;
    BootstrapAsset solon;
    BootstrapOps ops;
    address alice = address(0xa11ce);

    function setUp() public {
        solon = new BootstrapAsset();
        ops = new BootstrapOps();
        nft = new DeskNFT(
            address(this),
            address(solon),
            address(0xdead),
            address(new BootstrapRewards()),
            address(new BootstrapProtocol()),
            address(0),
            DeskNFT.Quote(2e18, 1e18, block.timestamp, 1, bytes32("public quote"))
        );
        vault = new ProtocolDeskVault(nft, solon, address(0xdead), address(this), address(ops));
        solon.mint(alice, 200000e18);
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        solon.approve(address(nft), type(uint256).max);
        vm.deal(address(ops), 10 ether);
    }

    function testOrdinarySafeMintCannotPolluteUnboundProtocolVault() public {
        vm.prank(alice);
        (bool ok,) = address(nft).call{value: 1 ether}(abi.encodeCall(nft.mint, (1, address(vault))));
        assertFalse(ok, "unbound protocol vault accepted ordinary card");
        assertEq(nft.balanceOf(address(vault)), 0);
        assertEq(solon.balanceOf(alice), 200000e18);
    }

    function testProtocolBindingRejectsPreviouslyUnsafeTransferredCards() public {
        vm.prank(alice);
        nft.mint{value: 1 ether}(1, alice);
        vm.prank(alice);
        nft.transferFrom(alice, address(vault), 1);
        (bool ok,) = address(nft).call(abi.encodeCall(nft.configureProtocolVault, (address(vault))));
        assertFalse(ok, "polluted protocol binding understated protocol count");
        assertEq(nft.protocolVault(), address(0));
    }

    function testAuthenticatedProtocolMintStillAcceptsItsOwnCallback() public {
        nft.configureProtocolVault(address(vault));
        solon.mint(address(this), 100000e18);
        solon.approve(address(vault), 100000e18);
        vault.depositBuyback(bytes32("funded lot"), 100000e18);
        assertEq(vault.mintAvailable(1), 1);
        assertEq(nft.protocolMinted(), 1);
        assertEq(nft.balanceOf(address(vault)), 1);
    }
}
