// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, PRECISION} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title DividendFlow Integration Test
/// @notice Tests the rewards-per-share dividend system:
///         VM deposits dividend → holders claim → transfer settlement → new holder claims.
contract DividendFlowTest is BaseTest {
    using Math for uint256;

    AssetRegistry public assetRegistry;
    OwnMarket public market;
    VaultManager public vaultMgr;
    OwnVault public usdcVault;
    EToken public eTSLA;

    uint256 constant HOLDER1_AMOUNT = 100e18; // 100 eTSLA
    uint256 constant HOLDER2_AMOUNT = 50e18; // 50 eTSLA
    uint256 constant REWARD_AMOUNT = 1500e6; // $1,500 USDC reward

    function setUp() public override {
        super.setUp();
        _deployProtocol();
        _mintETokens();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);

        // Register infrastructure in registry
        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);

        // Deploy contracts with registry
        market = new OwnMarket(address(protocolRegistry));
        vaultMgr = new VaultManager(Actors.ADMIN, address(protocolRegistry));

        // Register market and vault manager
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), address(vaultMgr));

        usdcVault = new OwnVault(
            address(usdc), "Own USDC Vault", "oUSDC", address(protocolRegistry), Actors.VM1, 8000, 50, 2000, 2000
        );

        // eTSLA with USDC as reward token (for dividends)
        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        vm.stopPrank();

        // Add payment token at vault level (VM1 is the bound VM)
        vm.startPrank(Actors.VM1);
        usdcVault.addPaymentToken(address(usdc));
        vm.stopPrank();
    }

    /// @dev Mint eTokens directly to holders for testing dividends.
    function _mintETokens() private {
        vm.startPrank(address(market));
        eTSLA.mint(Actors.MINTER1, HOLDER1_AMOUNT); // 100 eTSLA
        eTSLA.mint(Actors.MINTER2, HOLDER2_AMOUNT); // 50 eTSLA
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Deposit rewards and claim proportionally
    // ══════════════════════════════════════════════════════════

    function test_dividendFlow_depositAndClaim() public {
        // Deposit rewards (anyone can deposit)
        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        // Total supply: 150 eTSLA. Holder1 has 100 (2/3), Holder2 has 50 (1/3)
        uint256 totalSupply = eTSLA.totalSupply();
        assertEq(totalSupply, HOLDER1_AMOUNT + HOLDER2_AMOUNT);

        // Check claimable rewards
        uint256 claimable1 = eTSLA.claimableRewards(Actors.MINTER1);
        uint256 claimable2 = eTSLA.claimableRewards(Actors.MINTER2);

        // Holder1 should get ~1000 USDC (100/150 * 1500)
        // Holder2 should get ~500 USDC (50/150 * 1500)
        uint256 expected1 = REWARD_AMOUNT * HOLDER1_AMOUNT / totalSupply;
        uint256 expected2 = REWARD_AMOUNT * HOLDER2_AMOUNT / totalSupply;

        assertEq(claimable1, expected1, "holder1 claimable");
        assertEq(claimable2, expected2, "holder2 claimable");

        // Holder1 claims
        uint256 balBefore = usdc.balanceOf(Actors.MINTER1);
        vm.prank(Actors.MINTER1);
        eTSLA.claimRewards();
        uint256 balAfter = usdc.balanceOf(Actors.MINTER1);

        assertEq(balAfter - balBefore, expected1, "holder1 received rewards");

        // After claiming, claimable should be 0
        assertEq(eTSLA.claimableRewards(Actors.MINTER1), 0);

        // Holder2 claims
        balBefore = usdc.balanceOf(Actors.MINTER2);
        vm.prank(Actors.MINTER2);
        eTSLA.claimRewards();
        balAfter = usdc.balanceOf(Actors.MINTER2);

        assertEq(balAfter - balBefore, expected2, "holder2 received rewards");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Transfer settles rewards before transfer
    // ══════════════════════════════════════════════════════════

    function test_dividendFlow_transferSettlement() public {
        // Deposit rewards
        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        // Holder1 transfers all tokens to Holder2 BEFORE claiming
        vm.prank(Actors.MINTER1);
        eTSLA.transfer(Actors.MINTER2, HOLDER1_AMOUNT);

        // Holder1's rewards should still be claimable (settled before transfer)
        uint256 totalSupply = HOLDER1_AMOUNT + HOLDER2_AMOUNT;
        uint256 expected1 = REWARD_AMOUNT * HOLDER1_AMOUNT / totalSupply;

        uint256 claimable1 = eTSLA.claimableRewards(Actors.MINTER1);
        assertEq(claimable1, expected1, "holder1 rewards preserved after transfer");

        // Holder1 claims
        vm.prank(Actors.MINTER1);
        eTSLA.claimRewards();
        assertEq(usdc.balanceOf(Actors.MINTER1), expected1);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: New holder gets rewards from subsequent deposits
    // ══════════════════════════════════════════════════════════

    function test_dividendFlow_newHolderClaimsSubsequentRewards() public {
        // Deposit first round of rewards
        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        // Holder1 transfers all tokens to LP1 (who had 0 eTokens)
        vm.prank(Actors.MINTER1);
        eTSLA.transfer(Actors.LP1, HOLDER1_AMOUNT);

        // LP1 should NOT have rewards from the first deposit (wasn't a holder then)
        // But Holder1's rewards were settled on transfer
        uint256 lp1Claimable = eTSLA.claimableRewards(Actors.LP1);
        assertEq(lp1Claimable, 0, "new holder has no rewards from before transfer");

        // Deposit second round of rewards
        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        // Now LP1 (100 eTSLA) and MINTER2 (50 eTSLA) share the second reward
        uint256 totalSupply = HOLDER1_AMOUNT + HOLDER2_AMOUNT; // still 150
        uint256 expectedLP1 = REWARD_AMOUNT * HOLDER1_AMOUNT / totalSupply;
        uint256 expectedMinter2 = REWARD_AMOUNT * HOLDER2_AMOUNT / totalSupply;

        lp1Claimable = eTSLA.claimableRewards(Actors.LP1);
        assertEq(lp1Claimable, expectedLP1, "new holder gets rewards from second deposit");

        // MINTER2 should have rewards from both deposits
        uint256 minter2Claimable = eTSLA.claimableRewards(Actors.MINTER2);
        uint256 minter2FromFirst = REWARD_AMOUNT * HOLDER2_AMOUNT / totalSupply;
        assertEq(minter2Claimable, minter2FromFirst + expectedMinter2, "existing holder accumulates");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: No double-claim
    // ══════════════════════════════════════════════════════════

    function test_dividendFlow_noDoubleClaim() public {
        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        // Claim once
        vm.prank(Actors.MINTER1);
        eTSLA.claimRewards();

        // Second claim should revert
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSignature("NoRewardsToClaim()"));
        eTSLA.claimRewards();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Rewards per share tracked correctly
    // ══════════════════════════════════════════════════════════

    function test_dividendFlow_rewardsPerShareAccumulates() public {
        uint256 totalSupply = eTSLA.totalSupply();
        assertEq(eTSLA.rewardsPerShare(), 0);

        // First deposit
        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        uint256 expectedRPS = REWARD_AMOUNT * PRECISION / totalSupply;
        assertEq(eTSLA.rewardsPerShare(), expectedRPS, "RPS after first deposit");

        // Second deposit
        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        assertEq(eTSLA.rewardsPerShare(), expectedRPS * 2, "RPS accumulates");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cannot deposit rewards with zero supply
    // ══════════════════════════════════════════════════════════

    function test_dividendFlow_depositWithZeroSupply_reverts() public {
        // Deploy a fresh eToken with no supply
        vm.prank(Actors.ADMIN);
        EToken freshToken = new EToken("Fresh", "eFRESH", bytes32("FRESH"), address(protocolRegistry), address(usdc));

        _fundUSDC(Actors.VM1, 100e6);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(freshToken), 100e6);
        vm.expectRevert("EToken: no supply");
        freshToken.depositRewards(100e6);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Deposit zero rewards reverts
    // ══════════════════════════════════════════════════════════

    function test_dividendFlow_depositZeroRewards_reverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        eTSLA.depositRewards(0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Multiple reward deposits, claim once gets all
    // ══════════════════════════════════════════════════════════

    function test_dividendFlow_multipleDeposits_singleClaim() public {
        uint256 totalSupply = eTSLA.totalSupply();

        // Three deposits of 500 USDC each
        for (uint256 i; i < 3; i++) {
            _fundUSDC(Actors.VM1, 500e6);
            vm.startPrank(Actors.VM1);
            usdc.approve(address(eTSLA), 500e6);
            eTSLA.depositRewards(500e6);
            vm.stopPrank();
        }

        // Holder1 claims all at once.
        // Each 500e6 deposit computes rewardsPerShare with floor division,
        // so 3 deposits accumulate slightly less than 1500e6 * share / total.
        uint256 claimable = eTSLA.claimableRewards(Actors.MINTER1);

        // Holder1 owns 100/150 = 2/3 of supply → expect ~1000 USDC
        // Allow up to 1000 wei of rounding dust across the 3 deposits
        uint256 idealExpected = 1500e6 * HOLDER1_AMOUNT / totalSupply;
        assertApproxEqAbs(claimable, idealExpected, 1000, "accumulated rewards from multiple deposits");

        vm.prank(Actors.MINTER1);
        eTSLA.claimRewards();
        assertApproxEqAbs(usdc.balanceOf(Actors.MINTER1), idealExpected, 1000);
    }
}
