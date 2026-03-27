// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IFeeCalculator} from "../interfaces/IFeeCalculator.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title FeeCalculator — Fixed per-volatility-level fee lookup
/// @notice Stores admin-set mint and redeem fee rates per volatility tier.
///         Looks up an asset's volatility level from AssetRegistry to return
///         the applicable fee. Swappable via ProtocolRegistry for dynamic
///         fee implementations.
contract FeeCalculator is IFeeCalculator, Ownable {
    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    /// @dev Maximum fee: 5% (500 BPS). Protects against admin misconfiguration.
    uint256 public constant MAX_FEE_BPS = 500;

    /// @dev Valid volatility levels: 1 (low), 2 (medium), 3 (high).
    uint8 public constant MIN_VOLATILITY_LEVEL = 1;
    uint8 public constant MAX_VOLATILITY_LEVEL = 3;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    /// @notice Protocol registry for resolving AssetRegistry address.
    IProtocolRegistry public immutable registry;

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @dev Volatility level → mint fee in BPS.
    mapping(uint8 => uint256) private _mintFees;

    /// @dev Volatility level → redeem fee in BPS.
    mapping(uint8 => uint256) private _redeemFees;

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param _registry Protocol registry address.
    /// @param admin     Initial owner / admin address.
    constructor(address _registry, address admin) Ownable(admin) {
        registry = IProtocolRegistry(_registry);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFeeCalculator
    function setMintFee(uint8 volatilityLevel, uint256 feeBps) external onlyOwner {
        _validateVolatilityLevel(volatilityLevel);
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps, MAX_FEE_BPS);

        _mintFees[volatilityLevel] = feeBps;

        emit MintFeeUpdated(volatilityLevel, feeBps);
    }

    /// @inheritdoc IFeeCalculator
    function setRedeemFee(uint8 volatilityLevel, uint256 feeBps) external onlyOwner {
        _validateVolatilityLevel(volatilityLevel);
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps, MAX_FEE_BPS);

        _redeemFees[volatilityLevel] = feeBps;

        emit RedeemFeeUpdated(volatilityLevel, feeBps);
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFeeCalculator
    function getMintFee(bytes32 asset, uint256 /* amount */ ) external view returns (uint256 feeBps) {
        uint8 level = _getVolatilityLevel(asset);
        return _mintFees[level];
    }

    /// @inheritdoc IFeeCalculator
    function getRedeemFee(bytes32 asset, uint256 /* amount */ ) external view returns (uint256 feeBps) {
        uint8 level = _getVolatilityLevel(asset);
        return _redeemFees[level];
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Look up the asset's volatility level from AssetRegistry.
    function _getVolatilityLevel(
        bytes32 asset
    ) private view returns (uint8) {
        IAssetRegistry assetRegistry = IAssetRegistry(registry.assetRegistry());
        return assetRegistry.getAssetConfig(asset).volatilityLevel;
    }

    /// @dev Revert if volatility level is outside the valid range [1, 3].
    function _validateVolatilityLevel(
        uint8 level
    ) private pure {
        if (level < MIN_VOLATILITY_LEVEL || level > MAX_VOLATILITY_LEVEL) {
            revert InvalidVolatilityLevel(level);
        }
    }
}
