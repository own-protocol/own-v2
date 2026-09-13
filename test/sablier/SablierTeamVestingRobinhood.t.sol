// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CreateTeamVestingRobinhood} from "../../script/sablier/CreateTeamVestingRobinhood.s.sol";
import {DeploySablierLockupRobinhood} from "../../script/sablier/DeploySablierLockupRobinhood.s.sol";

import {Actors} from "../helpers/Actors.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin-v5.3.0/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin-v5.3.0/contracts/token/ERC721/IERC721.sol";
import {SablierComptroller} from "@sablier/evm-utils/src/SablierComptroller.sol";
import {ISablierComptroller} from "@sablier/evm-utils/src/interfaces/ISablierComptroller.sol";
import {ISablierLockup} from "@sablier/lockup/src/interfaces/ISablierLockup.sol";
import {Errors} from "@sablier/lockup/src/libraries/Errors.sol";
import {Lockup} from "@sablier/lockup/src/types/Lockup.sol";
import {LockupLinear} from "@sablier/lockup/src/types/LockupLinear.sol";
import {Test} from "forge-std/Test.sol";

/// @dev End-to-end test of the two Sablier scripts: deploy the audited Lockup protocol on a
///      Robinhood-chain-id fork, create the 5 team streams, and check the 30%-at-month-1 +
///      70%-linear-over-6-months schedule against the deployed contracts.
contract SablierTeamVestingRobinhoodTest is Test {
    uint256 internal constant DEPLOYER_KEY = 0xA11CE;
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant UPFRONT_BPS = 3000;
    uint40 internal constant CLIFF = 30 days;
    uint40 internal constant LINEAR = 180 days;

    address internal deployer = vm.addr(DEPLOYER_KEY);
    address internal safe = Actors.ADMIN;
    address internal attacker = Actors.ATTACKER;

    MockERC20 internal token;
    DeploySablierLockupRobinhood internal deployScript;
    CreateTeamVestingRobinhood internal createScript;
    ISablierLockup internal lockup;
    ISablierComptroller internal comptroller;

    address[] internal team;
    uint256[] internal amounts;
    uint256 internal total;
    uint40 internal start;
    uint40 internal cliffAt;
    uint40 internal endAt;

    function setUp() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        vm.warp(1_800_000_000);

        token = new MockERC20("Own", "OWN", 18);

        team.push(address(uint160(uint256(keccak256("team1")))));
        team.push(address(uint160(uint256(keccak256("team2")))));
        team.push(address(uint160(uint256(keccak256("team3")))));
        team.push(address(uint160(uint256(keccak256("team4")))));
        team.push(address(uint160(uint256(keccak256("team5")))));
        amounts.push(1000e18);
        amounts.push(2000e18);
        amounts.push(500e18);
        amounts.push(1_234_567_890_123_456_789);
        amounts.push(1001);
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
        token.mint(deployer, total);

        start = uint40(block.timestamp + 1 days);
        cliffAt = start + CLIFF;
        endAt = cliffAt + LINEAR;

        vm.setEnv("DEPLOYER_PRIVATE_KEY_ROBINHOOD", vm.toString(DEPLOYER_KEY));
        vm.setEnv("SABLIER_ADMIN_ROBINHOOD", vm.toString(safe));
        deployScript = new DeploySablierLockupRobinhood();
        deployScript.run();
        lockup = ISablierLockup(address(deployScript.lockup()));
        comptroller = ISablierComptroller(address(deployScript.comptroller()));

        _setCreateEnv();
        createScript = new CreateTeamVestingRobinhood();
        createScript.run();
    }

    function _setCreateEnv() internal {
        vm.setEnv("SABLIER_LOCKUP_ROBINHOOD", vm.toString(address(lockup)));
        vm.setEnv("VESTING_TOKEN_ROBINHOOD", vm.toString(address(token)));
        vm.setEnv("VESTING_BENEFICIARIES_ROBINHOOD", _csvAddresses(team));
        vm.setEnv("VESTING_AMOUNTS_ROBINHOOD", _csvUints(amounts));
        vm.setEnv("VESTING_START_ROBINHOOD", vm.toString(uint256(start)));
        vm.setEnv("VESTING_SENDER_ROBINHOOD", vm.toString(safe));
        vm.setEnv("VESTING_CANCELABLE_ROBINHOOD", "true");
        vm.setEnv("VESTING_TRANSFERABLE_ROBINHOOD", "false");
    }

    function _csvAddresses(
        address[] memory xs
    ) internal pure returns (string memory s) {
        for (uint256 i = 0; i < xs.length; i++) {
            s = i == 0 ? vm.toString(xs[i]) : string.concat(s, ",", vm.toString(xs[i]));
        }
    }

    function _csvUints(
        uint256[] memory xs
    ) internal pure returns (string memory s) {
        for (uint256 i = 0; i < xs.length; i++) {
            s = i == 0 ? vm.toString(xs[i]) : string.concat(s, ",", vm.toString(xs[i]));
        }
    }

    function _cliffUnlock(
        uint256 amount
    ) internal pure returns (uint256) {
        return amount * UPFRONT_BPS / BPS;
    }

    function _expectedStreamed(
        uint256 amount,
        uint40 at
    ) internal view returns (uint256) {
        if (at < cliffAt) return 0;
        if (at >= endAt) return amount;
        uint256 upfront = _cliffUnlock(amount);
        return upfront + (amount - upfront) * (at - cliffAt) / LINEAR;
    }

    function _config() internal view returns (CreateTeamVestingRobinhood.Config memory cfg) {
        cfg.deployerKey = DEPLOYER_KEY;
        cfg.lockup = lockup;
        cfg.token = IERC20(address(token));
        cfg.beneficiaries = team;
        cfg.amounts = amounts;
        cfg.start = start;
        cfg.sender = safe;
        cfg.cancelable = true;
        cfg.transferable = false;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   PROTOCOL DEPLOY
    //////////////////////////////////////////////////////////////////////////*/

    function test_deploy_wiresComptrollerDescriptorAndLockup() public view {
        assertEq(comptroller.admin(), safe, "admin");
        assertEq(comptroller.oracle(), address(0), "oracle");
        assertEq(comptroller.getMinFeeUSD(ISablierComptroller.Protocol.Lockup), 0, "min fee usd");
        assertEq(comptroller.calculateMinFeeWei(ISablierComptroller.Protocol.Lockup), 0, "min fee wei");
        assertEq(address(lockup.comptroller()), address(comptroller), "lockup.comptroller");
        assertEq(address(lockup.nftDescriptor()), address(deployScript.nftDescriptor()), "descriptor");
        assertEq(lockup.calculateMinFeeWei(1), 0, "withdrawals are free");
    }

    function test_deploy_comptrollerCannotBeReinitialised() public {
        SablierComptroller proxy = deployScript.comptroller();
        SablierComptroller impl = deployScript.comptrollerImpl();
        vm.expectRevert();
        proxy.initialize(attacker, 0, 0, 0, 0, address(0));
        vm.expectRevert();
        impl.initialize(attacker, 0, 0, 0, 0, address(0));
    }

    function test_deploy_wrongChain_reverts() public {
        vm.chainId(1);
        DeploySablierLockupRobinhood fresh = new DeploySablierLockupRobinhood();
        vm.expectRevert("RPC is not Robinhood Chain (4663)");
        fresh.runWith(DEPLOYER_KEY, safe);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   STREAM CREATION
    //////////////////////////////////////////////////////////////////////////*/

    function test_run_createsOneStreamPerBeneficiary() public view {
        assertEq(lockup.nextStreamId(), team.length + 1, "stream count");
        assertEq(token.balanceOf(address(lockup)), total, "lockup holds every allocation");
        assertEq(token.balanceOf(deployer), 0, "deployer fully funded the streams");
        assertEq(lockup.aggregateAmount(IERC20(address(token))), total, "aggregate amount");

        for (uint256 i = 0; i < team.length; i++) {
            uint256 id = createScript.streamIds(i);
            assertEq(id, i + 1, "sequential ids");
            assertEq(lockup.getRecipient(id), team[i], "recipient");
            assertEq(lockup.getSender(id), safe, "sender is the Safe");
            assertEq(lockup.getDepositedAmount(id), amounts[i], "deposit");
            assertEq(lockup.getStartTime(id), start, "start");
            assertEq(lockup.getCliffTime(id), cliffAt, "cliff");
            assertEq(lockup.getEndTime(id), endAt, "end");
            assertEq(lockup.getGranularity(id), 1, "per-second granularity");
            assertTrue(lockup.isCancelable(id), "cancelable");
            assertFalse(lockup.isTransferable(id), "not transferable");
            assertTrue(lockup.getLockupModel(id) == Lockup.Model.LOCKUP_LINEAR, "linear model");
            LockupLinear.UnlockAmounts memory u = lockup.getUnlockAmounts(id);
            assertEq(u.start, 0, "no unlock at start");
            assertEq(u.cliff, _cliffUnlock(amounts[i]), "30% unlock at cliff");
            assertTrue(lockup.statusOf(id) == Lockup.Status.PENDING, "pending before start");
        }
    }

    function test_run_dustRoundsCliffDownAndTotalIsExact() public {
        uint256 id = createScript.streamIds(4);
        assertEq(amounts[4], 1001);
        assertEq(lockup.getUnlockAmounts(id).cliff, 300, "floor(1001 * 0.3)");
        vm.warp(endAt);
        assertEq(lockup.streamedAmountOf(id), 1001, "everything streams by the end");
    }

    function test_run_policyOverrides_irrevocableTransferable() public {
        token.mint(deployer, total);
        CreateTeamVestingRobinhood.Config memory cfg = _config();
        cfg.cancelable = false;
        cfg.transferable = true;
        CreateTeamVestingRobinhood again = new CreateTeamVestingRobinhood();
        again.runWith(cfg);

        uint256 id = again.streamIds(0);
        assertFalse(lockup.isCancelable(id), "irrevocable");
        assertTrue(lockup.isTransferable(id), "transferable");
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Errors.SablierLockup_StreamNotCancelable.selector, id));
        lockup.cancel(id);
    }

    function test_run_lengthMismatch_reverts() public {
        CreateTeamVestingRobinhood.Config memory cfg = _config();
        cfg.amounts = new uint256[](team.length - 1);
        CreateTeamVestingRobinhood again = new CreateTeamVestingRobinhood();
        vm.expectRevert("beneficiaries/amounts length mismatch");
        again.runWith(cfg);
    }

    function test_run_zeroBeneficiary_reverts() public {
        CreateTeamVestingRobinhood.Config memory cfg = _config();
        cfg.beneficiaries[2] = address(0);
        CreateTeamVestingRobinhood again = new CreateTeamVestingRobinhood();
        vm.expectRevert("zero beneficiary");
        again.runWith(cfg);
    }

    function test_run_duplicateBeneficiary_reverts() public {
        CreateTeamVestingRobinhood.Config memory cfg = _config();
        cfg.beneficiaries[3] = cfg.beneficiaries[1];
        CreateTeamVestingRobinhood again = new CreateTeamVestingRobinhood();
        vm.expectRevert("duplicate beneficiary");
        again.runWith(cfg);
    }

    function test_run_zeroAmount_reverts() public {
        CreateTeamVestingRobinhood.Config memory cfg = _config();
        cfg.amounts[0] = 0;
        CreateTeamVestingRobinhood again = new CreateTeamVestingRobinhood();
        vm.expectRevert("zero amount");
        again.runWith(cfg);
    }

    function test_run_amountTooLarge_reverts() public {
        CreateTeamVestingRobinhood.Config memory cfg = _config();
        cfg.amounts[0] = uint256(type(uint128).max) + 1;
        CreateTeamVestingRobinhood again = new CreateTeamVestingRobinhood();
        vm.expectRevert("amount does not fit uint128");
        again.runWith(cfg);
    }

    function test_run_zeroSender_reverts() public {
        CreateTeamVestingRobinhood.Config memory cfg = _config();
        cfg.sender = address(0);
        CreateTeamVestingRobinhood again = new CreateTeamVestingRobinhood();
        vm.expectRevert("sender is zero");
        again.runWith(cfg);
    }

    function test_run_insufficientBalance_reverts() public {
        // Deployer spent everything in setUp; running again must fail before touching the chain.
        CreateTeamVestingRobinhood.Config memory cfg = _config();
        CreateTeamVestingRobinhood again = new CreateTeamVestingRobinhood();
        vm.expectRevert("deployer lacks vesting tokens");
        again.runWith(cfg);
    }

    function test_run_startInPast_reverts() public {
        token.mint(deployer, total);
        CreateTeamVestingRobinhood.Config memory cfg = _config();
        cfg.start = block.timestamp - 1;
        CreateTeamVestingRobinhood again = new CreateTeamVestingRobinhood();
        vm.expectRevert("start is in the past");
        again.runWith(cfg);
    }

    function test_run_wrongChain_reverts() public {
        token.mint(deployer, total);
        CreateTeamVestingRobinhood.Config memory cfg = _config();
        CreateTeamVestingRobinhood again = new CreateTeamVestingRobinhood();
        vm.chainId(1);
        vm.expectRevert("RPC is not Robinhood Chain (4663)");
        again.runWith(cfg);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      SCHEDULE
    //////////////////////////////////////////////////////////////////////////*/

    function test_schedule_beforeStart_nothing() public {
        vm.warp(start - 1);
        uint256 id = createScript.streamIds(0);
        assertEq(lockup.streamedAmountOf(id), 0);
        assertEq(lockup.withdrawableAmountOf(id), 0);
    }

    function test_schedule_oneSecondBeforeCliff_nothing() public {
        vm.warp(cliffAt - 1);
        for (uint256 i = 0; i < team.length; i++) {
            uint256 id = createScript.streamIds(i);
            assertEq(lockup.streamedAmountOf(id), 0, "nothing before month 1");
            assertTrue(lockup.statusOf(id) == Lockup.Status.STREAMING);
        }
    }

    function test_schedule_atCliff_exactlyThirtyPercent() public {
        vm.warp(cliffAt);
        for (uint256 i = 0; i < team.length; i++) {
            uint256 id = createScript.streamIds(i);
            assertEq(lockup.streamedAmountOf(id), _cliffUnlock(amounts[i]), "30% at month 1");
            assertEq(lockup.withdrawableAmountOf(id), _cliffUnlock(amounts[i]));
        }
    }

    function test_schedule_halfwayThroughLinear_thirtyPlusThirtyFive() public {
        vm.warp(cliffAt + 90 days);
        uint256 id = createScript.streamIds(0);
        assertEq(lockup.streamedAmountOf(id), 650e18, "30% + 70%/2 of 1000");
        for (uint256 i = 0; i < team.length; i++) {
            id = createScript.streamIds(i);
            assertEq(lockup.streamedAmountOf(id), _expectedStreamed(amounts[i], cliffAt + 90 days));
        }
    }

    function test_schedule_atEnd_fullyVested() public {
        vm.warp(endAt);
        for (uint256 i = 0; i < team.length; i++) {
            uint256 id = createScript.streamIds(i);
            assertEq(lockup.streamedAmountOf(id), amounts[i], "100% at month 7");
            assertTrue(lockup.statusOf(id) == Lockup.Status.SETTLED);
        }
        vm.warp(endAt + 365 days);
        assertEq(lockup.streamedAmountOf(createScript.streamIds(0)), amounts[0], "stays fully vested");
    }

    function testFuzz_schedule_matchesFormulaMonotonicAndBounded(
        uint40 t1,
        uint40 t2
    ) public {
        t1 = uint40(bound(t1, start - 1, endAt + 1));
        t2 = uint40(bound(t2, t1, endAt + 1));
        for (uint256 i = 0; i < team.length; i++) {
            uint256 id = createScript.streamIds(i);
            vm.warp(t1);
            uint256 s1 = lockup.streamedAmountOf(id);
            assertEq(s1, _expectedStreamed(amounts[i], t1), "formula");
            vm.warp(t2);
            uint256 s2 = lockup.streamedAmountOf(id);
            assertLe(s1, s2, "monotonic");
            assertLe(s2, amounts[i], "bounded");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     WITHDRAW
    //////////////////////////////////////////////////////////////////////////*/

    function test_withdrawMax_recipientReceivesVestedTokens() public {
        uint256 id = createScript.streamIds(0);
        vm.warp(cliffAt);
        vm.prank(team[0]);
        lockup.withdrawMax(id, team[0]);
        assertEq(token.balanceOf(team[0]), 300e18, "30% at cliff");

        vm.warp(endAt);
        vm.prank(team[0]);
        lockup.withdrawMax(id, team[0]);
        assertEq(token.balanceOf(team[0]), 1000e18, "everything by month 7");
        assertTrue(lockup.statusOf(id) == Lockup.Status.DEPLETED);
    }

    function test_withdraw_beforeCliff_reverts() public {
        uint256 id = createScript.streamIds(0);
        vm.warp(cliffAt - 1);
        vm.prank(team[0]);
        vm.expectRevert(abi.encodeWithSelector(Errors.SablierLockup_Overdraw.selector, id, 1, 0));
        lockup.withdraw(id, team[0], 1);
    }

    function test_withdraw_thirdPartyCannotRedirectFunds() public {
        uint256 id = createScript.streamIds(0);
        vm.warp(cliffAt);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.SablierLockup_WithdrawalAddressNotRecipient.selector, id, attacker, attacker)
        );
        lockup.withdraw(id, attacker, 1);
    }

    function test_withdrawMax_thirdPartyCanOnlyPushToRecipient() public {
        uint256 id = createScript.streamIds(1);
        vm.warp(cliffAt);
        vm.prank(attacker);
        lockup.withdrawMax(id, team[1]);
        assertEq(token.balanceOf(team[1]), _cliffUnlock(amounts[1]));
        assertEq(token.balanceOf(attacker), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  CANCEL / TRANSFER
    //////////////////////////////////////////////////////////////////////////*/

    function test_cancel_senderReclaimsUnvestedRecipientKeepsVested() public {
        uint256 id = createScript.streamIds(0);
        vm.warp(cliffAt + 90 days);
        vm.prank(safe);
        uint128 refunded = lockup.cancel(id);
        assertEq(refunded, 350e18, "unvested 35% refunded");
        assertEq(token.balanceOf(safe), 350e18);
        assertTrue(lockup.statusOf(id) == Lockup.Status.CANCELED);

        vm.warp(endAt + 1);
        vm.prank(team[0]);
        lockup.withdrawMax(id, team[0]);
        assertEq(token.balanceOf(team[0]), 650e18, "vested 65% stays with the recipient");
    }

    function test_cancel_notSender_reverts() public {
        uint256 id = createScript.streamIds(0);
        vm.prank(team[0]);
        vm.expectRevert(abi.encodeWithSelector(Errors.SablierLockup_Unauthorized.selector, id, team[0]));
        lockup.cancel(id);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Errors.SablierLockup_Unauthorized.selector, id, deployer));
        lockup.cancel(id);
    }

    function test_transfer_streamNftNotTransferable() public {
        uint256 id = createScript.streamIds(0);
        vm.prank(team[0]);
        vm.expectRevert(abi.encodeWithSelector(Errors.SablierLockup_NotTransferable.selector, id));
        IERC721(address(lockup)).transferFrom(team[0], attacker, id);
    }
}
