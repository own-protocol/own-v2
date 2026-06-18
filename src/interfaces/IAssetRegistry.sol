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

    /// @notice Emitted when an asset's active flag is set.
    /// @param ticker Asset ticker.
    /// @param active New active flag (false = no new orders / borrows; existing positions wind down).
    event AssetActiveUpdated(bytes32 indexed ticker, bool active);

    /// @notice Emitted on a stock-split token migration.
    /// @param ticker   Asset ticker.
    /// @param oldToken Previous active eToken (now legacy).
    /// @param newToken New active eToken.
    event TokenMigrated(bytes32 indexed ticker, address indexed oldToken, address indexed newToken, uint256 ratio);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The asset ticker is already registered.
    error AssetAlreadyExists(bytes32 ticker);

    /// @notice The asset ticker is not registered.
    error AssetNotFound(bytes32 ticker);

    /// @notice A zero address was provided.
    error ZeroAddress();

    /// @notice A zero conversion ratio was provided.
    error InvalidRatio();

    /// @notice The migration target is the current active token or an existing legacy token.
    error InvalidNewToken(address token);

    /// @notice Caller does not hold the asset-registry admin role.
    error OnlyAdmin();

    /// @notice Caller does not hold the asset-registry operator role.
    error OnlyOperator();

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

    /// @notice Activate or deactivate an asset. When `active` is false, new orders (OwnMarket
    ///         execute/place) and new borrows are blocked; existing resting orders still wind down.
    ///         Orthogonal to VaultManager's permanent halt and `assetCapUSD` — resuming minting after
    ///         reactivation also requires a non-zero cap and a fresh mark. Admin-only.
    /// @param ticker Asset ticker.
    /// @param active New active flag.
    function setAssetActive(bytes32 ticker, bool active) external;

    /// @notice Migrate to a new eToken after a stock split.
    /// @dev The current active token becomes a legacy token; the new token becomes active. Legacy
    ///      tokens are not directly redeemable — they must be converted to the active token via
    ///      OwnMarket.convertLegacy at `ratio`. Existing legacy tokens' ratios are re-based so every
    ///      legacy token's stored ratio always converts directly to the current active token.
    /// @param ticker   Asset ticker.
    /// @param newToken Address of the new active eToken contract.
    /// @param ratio    New tokens per old token, 1e18-scaled (e.g. 3:1 split => 3e18).
    function migrateToken(bytes32 ticker, address newToken, uint256 ratio) external;

    /// @notice Conversion ratio (1e18-scaled) from a legacy token to the current active token.
    /// @param token Legacy token address.
    /// @return ratio New active tokens per legacy token (0 if not a legacy token).
    function legacyRatioToActive(
        address token
    ) external view returns (uint256 ratio);

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

    /// @notice Return the oracle type for an asset (0 = Pyth, 1 = in-house).
    function getOracleType(
        bytes32 ticker
    ) external view returns (uint8 oracleType);
}
