// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEToken} from "../../src/interfaces/IEToken.sol";

import {PRECISION} from "../../src/interfaces/types/Types.sol";
import {EToken} from "../../src/tokens/EToken.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @title EToken Unit Tests
/// @notice Tests ERC-20 compliance, permit, restricted mint/burn, admin name/symbol
///         updates, and rewards-per-share dividend accumulator.
contract ETokenTest is BaseTest {
    EToken public eToken;
    MockERC20 public rewardToken;

    bytes32 constant TICKER = bytes32("TSLA");
    string constant NAME = "Own TSLA";
    string constant SYMBOL = "eTSLA";

    function setUp() public override {
        super.setUp();

        rewardToken = new MockERC20("Reward USDC", "rUSDC", 6);
        vm.label(address(rewardToken), "rewardToken");

        // Register this test contract as the MARKET (orderSystem) in registry
        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(this));
        vm.stopPrank();
        eToken = new EToken(NAME, SYMBOL, TICKER, address(protocolRegistry), address(rewardToken));
        vm.label(address(eToken), "eTSLA");
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-20 basics
    // ──────────────────────────────────────────────────────────

    function test_constructor_setsNameSymbolDecimals() public view {
        assertEq(eToken.name(), NAME);
        assertEq(eToken.symbol(), SYMBOL);
        assertEq(eToken.decimals(), 18);
    }

    function test_constructor_setsTicker() public view {
        assertEq(eToken.ticker(), TICKER);
    }

    function test_constructor_setsRewardToken() public view {
        assertEq(eToken.rewardToken(), address(rewardToken));
    }

    function test_constructor_initialSupplyZero() public view {
        assertEq(eToken.totalSupply(), 0);
    }

    function test_transfer_movesTokens() public {
        eToken.mint(Actors.MINTER1, 100e18);

        vm.prank(Actors.MINTER1);
        eToken.transfer(Actors.MINTER2, 40e18);

        assertEq(eToken.balanceOf(Actors.MINTER1), 60e18);
        assertEq(eToken.balanceOf(Actors.MINTER2), 40e18);
    }

    function test_transfer_zeroAmount_succeeds() public {
        eToken.mint(Actors.MINTER1, 100e18);

        vm.prank(Actors.MINTER1);
        eToken.transfer(Actors.MINTER2, 0);

        assertEq(eToken.balanceOf(Actors.MINTER1), 100e18);
    }

    function test_transfer_insufficientBalance_reverts() public {
        eToken.mint(Actors.MINTER1, 100e18);

        vm.prank(Actors.MINTER1);
        vm.expectRevert();
        eToken.transfer(Actors.MINTER2, 101e18);
    }

    function test_approve_setsAllowance() public {
        vm.prank(Actors.MINTER1);
        eToken.approve(Actors.MINTER2, 50e18);

        assertEq(eToken.allowance(Actors.MINTER1, Actors.MINTER2), 50e18);
    }

    function test_transferFrom_movesTokens() public {
        eToken.mint(Actors.MINTER1, 100e18);

        vm.prank(Actors.MINTER1);
        eToken.approve(Actors.MINTER2, 60e18);

        vm.prank(Actors.MINTER2);
        eToken.transferFrom(Actors.MINTER1, Actors.LP1, 40e18);

        assertEq(eToken.balanceOf(Actors.MINTER1), 60e18);
        assertEq(eToken.balanceOf(Actors.LP1), 40e18);
        assertEq(eToken.allowance(Actors.MINTER1, Actors.MINTER2), 20e18);
    }

    function test_transferFrom_insufficientAllowance_reverts() public {
        eToken.mint(Actors.MINTER1, 100e18);

        vm.prank(Actors.MINTER1);
        eToken.approve(Actors.MINTER2, 10e18);

        vm.prank(Actors.MINTER2);
        vm.expectRevert();
        eToken.transferFrom(Actors.MINTER1, Actors.LP1, 50e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Restricted mint/burn
    // ──────────────────────────────────────────────────────────

    function test_mint_orderSystem_succeeds() public {
        // address(this) is the orderSystem
        vm.expectEmit(true, false, false, true);
        emit IEToken.Minted(Actors.MINTER1, 100e18);

        eToken.mint(Actors.MINTER1, 100e18);

        assertEq(eToken.balanceOf(Actors.MINTER1), 100e18);
        assertEq(eToken.totalSupply(), 100e18);
    }

    function test_mint_nonOrderSystem_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IEToken.Unauthorized.selector);
        eToken.mint(Actors.ATTACKER, 100e18);
    }

    function test_mint_zeroAmount_reverts() public {
        vm.expectRevert(IEToken.ZeroAmount.selector);
        eToken.mint(Actors.MINTER1, 0);
    }

    function test_mint_zeroAddress_reverts() public {
        vm.expectRevert(IEToken.ZeroAddress.selector);
        eToken.mint(address(0), 100e18);
    }

    function test_burn_orderSystem_succeeds() public {
        eToken.mint(Actors.MINTER1, 100e18);

        vm.expectEmit(true, false, false, true);
        emit IEToken.Burned(Actors.MINTER1, 40e18);

        eToken.burn(Actors.MINTER1, 40e18);

        assertEq(eToken.balanceOf(Actors.MINTER1), 60e18);
        assertEq(eToken.totalSupply(), 60e18);
    }

    function test_burn_nonOrderSystem_reverts() public {
        eToken.mint(Actors.MINTER1, 100e18);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IEToken.Unauthorized.selector);
        eToken.burn(Actors.MINTER1, 50e18);
    }

    function test_burn_zeroAmount_reverts() public {
        vm.expectRevert(IEToken.ZeroAmount.selector);
        eToken.burn(Actors.MINTER1, 0);
    }

    function test_burn_exceedsBalance_reverts() public {
        eToken.mint(Actors.MINTER1, 100e18);

        vm.expectRevert();
        eToken.burn(Actors.MINTER1, 101e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin: name/symbol update
    // ──────────────────────────────────────────────────────────

    function test_updateName_admin_succeeds() public {
        vm.expectEmit(false, false, false, true);
        emit IEToken.NameUpdated(NAME, "Own TSLA v2");

        vm.prank(Actors.ADMIN);
        eToken.updateName("Own TSLA v2");

        assertEq(eToken.name(), "Own TSLA v2");
    }

    function test_updateName_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        eToken.updateName("Hacked");
    }

    function test_updateSymbol_admin_succeeds() public {
        vm.expectEmit(false, false, false, true);
        emit IEToken.SymbolUpdated(SYMBOL, "eTSLAv2");

        vm.prank(Actors.ADMIN);
        eToken.updateSymbol("eTSLAv2");

        assertEq(eToken.symbol(), "eTSLAv2");
    }

    function test_updateSymbol_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        eToken.updateSymbol("HACKED");
    }

    // ──────────────────────────────────────────────────────────
    //  Rewards: deposit
    // ──────────────────────────────────────────────────────────

    function test_depositRewards_updatesAccumulator() public {
        // Mint eTokens to holder so there's a non-zero supply
        eToken.mint(Actors.MINTER1, 100e18);

        // Fund and approve reward tokens
        uint256 rewardAmount = 1000e6; // 1000 USDC (6 decimals)
        rewardToken.mint(address(this), rewardAmount);
        rewardToken.approve(address(eToken), rewardAmount);

        vm.expectEmit(false, false, false, true);
        emit IEToken.RewardsDeposited(rewardAmount, (rewardAmount * PRECISION) / 100e18);

        eToken.depositRewards(rewardAmount);

        assertEq(eToken.rewardsPerShare(), (rewardAmount * PRECISION) / 100e18);
    }

    function test_depositRewards_zeroAmount_reverts() public {
        vm.expectRevert(IEToken.ZeroAmount.selector);
        eToken.depositRewards(0);
    }

    function test_depositRewards_zeroSupply_reverts() public {
        // No eTokens minted, so totalSupply == 0
        uint256 rewardAmount = 1000e6;
        rewardToken.mint(address(this), rewardAmount);
        rewardToken.approve(address(eToken), rewardAmount);

        vm.expectRevert(); // Division by zero or explicit check
        eToken.depositRewards(rewardAmount);
    }

    // ──────────────────────────────────────────────────────────
    //  Rewards: claim
    // ──────────────────────────────────────────────────────────

    function test_claimRewards_singleHolder_claimsAll() public {
        eToken.mint(Actors.MINTER1, 100e18);

        uint256 rewardAmount = 1000e6;
        rewardToken.mint(address(this), rewardAmount);
        rewardToken.approve(address(eToken), rewardAmount);
        eToken.depositRewards(rewardAmount);

        uint256 claimable = eToken.claimableRewards(Actors.MINTER1);
        assertEq(claimable, rewardAmount);

        vm.expectEmit(true, false, false, true);
        emit IEToken.RewardsClaimed(Actors.MINTER1, rewardAmount);

        vm.prank(Actors.MINTER1);
        uint256 claimed = eToken.claimRewards();

        assertEq(claimed, rewardAmount);
        assertEq(rewardToken.balanceOf(Actors.MINTER1), rewardAmount);
        assertEq(eToken.claimableRewards(Actors.MINTER1), 0);
    }

    function test_claimRewards_multipleHolders_proportional() public {
        // Minter1 gets 75%, Minter2 gets 25%
        eToken.mint(Actors.MINTER1, 75e18);
        eToken.mint(Actors.MINTER2, 25e18);

        uint256 rewardAmount = 1000e6;
        rewardToken.mint(address(this), rewardAmount);
        rewardToken.approve(address(eToken), rewardAmount);
        eToken.depositRewards(rewardAmount);

        assertEq(eToken.claimableRewards(Actors.MINTER1), 750e6);
        assertEq(eToken.claimableRewards(Actors.MINTER2), 250e6);
    }

    function test_claimRewards_noRewards_reverts() public {
        eToken.mint(Actors.MINTER1, 100e18);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(IEToken.NoRewardsToClaim.selector);
        eToken.claimRewards();
    }

    function test_claimRewards_doubleClaim_reverts() public {
        eToken.mint(Actors.MINTER1, 100e18);

        uint256 rewardAmount = 1000e6;
        rewardToken.mint(address(this), rewardAmount);
        rewardToken.approve(address(eToken), rewardAmount);
        eToken.depositRewards(rewardAmount);

        vm.prank(Actors.MINTER1);
        eToken.claimRewards();

        // Second claim should revert — no new rewards
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IEToken.NoRewardsToClaim.selector);
        eToken.claimRewards();
    }

    function test_claimRewards_multipleDeposits_accumulates() public {
        eToken.mint(Actors.MINTER1, 100e18);

        // Deposit 1
        uint256 r1 = 500e6;
        rewardToken.mint(address(this), r1);
        rewardToken.approve(address(eToken), r1);
        eToken.depositRewards(r1);

        // Deposit 2
        uint256 r2 = 300e6;
        rewardToken.mint(address(this), r2);
        rewardToken.approve(address(eToken), r2);
        eToken.depositRewards(r2);

        assertEq(eToken.claimableRewards(Actors.MINTER1), 800e6);
    }

    // ──────────────────────────────────────────────────────────
    //  Rewards: transfer settlement
    // ──────────────────────────────────────────────────────────

    function test_transfer_settlesRewardsForBothParties() public {
        // Minter1 holds tokens when rewards are deposited
        eToken.mint(Actors.MINTER1, 100e18);

        uint256 rewardAmount = 1000e6;
        rewardToken.mint(address(this), rewardAmount);
        rewardToken.approve(address(eToken), rewardAmount);
        eToken.depositRewards(rewardAmount);

        // Before transfer: minter1 has 1000 claimable, minter2 has 0
        assertEq(eToken.claimableRewards(Actors.MINTER1), 1000e6);
        assertEq(eToken.claimableRewards(Actors.MINTER2), 0);

        // Transfer 50% to minter2
        vm.prank(Actors.MINTER1);
        eToken.transfer(Actors.MINTER2, 50e18);

        // After transfer: minter1's accrued rewards are settled (still claimable)
        // minter1 should still have 1000 claimable (earned before transfer)
        // minter2 should have 0 claimable (just received tokens, no new rewards yet)
        assertEq(eToken.claimableRewards(Actors.MINTER1), 1000e6);
        assertEq(eToken.claimableRewards(Actors.MINTER2), 0);

        // New rewards deposited after transfer
        uint256 r2 = 500e6;
        rewardToken.mint(address(this), r2);
        rewardToken.approve(address(eToken), r2);
        eToken.depositRewards(r2);

        // Now both share 50/50 of new rewards
        assertEq(eToken.claimableRewards(Actors.MINTER1), 1000e6 + 250e6);
        assertEq(eToken.claimableRewards(Actors.MINTER2), 250e6);
    }

    function test_transfer_doesNotLoseUnclaimedRewards() public {
        eToken.mint(Actors.MINTER1, 100e18);

        uint256 rewardAmount = 1000e6;
        rewardToken.mint(address(this), rewardAmount);
        rewardToken.approve(address(eToken), rewardAmount);
        eToken.depositRewards(rewardAmount);

        // Transfer all tokens — minter1 should still be able to claim
        vm.prank(Actors.MINTER1);
        eToken.transfer(Actors.MINTER2, 100e18);

        // Minter1 still has rewards from before
        vm.prank(Actors.MINTER1);
        uint256 claimed = eToken.claimRewards();
        assertEq(claimed, 1000e6);
    }

    // ──────────────────────────────────────────────────────────
    //  Rewards: mint/burn reward settlement
    // ──────────────────────────────────────────────────────────

    function test_mint_settlesExistingRewards() public {
        eToken.mint(Actors.MINTER1, 100e18);

        uint256 rewardAmount = 1000e6;
        rewardToken.mint(address(this), rewardAmount);
        rewardToken.approve(address(eToken), rewardAmount);
        eToken.depositRewards(rewardAmount);

        // Mint more to minter1 — should settle existing rewards first
        eToken.mint(Actors.MINTER1, 50e18);

        // Minter1 should still have 1000 claimable from before the extra mint
        assertEq(eToken.claimableRewards(Actors.MINTER1), 1000e6);
    }

    function test_burn_settlesExistingRewards() public {
        eToken.mint(Actors.MINTER1, 100e18);

        uint256 rewardAmount = 1000e6;
        rewardToken.mint(address(this), rewardAmount);
        rewardToken.approve(address(eToken), rewardAmount);
        eToken.depositRewards(rewardAmount);

        // Burn some — should settle existing rewards first
        eToken.burn(Actors.MINTER1, 50e18);

        // Minter1 should still have 1000 claimable from before the burn
        assertEq(eToken.claimableRewards(Actors.MINTER1), 1000e6);
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-2612 Permit
    // ──────────────────────────────────────────────────────────

    function test_permit_setsAllowance() public {
        uint256 ownerPk = 0xA11CE;
        address owner = vm.addr(ownerPk);
        address spender = Actors.MINTER2;
        uint256 value = 100e18;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 domainSeparator = eToken.DOMAIN_SEPARATOR();
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, spender, value, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        eToken.permit(owner, spender, value, deadline, v, r, s);

        assertEq(eToken.allowance(owner, spender), value);
        assertEq(eToken.nonces(owner), 1);
    }

    function test_permit_expiredDeadline_reverts() public {
        uint256 ownerPk = 0xA11CE;
        address owner = vm.addr(ownerPk);
        address spender = Actors.MINTER2;
        uint256 value = 100e18;
        uint256 deadline = block.timestamp - 1; // expired

        bytes32 domainSeparator = eToken.DOMAIN_SEPARATOR();
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, spender, value, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        vm.expectRevert();
        eToken.permit(owner, spender, value, deadline, v, r, s);
    }

    // ──────────────────────────────────────────────────────────
    //  Edge cases
    // ──────────────────────────────────────────────────────────

    function test_mint_maxUint256_succeeds() public {
        eToken.mint(Actors.MINTER1, type(uint256).max);
        assertEq(eToken.balanceOf(Actors.MINTER1), type(uint256).max);
    }

    function test_mint_toMultipleRecipients_tracksTotalSupply() public {
        eToken.mint(Actors.MINTER1, 100e18);
        eToken.mint(Actors.MINTER2, 200e18);
        eToken.mint(Actors.LP1, 50e18);

        assertEq(eToken.totalSupply(), 350e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Fuzz tests
    // ──────────────────────────────────────────────────────────

    function testFuzz_mint_burn_balanceConsistent(uint256 mintAmount, uint256 burnAmount) public {
        mintAmount = bound(mintAmount, 1, type(uint128).max);
        burnAmount = bound(burnAmount, 1, mintAmount);

        eToken.mint(Actors.MINTER1, mintAmount);
        eToken.burn(Actors.MINTER1, burnAmount);

        assertEq(eToken.balanceOf(Actors.MINTER1), mintAmount - burnAmount);
        assertEq(eToken.totalSupply(), mintAmount - burnAmount);
    }

    function testFuzz_transfer_conservesTotalSupply(uint256 amount, uint256 transferAmount) public {
        amount = bound(amount, 1, type(uint128).max);
        transferAmount = bound(transferAmount, 0, amount);

        eToken.mint(Actors.MINTER1, amount);

        vm.prank(Actors.MINTER1);
        eToken.transfer(Actors.MINTER2, transferAmount);

        assertEq(eToken.totalSupply(), amount);
        assertEq(eToken.balanceOf(Actors.MINTER1) + eToken.balanceOf(Actors.MINTER2), amount);
    }

    function testFuzz_rewards_proportionalDistribution(uint256 balance1, uint256 balance2, uint256 reward) public {
        // Constrain to realistic ranges where precision loss is manageable
        balance1 = bound(balance1, 1e18, 100_000e18);
        balance2 = bound(balance2, 1e18, 100_000e18);
        reward = bound(reward, 100e6, 1_000_000e6); // min 100 USDC to avoid dust

        eToken.mint(Actors.MINTER1, balance1);
        eToken.mint(Actors.MINTER2, balance2);

        rewardToken.mint(address(this), reward);
        rewardToken.approve(address(eToken), reward);
        eToken.depositRewards(reward);

        uint256 claimable1 = eToken.claimableRewards(Actors.MINTER1);
        uint256 claimable2 = eToken.claimableRewards(Actors.MINTER2);

        // Core invariant: total claimable must not exceed deposited rewards
        assertLe(claimable1 + claimable2, reward);

        // Each holder's share should be roughly proportional
        // Use relative check: claimable1/claimable2 ≈ balance1/balance2
        // This avoids precision issues in the expected calculation itself
        if (claimable1 > 0 && claimable2 > 0) {
            // ratio1 = claimable1 * balance2, ratio2 = claimable2 * balance1
            // They should be approximately equal
            uint256 ratio1 = claimable1 * balance2;
            uint256 ratio2 = claimable2 * balance1;
            // Allow 0.1% relative tolerance
            assertApproxEqRel(ratio1, ratio2, 1e15);
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Pass-through holders (custodian dividend redirection)
    // ──────────────────────────────────────────────────────────

    /// @dev Setup helper: mint to MINTER1, register a "lending contract" address
    ///      as a pass-through holder, then deposit rewards.
    function _setupPassThroughCase() internal returns (address lender, uint256 rewardAmount, uint256 startBalance) {
        lender = makeAddr("lendingContract");
        startBalance = 100e18;
        rewardAmount = 100e6; // 100 reward tokens

        eToken.mint(Actors.MINTER1, startBalance);

        vm.prank(Actors.ADMIN);
        eToken.setPassThroughHolder(lender, true);
    }

    function test_setPassThroughHolder_setsFlagAndEmits() public {
        address lender = makeAddr("lender");

        vm.prank(Actors.ADMIN);
        vm.expectEmit(true, false, false, true);
        emit IEToken.PassThroughHolderUpdated(lender, true);
        eToken.setPassThroughHolder(lender, true);

        assertTrue(eToken.isPassThroughHolder(lender));

        vm.prank(Actors.ADMIN);
        eToken.setPassThroughHolder(lender, false);
        assertFalse(eToken.isPassThroughHolder(lender));
    }

    function test_setPassThroughHolder_zeroAddress_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IEToken.ZeroAddress.selector);
        eToken.setPassThroughHolder(address(0), true);
    }

    function test_setPassThroughHolder_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IEToken.Unauthorized.selector);
        eToken.setPassThroughHolder(makeAddr("x"), true);
    }

    /// @dev Single borrower posts collateral, dividend accrues during borrow,
    ///      rewards redirect to borrower on collateral return.
    function test_passThrough_singleBorrower_redirectsOnReturn() public {
        (address lender, uint256 reward, uint256 amount) = _setupPassThroughCase();

        // Borrower transfers all 100 to lender; rewards earned to date are 0
        // (no deposit yet), so nothing accrues to MINTER1.
        vm.prank(Actors.MINTER1);
        eToken.transfer(lender, amount);
        assertEq(eToken.claimableRewards(Actors.MINTER1), 0);

        // Dividend deposit while lender holds the eTokens.
        rewardToken.mint(address(this), reward);
        rewardToken.approve(address(eToken), reward);
        eToken.depositRewards(reward);

        // Lender claimable should be all of the reward (it's the sole holder).
        assertEq(eToken.claimableRewards(lender), reward);
        assertEq(eToken.claimableRewards(Actors.MINTER1), 0);

        // Lender returns the entire balance to MINTER1. Pass-through redirects
        // the lender's accrued slice (100% of `amount/amount`) to MINTER1.
        vm.prank(lender);
        eToken.transfer(Actors.MINTER1, amount);

        assertEq(eToken.claimableRewards(lender), 0, "lender keeps nothing");
        assertEq(eToken.claimableRewards(Actors.MINTER1), reward, "minter recovers reward");
    }

    /// @dev Two borrowers share custody. When one withdraws, only their pro-rata
    ///      slice of the lender's accrued bucket follows them.
    function test_passThrough_multiBorrower_proRataRedirect() public {
        address lender = makeAddr("lendingContract");
        uint256 reward = 100e6;

        eToken.mint(Actors.MINTER1, 75e18);
        eToken.mint(Actors.MINTER2, 25e18);

        vm.prank(Actors.ADMIN);
        eToken.setPassThroughHolder(lender, true);

        // Both transfer their entire balance to the lender (custody).
        vm.prank(Actors.MINTER1);
        eToken.transfer(lender, 75e18);
        vm.prank(Actors.MINTER2);
        eToken.transfer(lender, 25e18);

        // Reward accrues entirely to lender's bucket (sole holder of 100e18).
        rewardToken.mint(address(this), reward);
        rewardToken.approve(address(eToken), reward);
        eToken.depositRewards(reward);

        assertEq(eToken.claimableRewards(lender), reward);

        // MINTER1 withdraws 75% of the custody pool. Should receive 75% of accrued.
        vm.prank(lender);
        eToken.transfer(Actors.MINTER1, 75e18);

        // 75 / 100 of reward → MINTER1.
        uint256 expectedM1 = reward * 75 / 100;
        assertApproxEqAbs(eToken.claimableRewards(Actors.MINTER1), expectedM1, 1);
        // Remainder still credited to lender bucket pending MINTER2 withdrawal.
        assertApproxEqAbs(eToken.claimableRewards(lender), reward - expectedM1, 1);

        // MINTER2 withdraws their 25e18.
        vm.prank(lender);
        eToken.transfer(Actors.MINTER2, 25e18);

        // After MINTER2 withdraw, lender bucket fully drained, MINTER2 gets the rest.
        assertApproxEqAbs(eToken.claimableRewards(Actors.MINTER2), reward - expectedM1, 1);
        assertEq(eToken.claimableRewards(lender), 0);
    }

    /// @dev Liquidator path: lender → liquidator transfer redirects rewards to
    ///      the liquidator (decision: liquidator gets the rewards on seized
    ///      collateral, by design).
    function test_passThrough_liquidatorReceivesRewards() public {
        (address lender, uint256 reward, uint256 amount) = _setupPassThroughCase();

        vm.prank(Actors.MINTER1);
        eToken.transfer(lender, amount);

        rewardToken.mint(address(this), reward);
        rewardToken.approve(address(eToken), reward);
        eToken.depositRewards(reward);

        // Lender liquidates → seizes half of the collateral to liquidator.
        uint256 seize = amount / 2;
        vm.prank(lender);
        eToken.transfer(Actors.LIQUIDATOR, seize);

        assertApproxEqAbs(eToken.claimableRewards(Actors.LIQUIDATOR), reward / 2, 1);
        assertApproxEqAbs(eToken.claimableRewards(lender), reward / 2, 1);
        assertEq(eToken.claimableRewards(Actors.MINTER1), 0);
    }

    /// @dev Lender → another pass-through holder transfer should NOT redirect:
    ///      both are custodians, so the receiving custodian inherits the
    ///      bookkeeping. Currently no second custodian exists in the test, but
    ///      the behaviour is verified by the gating condition in `_update`.
    function test_passThrough_holderToHolder_noRedirect() public {
        (address lender, uint256 reward, uint256 amount) = _setupPassThroughCase();

        address otherHolder = makeAddr("otherCustodian");
        vm.prank(Actors.ADMIN);
        eToken.setPassThroughHolder(otherHolder, true);

        vm.prank(Actors.MINTER1);
        eToken.transfer(lender, amount);

        rewardToken.mint(address(this), reward);
        rewardToken.approve(address(eToken), reward);
        eToken.depositRewards(reward);

        vm.prank(lender);
        eToken.transfer(otherHolder, amount / 2);

        // Half went to another pass-through holder; the redirect rule does NOT
        // fire (to is a holder), so lender's bucket is unchanged.
        assertEq(eToken.claimableRewards(lender), reward);
        assertEq(eToken.claimableRewards(otherHolder), 0);
    }

    /// @dev Non-holder → holder transfer also does not trigger redirect; the
    ///      sender simply settles via the normal path.
    function test_passThrough_nonHolderToHolder_noRedirect() public {
        (address lender,, uint256 amount) = _setupPassThroughCase();

        // Reward arrives BEFORE transfer; MINTER1 holds 100e18.
        rewardToken.mint(address(this), 100e6);
        rewardToken.approve(address(eToken), 100e6);
        eToken.depositRewards(100e6);

        // Now MINTER1 transfers half to lender. Settlement credits MINTER1 with
        // the full reward (they held all the supply at deposit time). No redirect.
        vm.prank(Actors.MINTER1);
        eToken.transfer(lender, amount / 2);

        assertApproxEqAbs(eToken.claimableRewards(Actors.MINTER1), 100e6, 1);
        assertEq(eToken.claimableRewards(lender), 0);
    }

    /// @dev Burning eTokens held by a pass-through custodian (e.g. on
    ///      liquidation dust burn) leaves the rewards in the custodian bucket
    ///      — `to == address(0)` so the redirect doesn't fire.
    function test_passThrough_burnFromHolder_keepsRewards() public {
        (address lender, uint256 reward, uint256 amount) = _setupPassThroughCase();

        vm.prank(Actors.MINTER1);
        eToken.transfer(lender, amount);

        rewardToken.mint(address(this), reward);
        rewardToken.approve(address(eToken), reward);
        eToken.depositRewards(reward);

        // The order system (this test contract, mocked as MARKET) burns from lender.
        eToken.burn(lender, amount / 2);

        // Lender retains the full settled reward bucket (no redirect on burn).
        assertEq(eToken.claimableRewards(lender), reward);
    }
}
