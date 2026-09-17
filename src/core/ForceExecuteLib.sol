// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IEToken} from "../interfaces/IEToken.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IOwnMarket} from "../interfaces/IOwnMarket.sol";
import {IOwnVault} from "../interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {Order, OrderStatus, OrderType, PRECISION} from "../interfaces/types/Types.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ForceExecuteLib — Force-execution leg of OwnMarket
/// @notice The user's last-resort redeem exit, extracted verbatim from OwnMarket as an external
///         (linked, DELEGATECALLed) library to keep the market under the EIP-170 size limit.
///         Delegatecall preserves the market's context — address(this), msg.sender and storage —
///         so every authority boundary holds unchanged: releaseCollateral / EToken.burn /
///         closeExposure all still see the market as caller, and the order mutations write the
///         market's own storage. The library is a known immutable implementation linked at deploy
///         (per the protocol's delegatecall policy); a market implementation upgrade re-links it.
/// @dev Registry-derived contracts (AssetRegistry, VaultManager) are re-resolved per helper
///      rather than threaded as parameters — stack relief on a rare path, per house convention.
library ForceExecuteLib {
    /// @notice Validate, price and settle a force execution. Mirrors the pre-extraction body of
    ///         OwnMarket.forceExecuteOrder exactly; the market wrapper keeps the order load, the
    ///         event emission and the ETH refund.
    /// @param order               The open redeem order (storage reference into the market).
    /// @param orderId             Order id (for error context).
    /// @param registry            ProtocolRegistry for contract lookups.
    /// @param vault               Collateral-source vault chosen by the redeemer.
    /// @param assetPriceData      Signed price proof for the order's asset.
    /// @param collateralPriceData Signed price proof for the vault's collateral asset.
    /// @return remaining       eToken amount force-executed (the order's unfilled remainder).
    /// @return grossCollateral Collateral units released to the order owner.
    function forceExecute(
        Order storage order,
        uint256 orderId,
        IProtocolRegistry registry,
        address vault,
        bytes calldata assetPriceData,
        bytes calldata collateralPriceData
    ) external returns (uint256 remaining, uint256 grossCollateral) {
        _validateForce(order, orderId, registry, vault);

        remaining = order.amount - order.filledAmount;

        // Fresh price required: the current oracle price must still satisfy the order's limit, so a
        // stale favorable print can't be exercised after the market has moved. Payout settles at the
        // limit (bare oracle price, no maker spread).
        _checkAssetPrice(registry, order, assetPriceData);
        grossCollateral = _convertToCollateral(
            registry, vault, Math.mulDiv(remaining, order.limitPrice, PRECISION), collateralPriceData
        );

        // Effects.
        order.filledAmount = order.amount;
        order.status = OrderStatus.ForceExecuted;

        // Interactions: release collateral, burn escrowed eTokens, shrink global exposure.
        IOwnVault(vault).releaseCollateral(order.user, grossCollateral);
        IEToken(IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset)).burn(address(this), remaining);
        IVaultManager(registry.vaultManager()).closeExposure(order.asset, remaining);
    }

    /// @dev Owner / order-shape / vault-eligibility / pause / window gates, verbatim from the
    ///      pre-extraction body (own frame — stack relief).
    function _validateForce(
        Order storage order,
        uint256 orderId,
        IProtocolRegistry registry,
        address vault
    ) private view {
        if (order.user != msg.sender) revert IOwnMarket.OnlyOrderOwner(orderId);
        if (order.orderType != OrderType.Redeem) revert IOwnMarket.ForceMintNotAllowed(orderId);
        // An expired order is not a standing force-execution right (same rule as both fill paths).
        if (block.timestamp > order.expiry) revert IOwnMarket.OrderExpiredError(orderId);

        IAssetRegistry ar = IAssetRegistry(registry.assetRegistry());
        // A redeem order escrowed in a now-legacy token cannot be force-executed; cancel to recover.
        if (order.escrowToken != ar.getActiveToken(order.asset)) revert IOwnMarket.OrderTokenMigrated(orderId);

        // Collateral source: the redeemer picks any vault in the registry's admin-approved pool —
        // force-execution is the user's last-resort exit, so source flexibility is deliberate.
        // An empty pool (the default) disables force-execution for the asset (fail-safe).
        if (!ar.isForceExecuteVaultAllowed(order.asset, vault)) {
            revert IOwnMarket.ForceExecuteVaultNotAllowed(order.asset, vault);
        }

        IVaultManager vmgr = IVaultManager(registry.vaultManager());
        if (!vmgr.isRegisteredVault(vault)) revert IOwnMarket.VaultNotRegistered(vault);
        if (vmgr.isVaultExcluded(vault)) revert IOwnMarket.VaultExcludedFromPool(vault);
        // Pool entries can go stale (deregister → re-register as RWA); reserves never source
        // force-execution — releaseCollateral there is market-gated, which this call would pass.
        if (vmgr.vaultBackedAsset(vault) != bytes32(0)) revert IOwnMarket.RwaVaultNotEligible(vault);
        // Pause and halt both disable the force path.
        if (vmgr.isTradingPaused(order.asset)) revert IOwnMarket.AssetPaused(order.asset);
        if (vmgr.isAssetHalted(order.asset)) revert IOwnMarket.ForceDisabledDuringHalt(order.asset);
        // A zero claim threshold (pre-deploy default) disables force-execution entirely.
        uint256 threshold = vmgr.claimThreshold();
        if (threshold == 0) revert IOwnMarket.ForceNotEnabled();
        if (block.timestamp < order.createdAt + threshold) {
            revert IOwnMarket.ForceWindowNotElapsed(orderId);
        }
    }

    /// @dev Verify the asset leg: fresh proof, and the current price must still satisfy the
    ///      order's limit (own frame — stack relief).
    function _checkAssetPrice(IProtocolRegistry registry, Order storage order, bytes calldata assetPriceData) private {
        (uint256 currentPrice, uint256 assetTs) = _verifyAssetPrice(registry, order.asset, assetPriceData);
        if (_isStale(assetTs, registry.priceMaxAge())) revert IOwnMarket.StaleAssetPrice();
        if (currentPrice < order.limitPrice) revert IOwnMarket.PriceBelowMinimum();
    }

    /// @dev Verify a fresh signed price proof for an asset, forwarding the oracle's ETH fee.
    function _verifyAssetPrice(
        IProtocolRegistry registry,
        bytes32 asset,
        bytes calldata priceData
    ) private returns (uint256 price, uint256 timestamp) {
        address oracleAddr = _getOracleForAsset(registry, asset);
        if (oracleAddr == address(0)) revert IOwnMarket.AssetOracleNotSet(asset);
        return _verifyPaidPrice(oracleAddr, asset, priceData);
    }

    /// @dev Verify a signed price proof against `oracleAddr`, forwarding the oracle's ETH fee.
    ///      Runs under delegatecall, so the fee is paid from the market's balance (the caller's
    ///      attached ETH), exactly as before the extraction.
    function _verifyPaidPrice(
        address oracleAddr,
        bytes32 asset,
        bytes calldata priceData
    ) private returns (uint256 price, uint256 timestamp) {
        IOracleVerifier oracle = IOracleVerifier(oracleAddr);
        uint256 fee = oracle.verifyFee(priceData);
        (price, timestamp) = oracle.verifyPrice{value: fee}(asset, priceData);
    }

    /// @dev Convert a USD value (18 decimals) to collateral units using the vault's collateral oracle.
    function _convertToCollateral(
        IProtocolRegistry registry,
        address vault,
        uint256 usdValue,
        bytes calldata collateralPriceData
    ) private returns (uint256) {
        bytes32 collatAsset = IVaultManager(registry.vaultManager()).vaultCollateralAsset(vault);
        address oracleAddr = _getOracleForAsset(registry, collatAsset);
        if (oracleAddr == address(0)) revert IOwnMarket.CollateralOracleNotSet();
        (uint256 price, uint256 timestamp) = _verifyPaidPrice(oracleAddr, collatAsset, collateralPriceData);

        // Collateral is released now, so its price must be current.
        if (_isStale(timestamp, registry.priceMaxAge())) revert IOwnMarket.StaleCollateralPrice();

        // usdValue and price are 18-decimal, so this yields an 18-decimal collateral amount.
        // Scale down to the collateral token's decimals (floor — protocol-favorable).
        return Math.mulDiv(usdValue, PRECISION, price) / _tokenScale(IOwnVault(vault).asset());
    }

    /// @dev Resolve the oracle address for an asset via ProtocolRegistry.
    function _getOracleForAsset(IProtocolRegistry registry, bytes32 asset) private view returns (address) {
        uint8 oracleType = IAssetRegistry(registry.assetRegistry()).getOracleType(asset);
        if (oracleType == 0) return registry.pythOracle();
        return registry.inhouseOracle();
    }

    /// @dev 10^(18 − token decimals); all supported tokens have <= 18 decimals.
    function _tokenScale(
        address token
    ) private view returns (uint256) {
        return 10 ** (18 - IERC20Metadata(token).decimals());
    }

    /// @dev True if `ts` is in the future or older than `maxAge`.
    function _isStale(uint256 ts, uint256 maxAge) private view returns (bool) {
        return ts > block.timestamp || block.timestamp - ts > maxAge;
    }
}
