// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EToken} from "../../../src/tokens/EToken.sol";

import {Actors} from "../../helpers/Actors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title ETokenHandler — Invariant test handler for EToken
/// @notice Exercises eToken transfers and dividend (rewards) flows.
contract ETokenHandler is CommonBase, StdCheats, StdUtils {
    EToken public eTSLA;
    MockERC20 public usdc; // reward token

    address[] public holders;

    // ── Ghost variables ─────────────────────────────────────────

    uint256 public ghost_rewardsDeposited;
    uint256 public ghost_rewardsClaimed;
    uint256 public ghost_lastRewardsPerShare;

    // ── Constructor ─────────────────────────────────────────────

    constructor(address _eTSLA, address _usdc) {
        eTSLA = EToken(_eTSLA);
        usdc = MockERC20(_usdc);

        holders.push(Actors.MINTER1);
        holders.push(Actors.MINTER2);
    }

    // ── Handler functions ───────────────────────────────────────

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = holders[bound(fromSeed, 0, holders.length - 1)];
        address to = holders[bound(toSeed, 0, holders.length - 1)];
        if (from == to) return;

        uint256 bal = eTSLA.balanceOf(from);
        if (bal == 0) return;

        amount = bound(amount, 1, bal);

        vm.prank(from);
        eTSLA.transfer(to, amount);
    }

    function depositRewards(
        uint256 amount
    ) external {
        uint256 supply = eTSLA.totalSupply();
        if (supply == 0) return;

        amount = bound(amount, 1, 10_000e6); // 1 wei to 10k USDC

        usdc.mint(address(this), amount);
        usdc.approve(address(eTSLA), amount);
        eTSLA.depositRewards(amount);

        ghost_rewardsDeposited += amount;
        ghost_lastRewardsPerShare = eTSLA.rewardsPerShare();
    }

    function claimRewards(
        uint256 actorSeed
    ) external {
        address holder = holders[bound(actorSeed, 0, holders.length - 1)];
        uint256 claimable = eTSLA.claimableRewards(holder);
        if (claimable == 0) return;

        vm.prank(holder);
        uint256 amount = eTSLA.claimRewards();
        ghost_rewardsClaimed += amount;
    }
}
