// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {AssetConfig} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title AssetRegistry — Asset whitelisting and token tracking
/// @notice Manages the set of tradeable assets, their active eToken addresses,
///         legacy tokens (post-split), and collateral parameters.
contract AssetRegistry is IAssetRegistry, Ownable {
    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @dev Ticker → asset configuration.
    mapping(bytes32 => AssetConfig) private _assets;

    /// @dev Ticker → whether it has been registered (to distinguish from default struct).
    mapping(bytes32 => bool) private _registered;

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param admin Initial owner / admin address.
    constructor(
        address admin
    ) Ownable(admin) {}

    // ──────────────────────────────────────────────────────────
    //  Admin functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAssetRegistry
    function addAsset(bytes32 ticker, address eToken, AssetConfig calldata config) external onlyOwner {
        if (_registered[ticker]) revert AssetAlreadyExists(ticker);
        if (eToken == address(0)) revert ZeroAddress();
        _validateConfig(config);

        _assets[ticker] = config;
        _assets[ticker].activeToken = eToken;
        _assets[ticker].active = true;
        // Clear legacy tokens (fresh start)
        delete _assets[ticker].legacyTokens;
        _registered[ticker] = true;

        emit AssetAdded(ticker, eToken);
    }

    /// @inheritdoc IAssetRegistry
    function updateAssetConfig(bytes32 ticker, AssetConfig calldata config) external onlyOwner {
        if (!_registered[ticker]) revert AssetNotFound(ticker);
        _validateConfig(config);

        // Preserve activeToken and legacyTokens — only update numeric params
        _assets[ticker].minCollateralRatio = config.minCollateralRatio;
        _assets[ticker].liquidationThreshold = config.liquidationThreshold;
        _assets[ticker].liquidationReward = config.liquidationReward;

        emit AssetUpdated(ticker, _assets[ticker]);
    }

    /// @inheritdoc IAssetRegistry
    function deactivateAsset(
        bytes32 ticker
    ) external onlyOwner {
        if (!_registered[ticker]) revert AssetNotFound(ticker);
        if (!_assets[ticker].active) revert AssetNotActive(ticker);

        _assets[ticker].active = false;

        emit AssetDeactivated(ticker);
    }

    /// @inheritdoc IAssetRegistry
    function migrateToken(bytes32 ticker, address newToken) external onlyOwner {
        if (!_registered[ticker]) revert AssetNotFound(ticker);
        if (newToken == address(0)) revert ZeroAddress();

        address oldToken = _assets[ticker].activeToken;
        _assets[ticker].legacyTokens.push(oldToken);
        _assets[ticker].activeToken = newToken;

        emit TokenMigrated(ticker, oldToken, newToken);
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAssetRegistry
    function getAssetConfig(
        bytes32 ticker
    ) external view returns (AssetConfig memory config) {
        if (!_registered[ticker]) revert AssetNotFound(ticker);
        return _assets[ticker];
    }

    /// @inheritdoc IAssetRegistry
    function getActiveToken(
        bytes32 ticker
    ) external view returns (address token) {
        if (!_registered[ticker]) revert AssetNotFound(ticker);
        return _assets[ticker].activeToken;
    }

    /// @inheritdoc IAssetRegistry
    function getLegacyTokens(
        bytes32 ticker
    ) external view returns (address[] memory tokens) {
        if (!_registered[ticker]) revert AssetNotFound(ticker);
        return _assets[ticker].legacyTokens;
    }

    /// @inheritdoc IAssetRegistry
    function isActiveAsset(
        bytes32 ticker
    ) external view returns (bool) {
        return _registered[ticker] && _assets[ticker].active;
    }

    /// @inheritdoc IAssetRegistry
    function isValidToken(bytes32 ticker, address token) external view returns (bool) {
        if (!_registered[ticker]) return false;

        if (_assets[ticker].activeToken == token) return true;

        address[] storage legacy = _assets[ticker].legacyTokens;
        for (uint256 i; i < legacy.length;) {
            if (legacy[i] == token) return true;
            unchecked {
                ++i;
            } // SAFETY: i < legacy.length, so i+1 won't overflow
        }

        return false;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Validate collateral parameters.
    function _validateConfig(
        AssetConfig calldata config
    ) private pure {
        if (config.minCollateralRatio == 0) revert InvalidCollateralParams();
        if (config.liquidationThreshold >= config.minCollateralRatio) revert InvalidThresholds();
    }
}
