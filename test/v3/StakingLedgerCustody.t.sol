// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {SolonStakingV2} from "../../src/v3/SolonStakingV2.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {RewardPayoutVault} from "../../src/v3/RewardPayoutVault.sol";
import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";

contract CustodyStakeAsset is ERC20 {
    constructor() ERC20("Asset", "A") {}

    function mint(address who, uint256 amount) external {
        _mint(who, amount);
    }
}

contract CustodyObserver {
    function onFeeCredit(bytes32, address, uint8, uint256) external {}
}

contract StakingLedgerCustodyTest is Test {
    function testOutsiderCannotConsumeNativeBackingBeforeStakingSeal() public {
        _check(false);
    }

    function testOutsiderCannotConsumeRawBackingBeforeStakingStage() public {
        _check(true);
    }

    function _check(bool raw) internal {
        vm.warp(10 days);
        vm.deal(address(this), 100 ether);
        CustodyStakeAsset solon = new CustodyStakeAsset();
        CustodyStakeAsset stock = new CustodyStakeAsset();
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        EligibilityController controller = new EligibilityController(address(this));
        SolonStakingV2 staking = new SolonStakingV2(address(solon), address(ledger), controller);
        RewardPayoutVault payout = new RewardPayoutVault(new address[](0), controller);
        RewardRoundManager rounds = new RewardRoundManager(address(this), address(stock), address(payout), address(77));
        staking.configureRewards(address(rounds), address(payout));
        rounds.configureRewardModules(address(0), address(staking));
        payout.configureRewardModules(address(0), address(staking));
        bytes32 pool = keccak256("custody");
        address quote = raw ? address(stock) : address(0);
        uint8 kind = raw ? 1 : 0;
        staking.configureSource(pool, quote, kind, address(stock), bytes32(uint256(1)), 1, bytes32(uint256(2)));
        address observer = address(new CustodyObserver());
        address[6] memory recipients;
        for (uint256 i; i < 6; ++i) {
            recipients[i] = observer;
        }
        recipients[3] = address(staking);
        ledger.registerPool(pool, quote, kind, address(this), recipients);
        solon.mint(address(this), 100 ether);
        solon.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        if (raw) {
            stock.mint(address(this), 100 ether);
            stock.approve(address(ledger), 100 ether);
            ledger.creditStock(pool, 100 ether);
        } else {
            ledger.creditNative{value: 100 ether}(pool);
        }
        vm.prank(address(0xbad));
        (bool ok,) = address(ledger).call(abi.encodeCall(ledger.claim, (pool, uint8(3), 5 ether)));
        assertFalse(ok, "outsider consumed staking backing");
        assertEq(ledger.accrued(pool, 3), 5 ether);
        bytes32 key = staking.poolLane(pool);
        address source = staking.createEntrySource(key);
        if (raw) {
            uint256[] memory epochs = new uint256[](1);
            epochs[0] = 10;
            payout.stageCredit(source, address(this), epochs, address(stock));
            assertEq(payout.readyRaw(address(this), address(stock)), 5 ether);
        } else {
            vm.warp(11 days);
            vm.prank(source);
            (uint256 budget,,) = staking.sealSource(key, 10);
            assertEq(budget, 5 ether);
            assertEq(source.balance, 5 ether);
        }
        assertEq(ledger.accrued(pool, 3), 0);
        staking.unstake(100 ether, address(this));
        assertEq(solon.balanceOf(address(this)), 100 ether);
    }
}
