// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
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
    OwnVault public vault;
    EToken public eTSLA;

    uint256 constant LP_DEPOSIT = 50 ether;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);

        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(0);

        VaultFactory factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        vault = OwnVault(factory.createVault(address(weth), Actors.VM1, "Own WETH Vault", "oWETH", 8000, 2000));

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        vault.setGracePeriod(1 days);
        vault.setClaimThreshold(6 hours);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        vm.stopPrank();

        // Set payment token and enable asset
        vm.startPrank(Actors.VM1);
        vault.setPaymentToken(address(usdc));
        vault.enableAsset(TSLA);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _lpDeposit(address lp, uint256 amount) internal returns (uint256 shares) {
        _fundWETH(Actors.VM1, amount);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), amount);
        shares = vault.deposit(amount, lp);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: LP deposits and receives shares
    // ══════════════════════════════════════════════════════════

    function test_lpDeposit_receivesShares() public {
        uint256 shares = _lpDeposit(Actors.LP1, LP_DEPOSIT);

        assertGt(shares, 0, "LP received shares");
        assertEq(vault.balanceOf(Actors.LP1), shares);
        assertEq(vault.totalAssets(), LP_DEPOSIT);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Multiple LPs get proportional shares
    // ══════════════════════════════════════════════════════════

    function test_multipleLPs_proportionalShares() public {
        uint256 shares1 = _lpDeposit(Actors.LP1, LP_DEPOSIT);
        uint256 shares2 = _lpDeposit(Actors.LP2, LP_DEPOSIT * 2);

        assertApproxEqAbs(shares2, shares1 * 2, 1, "LP2 has 2x shares");
        assertEq(vault.totalAssets(), LP_DEPOSIT * 3);
        assertEq(vault.totalSupply(), shares1 + shares2);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Share price appreciates with donated yield
    // ══════════════════════════════════════════════════════════

    function test_sharePriceAppreciates() public {
        _lpDeposit(Actors.LP1, LP_DEPOSIT);

        uint256 sharePriceBefore = vault.convertToAssets(1 ether);

        uint256 yieldAmount = 5 ether;
        _fundWETH(address(vault), yieldAmount);

        uint256 sharePriceAfter = vault.convertToAssets(1 ether);
        assertGt(sharePriceAfter, sharePriceBefore, "share price increased");

        // maxWithdraw returns 0 (direct withdrawals disabled), but share price still reflects yield
        assertEq(vault.maxWithdraw(Actors.LP1), 0, "maxWithdraw is 0 (use async queue)");
        uint256 lpShares = vault.balanceOf(Actors.LP1);
        uint256 withdrawableViaQueue = vault.convertToAssets(lpShares);
        assertApproxEqAbs(withdrawableViaQueue, LP_DEPOSIT + yieldAmount, 1, "LP value includes deposit + yield");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Async withdrawal request
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_request() public {
        uint256 shares = _lpDeposit(Actors.LP1, LP_DEPOSIT);

        uint256 halfShares = shares / 2;
        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(halfShares);

        assertEq(vault.balanceOf(Actors.LP1), shares - halfShares, "shares escrowed");
        assertEq(vault.balanceOf(address(vault)), halfShares, "vault holds escrowed shares");

        WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertEq(req.owner, Actors.LP1);
        assertEq(req.shares, halfShares);
        assertEq(uint8(req.status), uint8(WithdrawalStatus.Pending));

        uint256[] memory pending = vault.getPendingWithdrawals();
        assertEq(pending.length, 1);
        assertEq(pending[0], requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Fulfill withdrawal
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_fulfill() public {
        uint256 shares = _lpDeposit(Actors.LP1, LP_DEPOSIT);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        uint256 usdcBefore = weth.balanceOf(Actors.LP1);

        uint256 assets = vault.fulfillWithdrawal(requestId);

        assertGt(assets, 0, "received assets");
        assertEq(weth.balanceOf(Actors.LP1), usdcBefore + assets, "LP got WETH");
        assertEq(vault.balanceOf(address(vault)), 0, "escrowed shares burned");

        WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertEq(uint8(req.status), uint8(WithdrawalStatus.Fulfilled));

        assertEq(vault.getPendingWithdrawals().length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cancel withdrawal — shares returned
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_cancel() public {
        uint256 shares = _lpDeposit(Actors.LP1, LP_DEPOSIT);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        assertEq(vault.balanceOf(Actors.LP1), 0, "all shares escrowed");

        vm.prank(Actors.LP1);
        vault.cancelWithdrawal(requestId);

        assertEq(vault.balanceOf(Actors.LP1), shares, "shares returned");

        WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertEq(uint8(req.status), uint8(WithdrawalStatus.Cancelled));
        assertEq(vault.getPendingWithdrawals().length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Only request owner can cancel
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_cancelOnlyOwner() public {
        _lpDeposit(Actors.LP1, LP_DEPOSIT);
        uint256 lp1Shares = vault.balanceOf(Actors.LP1);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(lp1Shares);

        vm.prank(Actors.LP2);
        vm.expectRevert(abi.encodeWithSignature("NotRequestOwner(uint256,address)", requestId, Actors.LP2));
        vault.cancelWithdrawal(requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: FIFO queue
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_FIFOQueue() public {
        _lpDeposit(Actors.LP1, LP_DEPOSIT);
        _lpDeposit(Actors.LP2, LP_DEPOSIT);

        uint256 lp1Shares = vault.balanceOf(Actors.LP1);
        vm.prank(Actors.LP1);
        uint256 reqId1 = vault.requestWithdrawal(lp1Shares);

        uint256 lp2Shares = vault.balanceOf(Actors.LP2);
        vm.prank(Actors.LP2);
        uint256 reqId2 = vault.requestWithdrawal(lp2Shares);

        uint256[] memory pending = vault.getPendingWithdrawals();
        assertEq(pending.length, 2);

        vault.fulfillWithdrawal(reqId1);
        assertGt(weth.balanceOf(Actors.LP1), 0);

        pending = vault.getPendingWithdrawals();
        assertEq(pending.length, 1);

        vault.fulfillWithdrawal(reqId2);
        assertGt(weth.balanceOf(Actors.LP2), 0);

        assertEq(vault.getPendingWithdrawals().length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cannot request withdrawal with zero shares
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_zeroShares_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        vault.requestWithdrawal(0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Full lifecycle — deposit, earn, withdraw
    // ══════════════════════════════════════════════════════════

    function test_fullLPLifecycle() public {
        uint256 shares = _lpDeposit(Actors.LP1, LP_DEPOSIT);
        assertGt(shares, 0);

        uint256 yield_ = 5 ether;
        _fundWETH(address(vault), yield_);
        assertEq(vault.totalAssets(), LP_DEPOSIT + yield_);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        uint256 assets = vault.fulfillWithdrawal(requestId);
        assertApproxEqAbs(assets, LP_DEPOSIT + yield_, 1, "LP received deposit + yield");
        assertApproxEqAbs(weth.balanceOf(Actors.LP1), LP_DEPOSIT + yield_, 1);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: ERC-4626 standard withdraw
    // ══════════════════════════════════════════════════════════

    function test_erc4626_standardWithdraw_reverts() public {
        _lpDeposit(Actors.LP1, LP_DEPOSIT);

        vm.prank(Actors.LP1);
        vm.expectRevert(IOwnVault.DirectWithdrawalDisabled.selector);
        vault.withdraw(LP_DEPOSIT, Actors.LP1, Actors.LP1);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: ERC-4626 standard redeem (disabled — use async queue)
    // ══════════════════════════════════════════════════════════

    function test_erc4626_standardRedeem_reverts() public {
        uint256 shares = _lpDeposit(Actors.LP1, LP_DEPOSIT);

        vm.prank(Actors.LP1);
        vm.expectRevert(IOwnVault.DirectWithdrawalDisabled.selector);
        vault.redeem(shares, Actors.LP1, Actors.LP1);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Vault view functions
    // ══════════════════════════════════════════════════════════

    function test_vaultViewFunctions() public {
        _lpDeposit(Actors.LP1, LP_DEPOSIT);

        assertEq(vault.asset(), address(weth));
        assertEq(vault.totalAssets(), LP_DEPOSIT);
        assertEq(uint8(vault.vaultStatus()), uint8(VaultStatus.Active));
        assertEq(vault.maxUtilization(), 8000);
        assertEq(vault.totalExposureUSD(), 0);
        assertEq(vault.healthFactor(), type(uint256).max);
        assertEq(vault.utilization(), 0);
    }
}
