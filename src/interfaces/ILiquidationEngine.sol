// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ILiquidationEngine — Three-tier liquidation for collateral vaults
/// @notice Monitors vault health and executes liquidations to restore collateral
///         ratios above their minimums.
///
///         - **Tier 1**: Liquidator provides eTokens → receives discounted LP collateral.
///         - **Tier 2**: Organic new LP deposits (no interface needed).
///         - **Tier 3**: Vault sells collateral on a DEX (fallback) or pays the
///           minter on redeem deadline expiry.
///
/// @dev Liquidations are always partial — only enough to restore the vault's
///      health factor above the minimum threshold.
interface ILiquidationEngine {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted after a Tier 1 liquidation (liquidator provides eTokens).
    /// @param vault              Liquidated vault.
    /// @param asset              Asset whose eTokens were provided.
    /// @param liquidator         Address that triggered the liquidation.
    /// @param eTokenAmount       eTokens burned.
    /// @param collateralReceived LP collateral sent to the liquidator.
    /// @param reward             Liquidation reward (included in collateralReceived).
    event LiquidationExecuted(
        address indexed vault,
        bytes32 indexed asset,
        address indexed liquidator,
        uint256 eTokenAmount,
        uint256 collateralReceived,
        uint256 reward
    );

    /// @notice Emitted after a Tier 3 DEX liquidation (vault sells collateral).
    /// @param vault             Vault whose collateral was sold.
    /// @param asset             Asset whose exposure was reduced.
    /// @param collateralSold    Amount of LP collateral sold.
    /// @param stablecoinReceived Stablecoin proceeds from the DEX sale.
    event DEXLiquidationExecuted(
        address indexed vault, bytes32 indexed asset, uint256 collateralSold, uint256 stablecoinReceived
    );

    /// @notice Emitted when LP collateral is sold to pay a minter on redeem deadline expiry.
    /// @param orderId        Expired redeem order.
    /// @param vault          Vault whose collateral was sold.
    /// @param collateralSold Amount of LP collateral sold.
    /// @param userPayout     Stablecoin amount paid to the minter.
    event RedemptionDeadlineLiquidation(
        uint256 indexed orderId, address indexed vault, uint256 collateralSold, uint256 userPayout
    );

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The vault is healthy; no liquidation is needed.
    error VaultHealthy(address vault, uint256 healthFactor);

    /// @notice The requested liquidation exceeds the maximum allowed.
    error ExcessiveLiquidation(uint256 requestedAmount, uint256 maxLiquidatable);

    /// @notice The liquidator does not hold enough eTokens.
    error InsufficientETokens(address liquidator, uint256 required, uint256 available);

    /// @notice The asset is not registered.
    error AssetNotFound(bytes32 asset);

    /// @notice A zero amount was provided.
    error ZeroAmount();

    /// @notice The DEX swap failed.
    error DEXLiquidationFailed();

    /// @notice No viable DEX route exists for the swap.
    error NoSlippageRoute();

    // ──────────────────────────────────────────────────────────
    //  Tier 1 — Liquidator provides eTokens
    // ──────────────────────────────────────────────────────────

    /// @notice Execute a Tier 1 liquidation: provide eTokens and receive
    ///         discounted LP collateral from the vault.
    /// @param vault        Vault to liquidate.
    /// @param asset        Asset ticker whose eTokens to provide.
    /// @param eTokenAmount Amount of eTokens to burn.
    /// @param priceData    Signed oracle price data for valuation.
    /// @return collateralReceived Amount of LP collateral received (including reward).
    function liquidate(
        address vault,
        bytes32 asset,
        uint256 eTokenAmount,
        bytes calldata priceData
    ) external returns (uint256 collateralReceived);

    // ──────────────────────────────────────────────────────────
    //  Tier 3 — DEX fallback
    // ──────────────────────────────────────────────────────────

    /// @notice Execute a Tier 3 liquidation: sell vault collateral on a DEX
    ///         to restore health.
    /// @param vault            Vault to liquidate.
    /// @param asset            Asset ticker whose exposure to reduce.
    /// @param collateralAmount Amount of LP collateral to sell.
    /// @param priceData        Signed oracle price data for valuation.
    /// @param swapData         DEX-specific encoded swap calldata.
    /// @return stablecoinReceived Stablecoin proceeds from the sale.
    function dexLiquidate(
        address vault,
        bytes32 asset,
        uint256 collateralAmount,
        bytes calldata priceData,
        bytes calldata swapData
    ) external returns (uint256 stablecoinReceived);

    /// @notice Liquidate LP collateral to pay a minter whose redeem order
    ///         expired without VM confirmation.
    /// @param orderId  Expired redeem order identifier.
    /// @param priceData Signed oracle price data for valuation.
    /// @param swapData  DEX-specific encoded swap calldata.
    /// @return userPayout Stablecoin amount paid to the minter.
    function liquidateExpiredRedemption(
        uint256 orderId,
        bytes calldata priceData,
        bytes calldata swapData
    ) external returns (uint256 userPayout);

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @notice Return the current health factor for a vault.
    /// @dev 1e18 = 1.0 (exactly at minimum). < 1e18 means liquidatable.
    /// @param vault Vault address.
    /// @return The health factor (PRECISION-scaled).
    function getHealthFactor(
        address vault
    ) external view returns (uint256);

    /// @notice Return the maximum eToken amount that can be liquidated from a
    ///         vault for a given asset (partial only — enough to restore health).
    /// @param vault Vault address.
    /// @param asset Asset ticker.
    /// @return Maximum liquidatable eToken amount.
    function getMaxLiquidatable(address vault, bytes32 asset) external view returns (uint256);

    /// @notice Check whether a vault is below the liquidation threshold.
    /// @param vault Vault address.
    /// @return True if the vault can be liquidated.
    function isLiquidatable(
        address vault
    ) external view returns (bool);
}
