// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployTeamVestingRobinhood} from "../../script/robinhood/DeployTeamVestingRobinhood.s.sol";

import {Actors} from "../helpers/Actors.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @dev End-to-end test of the team vesting deploy script: 5 OpenZeppelin VestingWallets on a
///      Robinhood-chain-id fork, each vesting linearly over 6 × 30 days from `start`.
contract DeployTeamVestingRobinhoodTest is Test {
    uint256 internal constant DEPLOYER_KEY = 0xA11CE;
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint64 internal constant DURATION = 180 days;

    address internal deployer = vm.addr(DEPLOYER_KEY);
    address internal safe = Actors.ADMIN;
    address internal attacker = Actors.ATTACKER;

    MockERC20 internal token;
    DeployTeamVestingRobinhood internal script;

    address[] internal team;
    uint256[] internal amounts;
    uint256 internal total;
    uint64 internal start;
    uint64 internal endAt;

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
        token.mint(safe, total);

        start = uint64(block.timestamp + 1 days);
        endAt = start + DURATION;

        // Env vars are process-global and tests run in parallel, so every test sets identical values
        // here and routes variations through `runWith` instead of touching env.
        vm.setEnv("DEPLOYER_PRIVATE_KEY_ROBINHOOD", vm.toString(DEPLOYER_KEY));
        vm.setEnv("VESTING_TOKEN_ROBINHOOD", vm.toString(address(token)));
        vm.setEnv("VESTING_BENEFICIARIES_ROBINHOOD", _csvAddresses(team));
        vm.setEnv("VESTING_AMOUNTS_ROBINHOOD", _csvUints(amounts));
        vm.setEnv("VESTING_START_ROBINHOOD", vm.toString(uint256(start)));

        script = new DeployTeamVestingRobinhood();
        script.run();
        _fundFromSafe();
    }

    /// @dev Mirrors the Safe batch the script prints: one plain transfer per wallet.
    function _fundFromSafe() internal {
        for (uint256 i = 0; i < team.length; i++) {
            address wallet = address(script.wallets(i));
            vm.prank(safe);
            token.transfer(wallet, amounts[i]);
        }
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

    function _config() internal view returns (DeployTeamVestingRobinhood.Config memory cfg) {
        cfg.deployerKey = DEPLOYER_KEY;
        cfg.token = IERC20(address(token));
        cfg.beneficiaries = team;
        cfg.amounts = amounts;
        cfg.start = start;
    }

    function _expectedVested(
        uint256 amount,
        uint64 at
    ) internal view returns (uint256) {
        if (at < start) return 0;
        if (at >= endAt) return amount;
        return amount * (at - start) / DURATION;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                       DEPLOY
    //////////////////////////////////////////////////////////////////////////*/

    function test_run_deploysOneEmptyWalletPerBeneficiary() public {
        DeployTeamVestingRobinhood fresh = new DeployTeamVestingRobinhood();
        fresh.runWith(_config());
        for (uint256 i = 0; i < team.length; i++) {
            VestingWallet wallet = fresh.wallets(i);
            assertEq(wallet.owner(), team[i], "beneficiary owns the wallet");
            assertEq(wallet.start(), start, "start");
            assertEq(wallet.duration(), DURATION, "duration");
            assertEq(wallet.end(), endAt, "end");
            assertEq(token.balanceOf(address(wallet)), 0, "deployed empty; the Safe funds it");
            assertEq(wallet.released(address(token)), 0, "nothing released yet");
        }
        assertEq(token.balanceOf(deployer), 0, "deployer never holds the tokens");
    }

    function test_run_deployerHasNoRightsOnWallets() public {
        VestingWallet wallet = script.wallets(0);
        assertTrue(wallet.owner() != deployer, "deployer is not the owner");
        vm.prank(deployer);
        vm.expectRevert();
        wallet.transferOwnership(deployer);
        assertEq(wallet.owner(), team[0]);
    }

    function test_fundFromSafe_walletsHoldExactAllocations() public view {
        assertEq(token.balanceOf(safe), 0, "Safe transferred everything");
        for (uint256 i = 0; i < team.length; i++) {
            assertEq(token.balanceOf(address(script.wallets(i))), amounts[i], "funded with the allocation");
        }
    }

    function test_fundFromSafe_afterStart_elapsedShareReleasableAtOnce() public {
        // Fresh wallets, funded 60 days after start: the schedule is anchored to start, not funding.
        DeployTeamVestingRobinhood fresh = new DeployTeamVestingRobinhood();
        fresh.runWith(_config());
        VestingWallet wallet = fresh.wallets(0);
        token.mint(safe, 900e18);
        vm.warp(start + 60 days);
        vm.prank(safe);
        token.transfer(address(wallet), 900e18);
        assertEq(wallet.releasable(address(token)), 300e18, "60/180 of the late deposit");
    }

    function test_run_lengthMismatch_reverts() public {
        DeployTeamVestingRobinhood.Config memory cfg = _config();
        cfg.amounts = new uint256[](team.length - 1);
        DeployTeamVestingRobinhood again = new DeployTeamVestingRobinhood();
        vm.expectRevert("beneficiaries/amounts length mismatch");
        again.runWith(cfg);
    }

    function test_run_zeroBeneficiary_reverts() public {
        DeployTeamVestingRobinhood.Config memory cfg = _config();
        cfg.beneficiaries[2] = address(0);
        DeployTeamVestingRobinhood again = new DeployTeamVestingRobinhood();
        vm.expectRevert("zero beneficiary");
        again.runWith(cfg);
    }

    function test_run_duplicateBeneficiary_reverts() public {
        DeployTeamVestingRobinhood.Config memory cfg = _config();
        cfg.beneficiaries[3] = cfg.beneficiaries[1];
        DeployTeamVestingRobinhood again = new DeployTeamVestingRobinhood();
        vm.expectRevert("duplicate beneficiary");
        again.runWith(cfg);
    }

    function test_run_zeroAmount_reverts() public {
        DeployTeamVestingRobinhood.Config memory cfg = _config();
        cfg.amounts[0] = 0;
        DeployTeamVestingRobinhood again = new DeployTeamVestingRobinhood();
        vm.expectRevert("zero amount");
        again.runWith(cfg);
    }

    function test_run_startInPast_reverts() public {
        DeployTeamVestingRobinhood.Config memory cfg = _config();
        cfg.start = block.timestamp - 1;
        DeployTeamVestingRobinhood again = new DeployTeamVestingRobinhood();
        vm.expectRevert("start is in the past");
        again.runWith(cfg);
    }

    function test_run_tokenNotContract_reverts() public {
        DeployTeamVestingRobinhood.Config memory cfg = _config();
        cfg.token = IERC20(attacker);
        DeployTeamVestingRobinhood again = new DeployTeamVestingRobinhood();
        vm.expectRevert("token is not a contract");
        again.runWith(cfg);
    }

    function test_run_wrongChain_reverts() public {
        DeployTeamVestingRobinhood.Config memory cfg = _config();
        DeployTeamVestingRobinhood again = new DeployTeamVestingRobinhood();
        vm.chainId(1);
        vm.expectRevert("RPC is not Robinhood Chain (4663)");
        again.runWith(cfg);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      SCHEDULE
    //////////////////////////////////////////////////////////////////////////*/

    function test_schedule_beforeStart_nothing() public {
        vm.warp(start - 1);
        for (uint256 i = 0; i < team.length; i++) {
            assertEq(script.wallets(i).releasable(address(token)), 0);
        }
    }

    function test_schedule_oneThirdThrough_oneThirdVested() public {
        vm.warp(start + 60 days);
        assertEq(script.wallets(0).releasable(address(token)), uint256(1000e18) / 3, "1000 * 60/180");
        for (uint256 i = 0; i < team.length; i++) {
            assertEq(script.wallets(i).releasable(address(token)), _expectedVested(amounts[i], start + 60 days));
        }
    }

    function test_schedule_atEnd_fullyVested() public {
        vm.warp(endAt);
        for (uint256 i = 0; i < team.length; i++) {
            assertEq(script.wallets(i).releasable(address(token)), amounts[i], "100% after 6 months");
        }
        vm.warp(endAt + 365 days);
        assertEq(script.wallets(4).releasable(address(token)), 1001, "dust fully vests, stays vested");
    }

    function testFuzz_schedule_matchesFormulaMonotonicAndBounded(
        uint64 t1,
        uint64 t2
    ) public {
        t1 = uint64(bound(t1, start - 1, endAt + 1));
        t2 = uint64(bound(t2, t1, endAt + 1));
        for (uint256 i = 0; i < team.length; i++) {
            VestingWallet wallet = script.wallets(i);
            vm.warp(t1);
            uint256 v1 = wallet.vestedAmount(address(token), t1);
            assertEq(v1, _expectedVested(amounts[i], t1), "formula");
            uint256 v2 = wallet.vestedAmount(address(token), t2);
            assertLe(v1, v2, "monotonic");
            assertLe(v2, amounts[i], "bounded");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      RELEASE
    //////////////////////////////////////////////////////////////////////////*/

    function test_release_beneficiaryReceivesVestedTokens() public {
        VestingWallet wallet = script.wallets(0);
        vm.warp(start + 90 days);
        vm.prank(team[0]);
        wallet.release(address(token));
        assertEq(token.balanceOf(team[0]), 500e18, "half after 3 months");

        vm.warp(endAt);
        vm.prank(team[0]);
        wallet.release(address(token));
        assertEq(token.balanceOf(team[0]), 1000e18, "everything after 6 months");
        assertEq(token.balanceOf(address(wallet)), 0);
    }

    function test_release_anyoneCanTriggerFundsGoToBeneficiaryOnly() public {
        VestingWallet wallet = script.wallets(1);
        vm.warp(start + 90 days);
        vm.prank(attacker);
        wallet.release(address(token));
        assertEq(token.balanceOf(team[1]), 1000e18, "half of 2000 to the beneficiary");
        assertEq(token.balanceOf(attacker), 0, "caller gets nothing");
    }

    function test_release_beforeStart_releasesNothing() public {
        VestingWallet wallet = script.wallets(0);
        vm.warp(start - 1);
        vm.prank(team[0]);
        wallet.release(address(token));
        assertEq(token.balanceOf(team[0]), 0);
        assertEq(token.balanceOf(address(wallet)), amounts[0]);
    }
}
