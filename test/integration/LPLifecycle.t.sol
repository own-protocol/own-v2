// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, VaultStatus, WithdrawalRequest, WithdrawalStatus} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {PaymentTokenRegistry} from "../../src/core/PaymentTokenRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LPLifecycle Integration Test
/// @notice Tests LP deposits → delegation → yield → async withdrawal queue → fulfillment.
contract LPLifecycleTest is BaseTest {
    AssetRegistry public assetRegistry;
    PaymentTokenRegistry public paymentRegistry;
    VaultManager public vaultMgr;
    OwnMarket public market;
    OwnVault public usdcVault;
    EToken public eTSLA;

    uint256 constant LP_DEPOSIT = 100_000e6; // 100k USDC

    function setUp() public override {
        super.setUp();
        _deployProtocol();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);
        paymentRegistry = new PaymentTokenRegistry(Actors.ADMIN);

        // Register infrastructure in registry
        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.PAYMENT_TOKEN_REGISTRY(), address(paymentRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);

        // Deploy contracts with registry
        market = new OwnMarket(address(protocolRegistry));
        vaultMgr = new VaultManager(Actors.ADMIN, address(protocolRegistry), 30);

        // Register market and vault manager
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), address(vaultMgr));

        usdcVault = new OwnVault(
            address(usdc),
            "Own USDC Vault",
            "oUSDC",
            address(protocolRegistry),
            8000,
            0, // no AUM fee for cleaner math
            1000
        );

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            minCollateralRatio: 11_000,
            liquidationThreshold: 10_500,
            liquidationReward: 500,
            active: true
        });
        assetRegistry.addAsset(TSLA, address(eTSLA), config);
        paymentRegistry.addPaymentToken(address(usdc));

        vm.stopPrank();

        // Register VM1
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setSpread(50);
        vaultMgr.setExposureCaps(10_000_000e18, 5_000_000e18);
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: LP deposits and receives shares
    // ══════════════════════════════════════════════════════════

    function test_lpDeposit_receivesShares() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 shares = usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        assertGt(shares, 0, "LP received shares");
        assertEq(usdcVault.balanceOf(Actors.LP1), shares);
        assertEq(usdcVault.totalAssets(), LP_DEPOSIT);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Multiple LPs get proportional shares
    // ══════════════════════════════════════════════════════════

    function test_multipleLPs_proportionalShares() public {
        // LP1 deposits 100k
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 shares1 = usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        // LP2 deposits 200k
        _fundUSDC(Actors.LP2, LP_DEPOSIT * 2);
        vm.startPrank(Actors.LP2);
        usdc.approve(address(usdcVault), LP_DEPOSIT * 2);
        uint256 shares2 = usdcVault.deposit(LP_DEPOSIT * 2, Actors.LP2);
        vm.stopPrank();

        // LP2 deposited 2x, should have ~2x shares
        assertApproxEqAbs(shares2, shares1 * 2, 1, "LP2 has 2x shares");
        assertEq(usdcVault.totalAssets(), LP_DEPOSIT * 3);
        assertEq(usdcVault.totalSupply(), shares1 + shares2);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: LP delegates to VM
    // ══════════════════════════════════════════════════════════

    function test_lpDelegation_flow() public {
        // LP1 proposes delegation to VM1
        vm.prank(Actors.LP1);
        vaultMgr.proposeDelegation(Actors.VM1);

        // VM1 accepts
        vm.prank(Actors.VM1);
        vaultMgr.acceptDelegation(Actors.LP1);

        // Verify delegation
        assertEq(vaultMgr.getDelegatedVM(Actors.LP1), Actors.VM1);

        address[] memory lps = vaultMgr.getDelegatedLPs(Actors.VM1);
        assertEq(lps.length, 1);
        assertEq(lps[0], Actors.LP1);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: LP removes delegation
    // ══════════════════════════════════════════════════════════

    function test_lpRemovesDelegation() public {
        // Setup delegation
        vm.prank(Actors.LP1);
        vaultMgr.proposeDelegation(Actors.VM1);
        vm.prank(Actors.VM1);
        vaultMgr.acceptDelegation(Actors.LP1);

        // LP removes
        vm.prank(Actors.LP1);
        vaultMgr.removeDelegation();

        assertEq(vaultMgr.getDelegatedVM(Actors.LP1), address(0));
        assertEq(vaultMgr.getDelegatedLPs(Actors.VM1).length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Share price appreciates with donated yield
    // ══════════════════════════════════════════════════════════

    function test_sharePriceAppreciates() public {
        // LP1 deposits
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 shares = usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        uint256 sharePriceBefore = usdcVault.convertToAssets(1e6); // using 1 share unit

        // Simulate yield: donate USDC directly to vault (e.g., aUSDC interest or spread revenue)
        uint256 yieldAmount = 10_000e6; // $10k yield
        _fundUSDC(address(usdcVault), yieldAmount);

        uint256 sharePriceAfter = usdcVault.convertToAssets(1e6);
        assertGt(sharePriceAfter, sharePriceBefore, "share price increased");

        // LP1 can withdraw more than deposited (1 wei rounding from ERC-4626)
        uint256 maxWithdraw = usdcVault.maxWithdraw(Actors.LP1);
        assertApproxEqAbs(maxWithdraw, LP_DEPOSIT + yieldAmount, 1, "LP can withdraw deposit + yield");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Async withdrawal request
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_request() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 shares = usdcVault.deposit(LP_DEPOSIT, Actors.LP1);

        // Request withdrawal of half shares
        uint256 halfShares = shares / 2;
        uint256 requestId = usdcVault.requestWithdrawal(halfShares);
        vm.stopPrank();

        // Shares escrowed in vault
        assertEq(usdcVault.balanceOf(Actors.LP1), shares - halfShares, "shares escrowed");
        assertEq(usdcVault.balanceOf(address(usdcVault)), halfShares, "vault holds escrowed shares");

        // Check request
        WithdrawalRequest memory req = usdcVault.getWithdrawalRequest(requestId);
        assertEq(req.owner, Actors.LP1);
        assertEq(req.shares, halfShares);
        assertEq(uint8(req.status), uint8(WithdrawalStatus.Pending));

        // Pending withdrawals list
        uint256[] memory pending = usdcVault.getPendingWithdrawals();
        assertEq(pending.length, 1);
        assertEq(pending[0], requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Fulfill withdrawal
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_fulfill() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 shares = usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(shares);
        vm.stopPrank();

        uint256 usdcBefore = usdc.balanceOf(Actors.LP1);

        // Anyone can fulfill
        uint256 assets = usdcVault.fulfillWithdrawal(requestId);

        assertGt(assets, 0, "received assets");
        assertEq(usdc.balanceOf(Actors.LP1), usdcBefore + assets, "LP got USDC");
        assertEq(usdcVault.balanceOf(address(usdcVault)), 0, "escrowed shares burned");

        // Request fulfilled
        WithdrawalRequest memory req = usdcVault.getWithdrawalRequest(requestId);
        assertEq(uint8(req.status), uint8(WithdrawalStatus.Fulfilled));

        // Pending list empty
        assertEq(usdcVault.getPendingWithdrawals().length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cancel withdrawal — shares returned
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_cancel() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 shares = usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(shares);

        assertEq(usdcVault.balanceOf(Actors.LP1), 0, "all shares escrowed");

        usdcVault.cancelWithdrawal(requestId);
        vm.stopPrank();

        assertEq(usdcVault.balanceOf(Actors.LP1), shares, "shares returned");

        WithdrawalRequest memory req = usdcVault.getWithdrawalRequest(requestId);
        assertEq(uint8(req.status), uint8(WithdrawalStatus.Cancelled));
        assertEq(usdcVault.getPendingWithdrawals().length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Only request owner can cancel
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_cancelOnlyOwner() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        uint256 lp1Shares = usdcVault.balanceOf(Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(lp1Shares);
        vm.stopPrank();

        vm.prank(Actors.LP2);
        vm.expectRevert(abi.encodeWithSignature("NotRequestOwner(uint256,address)", requestId, Actors.LP2));
        usdcVault.cancelWithdrawal(requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: FIFO queue — multiple requests fulfilled in order
    // ══════════════════════════════════════════════════════════

    function test_asyncWithdrawal_FIFOQueue() public {
        // LP1 and LP2 deposit
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        _fundUSDC(Actors.LP2, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        vm.startPrank(Actors.LP2);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP2);
        vm.stopPrank();

        // Both request withdrawals
        uint256 lp1Shares = usdcVault.balanceOf(Actors.LP1);
        vm.prank(Actors.LP1);
        uint256 reqId1 = usdcVault.requestWithdrawal(lp1Shares);

        uint256 lp2Shares = usdcVault.balanceOf(Actors.LP2);
        vm.prank(Actors.LP2);
        uint256 reqId2 = usdcVault.requestWithdrawal(lp2Shares);

        // Both in pending
        uint256[] memory pending = usdcVault.getPendingWithdrawals();
        assertEq(pending.length, 2);

        // Fulfill first request
        usdcVault.fulfillWithdrawal(reqId1);
        assertGt(usdc.balanceOf(Actors.LP1), 0);

        pending = usdcVault.getPendingWithdrawals();
        assertEq(pending.length, 1);

        // Fulfill second request
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
    //  Test: Full lifecycle — deposit, delegate, earn, withdraw
    // ══════════════════════════════════════════════════════════

    function test_fullLPLifecycle() public {
        // 1. LP deposits
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 shares = usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
        assertGt(shares, 0);

        // 2. LP delegates to VM
        vm.prank(Actors.LP1);
        vaultMgr.proposeDelegation(Actors.VM1);
        vm.prank(Actors.VM1);
        vaultMgr.acceptDelegation(Actors.LP1);
        assertEq(vaultMgr.getDelegatedVM(Actors.LP1), Actors.VM1);

        // 3. Simulate yield (donate USDC to vault)
        uint256 yield_ = 5000e6;
        _fundUSDC(address(usdcVault), yield_);
        assertEq(usdcVault.totalAssets(), LP_DEPOSIT + yield_);

        // 4. LP requests withdrawal of all shares
        vm.prank(Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(shares);

        // 5. Withdrawal fulfilled — LP gets deposit + yield (1 wei ERC-4626 rounding)
        uint256 assets = usdcVault.fulfillWithdrawal(requestId);
        assertApproxEqAbs(assets, LP_DEPOSIT + yield_, 1, "LP received deposit + yield");
        assertApproxEqAbs(usdc.balanceOf(Actors.LP1), LP_DEPOSIT + yield_, 1);

        // 6. LP removes delegation
        vm.prank(Actors.LP1);
        vaultMgr.removeDelegation();
        assertEq(vaultMgr.getDelegatedVM(Actors.LP1), address(0));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: ERC-4626 standard withdraw (non-async)
    // ══════════════════════════════════════════════════════════

    function test_erc4626_standardWithdraw() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);

        // Standard ERC-4626 withdraw
        uint256 usdcBefore = usdc.balanceOf(Actors.LP1);
        uint256 shares = usdcVault.withdraw(LP_DEPOSIT, Actors.LP1, Actors.LP1);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(usdc.balanceOf(Actors.LP1), usdcBefore + LP_DEPOSIT);
        assertEq(usdcVault.balanceOf(Actors.LP1), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: ERC-4626 standard redeem
    // ══════════════════════════════════════════════════════════

    function test_erc4626_standardRedeem() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 shares = usdcVault.deposit(LP_DEPOSIT, Actors.LP1);

        uint256 usdcBefore = usdc.balanceOf(Actors.LP1);
        uint256 assets = usdcVault.redeem(shares, Actors.LP1, Actors.LP1);
        vm.stopPrank();

        assertEq(assets, LP_DEPOSIT);
        assertEq(usdc.balanceOf(Actors.LP1), usdcBefore + LP_DEPOSIT);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Vault view functions
    // ══════════════════════════════════════════════════════════

    function test_vaultViewFunctions() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        assertEq(usdcVault.asset(), address(usdc));
        assertEq(usdcVault.totalAssets(), LP_DEPOSIT);
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Active));
        assertEq(usdcVault.maxUtilization(), 8000);
        assertEq(usdcVault.totalExposure(), 0);
        // With 0 exposure, health factor is max
        assertEq(usdcVault.healthFactor(), type(uint256).max);
        assertEq(usdcVault.utilization(), 0);
    }
}
