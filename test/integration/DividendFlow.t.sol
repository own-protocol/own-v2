// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, PRECISION} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title DividendFlow Integration Test
/// @notice Tests the rewards-per-share dividend system:
///         VM deposits dividend -> holders claim -> transfer settlement -> new holder claims.
contract DividendFlowTest is BaseTest {
    using Math for uint256;

    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public usdcVault;
    EToken public eTSLA;

    uint256 constant HOLDER1_AMOUNT = 100e18;
    uint256 constant HOLDER2_AMOUNT = 50e18;
    uint256 constant REWARD_AMOUNT = 1500e6;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
        _mintETokens();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);

        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(2000);

        VaultFactory factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        usdcVault = OwnVault(factory.createVault(address(usdc), Actors.VM1, "Own USDC Vault", "oUSDC", 8000, 2000));

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        usdcVault.setGracePeriod(1 days);
        usdcVault.setClaimThreshold(6 hours);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        vm.stopPrank();

        // Set payment token and enable asset
        vm.startPrank(Actors.VM1);
        usdcVault.setPaymentToken(address(usdc));
        usdcVault.enableAsset(TSLA);
        vm.stopPrank();
    }

    function _mintETokens() private {
        vm.startPrank(address(market));
        eTSLA.mint(Actors.MINTER1, HOLDER1_AMOUNT);
        eTSLA.mint(Actors.MINTER2, HOLDER2_AMOUNT);
        vm.stopPrank();
    }

    function test_dividendFlow_depositAndClaim() public {
        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        uint256 totalSupply = eTSLA.totalSupply();
        assertEq(totalSupply, HOLDER1_AMOUNT + HOLDER2_AMOUNT);

        uint256 claimable1 = eTSLA.claimableRewards(Actors.MINTER1);
        uint256 claimable2 = eTSLA.claimableRewards(Actors.MINTER2);

        uint256 expected1 = REWARD_AMOUNT * HOLDER1_AMOUNT / totalSupply;
        uint256 expected2 = REWARD_AMOUNT * HOLDER2_AMOUNT / totalSupply;

        assertEq(claimable1, expected1, "holder1 claimable");
        assertEq(claimable2, expected2, "holder2 claimable");

        uint256 balBefore = usdc.balanceOf(Actors.MINTER1);
        vm.prank(Actors.MINTER1);
        eTSLA.claimRewards();
        uint256 balAfter = usdc.balanceOf(Actors.MINTER1);

        assertEq(balAfter - balBefore, expected1, "holder1 received rewards");
        assertEq(eTSLA.claimableRewards(Actors.MINTER1), 0);

        balBefore = usdc.balanceOf(Actors.MINTER2);
        vm.prank(Actors.MINTER2);
        eTSLA.claimRewards();
        balAfter = usdc.balanceOf(Actors.MINTER2);

        assertEq(balAfter - balBefore, expected2, "holder2 received rewards");
    }

    function test_dividendFlow_transferSettlement() public {
        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        vm.prank(Actors.MINTER1);
        eTSLA.transfer(Actors.MINTER2, HOLDER1_AMOUNT);

        uint256 totalSupply = HOLDER1_AMOUNT + HOLDER2_AMOUNT;
        uint256 expected1 = REWARD_AMOUNT * HOLDER1_AMOUNT / totalSupply;

        uint256 claimable1 = eTSLA.claimableRewards(Actors.MINTER1);
        assertEq(claimable1, expected1, "holder1 rewards preserved after transfer");

        vm.prank(Actors.MINTER1);
        eTSLA.claimRewards();
        assertEq(usdc.balanceOf(Actors.MINTER1), expected1);
    }

    function test_dividendFlow_newHolderClaimsSubsequentRewards() public {
        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        vm.prank(Actors.MINTER1);
        eTSLA.transfer(Actors.LP1, HOLDER1_AMOUNT);

        uint256 lp1Claimable = eTSLA.claimableRewards(Actors.LP1);
        assertEq(lp1Claimable, 0, "new holder has no rewards from before transfer");

        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        uint256 totalSupply = HOLDER1_AMOUNT + HOLDER2_AMOUNT;
        uint256 expectedLP1 = REWARD_AMOUNT * HOLDER1_AMOUNT / totalSupply;
        uint256 expectedMinter2 = REWARD_AMOUNT * HOLDER2_AMOUNT / totalSupply;

        lp1Claimable = eTSLA.claimableRewards(Actors.LP1);
        assertEq(lp1Claimable, expectedLP1, "new holder gets rewards from second deposit");

        uint256 minter2Claimable = eTSLA.claimableRewards(Actors.MINTER2);
        uint256 minter2FromFirst = REWARD_AMOUNT * HOLDER2_AMOUNT / totalSupply;
        assertEq(minter2Claimable, minter2FromFirst + expectedMinter2, "existing holder accumulates");
    }

    function test_dividendFlow_noDoubleClaim() public {
        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        vm.prank(Actors.MINTER1);
        eTSLA.claimRewards();

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSignature("NoRewardsToClaim()"));
        eTSLA.claimRewards();
    }

    function test_dividendFlow_rewardsPerShareAccumulates() public {
        uint256 totalSupply = eTSLA.totalSupply();
        assertEq(eTSLA.rewardsPerShare(), 0);

        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        uint256 expectedRPS = REWARD_AMOUNT * PRECISION / totalSupply;
        assertEq(eTSLA.rewardsPerShare(), expectedRPS, "RPS after first deposit");

        _fundUSDC(Actors.VM1, REWARD_AMOUNT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(eTSLA), REWARD_AMOUNT);
        eTSLA.depositRewards(REWARD_AMOUNT);
        vm.stopPrank();

        assertEq(eTSLA.rewardsPerShare(), expectedRPS * 2, "RPS accumulates");
    }

    function test_dividendFlow_depositWithZeroSupply_reverts() public {
        vm.prank(Actors.ADMIN);
        EToken freshToken = new EToken("Fresh", "eFRESH", bytes32("FRESH"), address(protocolRegistry), address(usdc));

        _fundUSDC(Actors.VM1, 100e6);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(freshToken), 100e6);
        vm.expectRevert("EToken: no supply");
        freshToken.depositRewards(100e6);
        vm.stopPrank();
    }

    function test_dividendFlow_depositZeroRewards_reverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        eTSLA.depositRewards(0);
    }

    function test_dividendFlow_multipleDeposits_singleClaim() public {
        uint256 totalSupply = eTSLA.totalSupply();

        for (uint256 i; i < 3; i++) {
            _fundUSDC(Actors.VM1, 500e6);
            vm.startPrank(Actors.VM1);
            usdc.approve(address(eTSLA), 500e6);
            eTSLA.depositRewards(500e6);
            vm.stopPrank();
        }

        uint256 claimable = eTSLA.claimableRewards(Actors.MINTER1);
        uint256 idealExpected = 1500e6 * HOLDER1_AMOUNT / totalSupply;
        assertApproxEqAbs(claimable, idealExpected, 1000, "accumulated rewards from multiple deposits");

        vm.prank(Actors.MINTER1);
        eTSLA.claimRewards();
        assertApproxEqAbs(usdc.balanceOf(Actors.MINTER1), idealExpected, 1000);
    }
}
