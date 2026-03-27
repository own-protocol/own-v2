// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetConfig} from "./types/Types.sol";

/// @title IAssetRegistry — Asset whitelisting and token tracking
/// @notice Manages the set of tradeable assets, their active eToken addresses,
///         legacy tokens (post-split), collateral parameters, and oracle
///         configuration. Only the protocol admin can mutate state.
interface IAssetRegistry {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a new asset is registered.
    /// @param ticker  Asset ticker (e.g. bytes32("TSLA")).
    /// @param eToken  Address of the active eToken contract.
    event AssetAdded(bytes32 indexed ticker, address indexed eToken);

    /// @notice Emitted when an asset's configuration is updated.
    /// @param ticker Asset ticker.
    /// @param config The new configuration.
    event AssetUpdated(bytes32 indexed ticker, AssetConfig config);

    /// @notice Emitted when an asset is deactivated (no new orders allowed).
    /// @param ticker Asset ticker.
    event AssetDeactivated(bytes32 indexed ticker);

    /// @notice Emitted on a stock-split token migration.
    /// @param ticker   Asset ticker.
    /// @param oldToken Previous active eToken (now legacy).
    /// @param newToken New active eToken.
    event TokenMigrated(bytes32 indexed ticker, address indexed oldToken, address indexed newToken);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The asset ticker is already registered.
    error AssetAlreadyExists(bytes32 ticker);

    /// @notice The asset ticker is not registered.
    error AssetNotFound(bytes32 ticker);

    /// @notice The asset is not active for new orders.
    error AssetNotActive(bytes32 ticker);

    /// @notice A zero address was provided.
    error ZeroAddress();

    // ──────────────────────────────────────────────────────────
    //  Admin functions
    // ──────────────────────────────────────────────────────────

    /// @notice Register a new tradeable asset.
    /// @param ticker Asset ticker (e.g. bytes32("TSLA")).
    /// @param eToken Address of the deployed eToken contract.
    /// @param config Initial asset configuration.
    function addAsset(bytes32 ticker, address eToken, AssetConfig calldata config) external;

    /// @notice Update an existing asset's configuration.
    /// @param ticker Asset ticker.
    /// @param config New configuration values.
    function updateAssetConfig(bytes32 ticker, AssetConfig calldata config) external;

    /// @notice Deactivate an asset so no new orders can be placed.
    /// @param ticker Asset ticker.
    function deactivateAsset(
        bytes32 ticker
    ) external;

    /// @notice Migrate to a new eToken after a stock split.
    /// @dev The current active token becomes a legacy token; the new token
    ///      becomes active. Legacy tokens remain valid and redeemable.
    /// @param ticker   Asset ticker.
    /// @param newToken Address of the new active eToken contract.
    function migrateToken(bytes32 ticker, address newToken) external;

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @notice Return the full configuration for an asset.
    /// @param ticker Asset ticker.
    /// @return config The asset configuration.
    function getAssetConfig(
        bytes32 ticker
    ) external view returns (AssetConfig memory config);

    /// @notice Return the current active eToken address for an asset.
    /// @param ticker Asset ticker.
    /// @return token The active eToken address.
    function getActiveToken(
        bytes32 ticker
    ) external view returns (address token);

    /// @notice Return all legacy eToken addresses for an asset.
    /// @param ticker Asset ticker.
    /// @return tokens Array of legacy eToken addresses.
    function getLegacyTokens(
        bytes32 ticker
    ) external view returns (address[] memory tokens);

    /// @notice Check whether an asset is active for new orders.
    /// @param ticker Asset ticker.
    /// @return True if the asset is active.
    function isActiveAsset(
        bytes32 ticker
    ) external view returns (bool);

    /// @notice Check whether a token address is either the active or a legacy token for a ticker.
    /// @param ticker Asset ticker.
    /// @param token  Token address to check.
    /// @return True if the token is valid (active or legacy) for the ticker.
    function isValidToken(bytes32 ticker, address token) external view returns (bool);
}
