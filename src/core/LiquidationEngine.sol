// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ILiquidationEngine} from "../interfaces/ILiquidationEngine.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {PRECISION} from "../interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LiquidationEngine — Three-tier liquidation for collateral vaults
/// @notice Monitors vault health and executes liquidations to restore collateral
///         ratios. Supports Tier 1 (eToken-based), Tier 2 (organic LP deposits),
///         and Tier 3 (DEX fallback + expired redemption).
contract LiquidationEngine is ILiquidationEngine, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    address public immutable admin;
    IOracleVerifier public immutable oracle;
    address public immutable assetRegistry;
    address public immutable dex;

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    constructor(address admin_, address oracle_, address assetRegistry_, address dex_) {
        admin = admin_;
        oracle = IOracleVerifier(oracle_);
        assetRegistry = assetRegistry_;
        dex = dex_;
    }

    // ──────────────────────────────────────────────────────────
    //  Tier 1 — Liquidator provides eTokens
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc ILiquidationEngine
    function liquidate(
        address vault,
        bytes32 asset,
        uint256 eTokenAmount,
        bytes calldata priceData
    ) external nonReentrant returns (uint256 collateralReceived) {
        if (eTokenAmount == 0) revert ZeroAmount();
        if (!_isLiquidatable(vault)) revert VaultHealthy(vault, _getHealthFactor(vault));

        uint256 maxLiq = _getMaxLiquidatable(vault, asset);
        if (eTokenAmount > maxLiq) revert ExcessiveLiquidation(eTokenAmount, maxLiq);

        // Verify price
        (uint256 price,,) = oracle.verifyPrice(asset, priceData);

        // Calculate collateral to transfer (eTokens * price + reward)
        // Simplified: will be refined when vault integration is complete
        collateralReceived = (eTokenAmount * price) / PRECISION;

        emit LiquidationExecuted(vault, asset, msg.sender, eTokenAmount, collateralReceived, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Tier 3 — DEX fallback
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc ILiquidationEngine
    function dexLiquidate(
        address vault,
        bytes32 asset,
        uint256 collateralAmount,
        bytes calldata priceData,
        bytes calldata /* swapData */
    ) external nonReentrant returns (uint256 stablecoinReceived) {
        if (collateralAmount == 0) revert ZeroAmount();
        if (!_isLiquidatable(vault)) revert VaultHealthy(vault, _getHealthFactor(vault));

        // Verify price
        oracle.verifyPrice(asset, priceData);

        // DEX swap would happen here
        stablecoinReceived = 0;

        emit DEXLiquidationExecuted(vault, asset, collateralAmount, stablecoinReceived);
    }

    /// @inheritdoc ILiquidationEngine
    function liquidateExpiredRedemption(
        uint256 orderId,
        bytes calldata, /* priceData */
        bytes calldata /* swapData */
    ) external nonReentrant returns (uint256 userPayout) {
        // Will integrate with OwnMarket for expired redemption orders
        userPayout = 0;
        emit RedemptionDeadlineLiquidation(orderId, address(0), 0, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc ILiquidationEngine
    function getHealthFactor(
        address vault
    ) external view returns (uint256) {
        return _getHealthFactor(vault);
    }

    /// @inheritdoc ILiquidationEngine
    function getMaxLiquidatable(address vault, bytes32 asset) external view returns (uint256) {
        return _getMaxLiquidatable(vault, asset);
    }

    /// @inheritdoc ILiquidationEngine
    function isLiquidatable(
        address vault
    ) external view returns (bool) {
        return _isLiquidatable(vault);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    function _getHealthFactor(
        address /* vault */
    ) private pure returns (uint256) {
        // Stub: will query vault.healthFactor() when integration is complete
        return type(uint256).max;
    }

    function _getMaxLiquidatable(address, /* vault */ bytes32 /* asset */ ) private pure returns (uint256) {
        // Stub: will compute based on vault health and asset config
        return 0;
    }

    function _isLiquidatable(
        address /* vault */
    ) private pure returns (bool) {
        // Stub: will check vault health < liquidation threshold
        return false;
    }
}
