// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, VaultStatus, WithdrawalRequest, WithdrawalStatus} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LPLifecycle Integration Test
/// @notice Tests LP deposits -> yield -> async withdrawal queue -> fulfillment.
contract LPLifecycleTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public usdcVault;
    EToken public eTSLA;

    uint256 constant LP_DEPOSIT = 100_000e6;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);

        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(0);

        VaultFactory factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        usdcVault = OwnVault(factory.createVault(address(usdc), Actors.VM1, "Own USDC Vault", "oUSDC", 8000, 2000, 900));

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

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _lpDeposit(address lp, uint256 amount) internal returns (uint256 shares) {
        _fundUSDC(Actors.VM1, amount);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), amount);
        shares = usdcVault.deposit(amount, lp);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: LP deposits and receives shares
    // ══════════════════════════════════════════════════════════

    function test_lpDeposit_receivesShares() public {
        uint256 shares = _lpDeposit(Actors.LP1, LP_DEPOSIT);

        assertGt(shares, 0, "LP received shares");
        assertEq(usdcVault.balanceOf(Actors.LP1), shares);
        assertEq(usdcVault.totalAssets(), LP_DEPOSIT);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Multiple LPs get proportional shares
    // ══════════════════════════════════════════════════════════

    function test_multipleLPs_proportionalShares() public {
        uint256 shares1 = _lpDeposit(Actors.LP1, LP_DEPOSIT);
        uint256 shares2 = _lpDeposit(Actors.LP2, LP_DEPOSIT * 2);

        assertApproxEqAbs(shares2, shares1 * 2, 1, "LP2 has 2x shares");
        assertEq(usdcVault.totalAssets(), LP_DEPOSIT * 3);
        assertEq(usdcVault.totalSupply(), shares1 + shares2);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Share price appreciates with donated yield
    // ══════════════════════════════════════════════════════════

    function test_sharePriceAppreciates() public {
        _lpDeposit(Actors.LP1, LP_DEPOSIT);

        uint256 sharePriceBefore = usdcVault.convertToAssets(1e6);

        uint256 yieldAmount = 10_000e6;
        _fundUSDC(address(usdcVault), yieldAmount);

        uint256 sharePriceAfter = usdcVault.convertToAssets(1e6);
        assertGt(sharePriceAfter, sharePriceBefore, "share price increased");

        uint256 maxWithdraw = usdcVault.maxWithdraw(Actors.LP1);
        assertApproxEqAbs(maxWithdraw, LP_DEPOSIT + yieldAmount, 1, "LP can withdraw deposit + yield");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Async withdrawal request
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_request() public {
        uint256 shares = _lpDeposit(Actors.LP1, LP_DEPOSIT);

        uint256 halfShares = shares / 2;
        vm.prank(Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(halfShares);

        assertEq(usdcVault.balanceOf(Actors.LP1), shares - halfShares, "shares escrowed");
        assertEq(usdcVault.balanceOf(address(usdcVault)), halfShares, "vault holds escrowed shares");

        WithdrawalRequest memory req = usdcVault.getWithdrawalRequest(requestId);
        assertEq(req.owner, Actors.LP1);
        assertEq(req.shares, halfShares);
        assertEq(uint8(req.status), uint8(WithdrawalStatus.Pending));

        uint256[] memory pending = usdcVault.getPendingWithdrawals();
        assertEq(pending.length, 1);
        assertEq(pending[0], requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Fulfill withdrawal
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_fulfill() public {
        uint256 shares = _lpDeposit(Actors.LP1, LP_DEPOSIT);

        vm.prank(Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(shares);

        uint256 usdcBefore = usdc.balanceOf(Actors.LP1);

        uint256 assets = usdcVault.fulfillWithdrawal(requestId);

        assertGt(assets, 0, "received assets");
        assertEq(usdc.balanceOf(Actors.LP1), usdcBefore + assets, "LP got USDC");
        assertEq(usdcVault.balanceOf(address(usdcVault)), 0, "escrowed shares burned");

        WithdrawalRequest memory req = usdcVault.getWithdrawalRequest(requestId);
        assertEq(uint8(req.status), uint8(WithdrawalStatus.Fulfilled));

        assertEq(usdcVault.getPendingWithdrawals().length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cancel withdrawal — shares returned
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_cancel() public {
        uint256 shares = _lpDeposit(Actors.LP1, LP_DEPOSIT);

        vm.prank(Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(shares);

        assertEq(usdcVault.balanceOf(Actors.LP1), 0, "all shares escrowed");

        vm.prank(Actors.LP1);
        usdcVault.cancelWithdrawal(requestId);

        assertEq(usdcVault.balanceOf(Actors.LP1), shares, "shares returned");

        WithdrawalRequest memory req = usdcVault.getWithdrawalRequest(requestId);
        assertEq(uint8(req.status), uint8(WithdrawalStatus.Cancelled));
        assertEq(usdcVault.getPendingWithdrawals().length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Only request owner can cancel
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_cancelOnlyOwner() public {
        _lpDeposit(Actors.LP1, LP_DEPOSIT);
        uint256 lp1Shares = usdcVault.balanceOf(Actors.LP1);

        vm.prank(Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(lp1Shares);

        vm.prank(Actors.LP2);
        vm.expectRevert(abi.encodeWithSignature("NotRequestOwner(uint256,address)", requestId, Actors.LP2));
        usdcVault.cancelWithdrawal(requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: FIFO queue
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_FIFOQueue() public {
        _lpDeposit(Actors.LP1, LP_DEPOSIT);
        _lpDeposit(Actors.LP2, LP_DEPOSIT);

        uint256 lp1Shares = usdcVault.balanceOf(Actors.LP1);
        vm.prank(Actors.LP1);
        uint256 reqId1 = usdcVault.requestWithdrawal(lp1Shares);

        uint256 lp2Shares = usdcVault.balanceOf(Actors.LP2);
        vm.prank(Actors.LP2);
        uint256 reqId2 = usdcVault.requestWithdrawal(lp2Shares);

        uint256[] memory pending = usdcVault.getPendingWithdrawals();
        assertEq(pending.length, 2);

        usdcVault.fulfillWithdrawal(reqId1);
        assertGt(usdc.balanceOf(Actors.LP1), 0);

        pending = usdcVault.getPendingWithdrawals();
        assertEq(pending.length, 1);

        usdcVault.fulfillWithdrawal(reqId2);
        assertGt(usdc.balanceOf(Actors.LP2), 0);

        assertEq(usdcVault.getPendingWithdrawals().length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cannot request withdrawal with zero shares
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_zeroShares_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        usdcVault.requestWithdrawal(0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Full lifecycle — deposit, earn, withdraw
    // ══════════════════════════════════════════════════════════

    function test_fullLPLifecycle() public {
        uint256 shares = _lpDeposit(Actors.LP1, LP_DEPOSIT);
        assertGt(shares, 0);

        uint256 yield_ = 5000e6;
        _fundUSDC(address(usdcVault), yield_);
        assertEq(usdcVault.totalAssets(), LP_DEPOSIT + yield_);

        vm.prank(Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(shares);

        uint256 assets = usdcVault.fulfillWithdrawal(requestId);
        assertApproxEqAbs(assets, LP_DEPOSIT + yield_, 1, "LP received deposit + yield");
        assertApproxEqAbs(usdc.balanceOf(Actors.LP1), LP_DEPOSIT + yield_, 1);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: ERC-4626 standard withdraw
    // ══════════════════════════════════════════════════════════

    function test_erc4626_standardWithdraw() public {
        _lpDeposit(Actors.LP1, LP_DEPOSIT);

        uint256 usdcBefore = usdc.balanceOf(Actors.LP1);
        vm.prank(Actors.LP1);
        uint256 shares = usdcVault.withdraw(LP_DEPOSIT, Actors.LP1, Actors.LP1);

        assertGt(shares, 0);
        assertEq(usdc.balanceOf(Actors.LP1), usdcBefore + LP_DEPOSIT);
        assertEq(usdcVault.balanceOf(Actors.LP1), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: ERC-4626 standard redeem
    // ══════════════════════════════════════════════════════════

    function test_erc4626_standardRedeem() public {
        uint256 shares = _lpDeposit(Actors.LP1, LP_DEPOSIT);

        uint256 usdcBefore = usdc.balanceOf(Actors.LP1);
        vm.prank(Actors.LP1);
        uint256 assets = usdcVault.redeem(shares, Actors.LP1, Actors.LP1);

        assertEq(assets, LP_DEPOSIT);
        assertEq(usdc.balanceOf(Actors.LP1), usdcBefore + LP_DEPOSIT);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Vault view functions
    // ══════════════════════════════════════════════════════════

    function test_vaultViewFunctions() public {
        _lpDeposit(Actors.LP1, LP_DEPOSIT);

        assertEq(usdcVault.asset(), address(usdc));
        assertEq(usdcVault.totalAssets(), LP_DEPOSIT);
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Active));
        assertEq(usdcVault.maxUtilization(), 8000);
        assertEq(usdcVault.totalExposureUSD(), 0);
        assertEq(usdcVault.healthFactor(), type(uint256).max);
        assertEq(usdcVault.utilization(), 0);
    }
}
