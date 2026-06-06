// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IExposureManager — Central, pooled exposure / utilisation / collateral accounting
/// @notice Owns all global risk math for the protocol. Per-collateral vaults keep custody, LP
///         shares, yield, and lending; this manager pools the risk across every vault.
///
///         Two caps are enforced, both O(1):
///           1. Global utilisation — solvency: `globalExposureUSD / globalCollateralUSD <= maxBps`.
///           2. Per-asset USD ceiling — concentration: `globalAssetUnits[asset] * mark <= assetCapUSD`.
///              `assetCapUSD == 0` blocks minting that asset (safe default).
///
///         Exposure and collateral are valued exclusively at keeper-cached marks (Maker `spot`-style),
///         refreshed by permissionless price pulls. Staleness between pulls is absorbed by the
///         utilisation buffer. There is no `(vault, asset)` attribution — exposure is purely global
///         per asset.
interface IExposureManager {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a vault is registered by the factory.
    /// @param vault           The vault address.
    /// @param collateralAsset Oracle ticker used to price the vault's collateral.
    event VaultRegistered(address indexed vault, bytes32 indexed collateralAsset);

    /// @notice Emitted when a vault is deregistered by the factory.
    /// @param vault The vault address.
    event VaultDeregistered(address indexed vault);

    /// @notice Emitted when exposure is opened (eTokens minted) against an asset.
    /// @param vault   Vault whose VM filled the order.
    /// @param asset   Asset ticker.
    /// @param units   eToken units added to global exposure (18 decimals).
    /// @param markUSD Asset mark used to value the units (18 decimals).
    event ExposureOpened(address indexed vault, bytes32 indexed asset, uint256 units, uint256 markUSD);

    /// @notice Emitted when exposure is closed (eTokens redeemed) against an asset.
    /// @param vault   Vault whose VM filled the redeem.
    /// @param asset   Asset ticker.
    /// @param units   eToken units removed from global exposure (18 decimals).
    /// @param markUSD Asset mark used to value the units (18 decimals).
    event ExposureClosed(address indexed vault, bytes32 indexed asset, uint256 units, uint256 markUSD);

    /// @notice Emitted when an asset's price mark is pulled fresh from the oracle.
    /// @param asset   Asset ticker.
    /// @param oldMark Previous mark (18 decimals).
    /// @param newMark New mark (18 decimals).
    event AssetPricePulled(bytes32 indexed asset, uint256 oldMark, uint256 newMark);

    /// @notice Emitted when a vault's collateral mark is pulled fresh from the oracle.
    /// @param vault      The vault address.
    /// @param oldMarkUSD Previous collateral mark (18-decimal USD).
    /// @param newMarkUSD New collateral mark (18-decimal USD).
    event CollateralPricePulled(address indexed vault, uint256 oldMarkUSD, uint256 newMarkUSD);

    /// @notice Emitted when an asset's per-asset USD issuance ceiling is set.
    /// @param asset  Asset ticker.
    /// @param capUSD New ceiling (18-decimal USD). 0 blocks minting.
    event AssetCapUpdated(bytes32 indexed asset, uint256 capUSD);

    /// @notice Emitted when the global maximum utilisation is updated.
    /// @param oldBps Previous cap in basis points.
    /// @param newBps New cap in basis points.
    event GlobalMaxUtilizationUpdated(uint256 oldBps, uint256 newBps);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Caller is not the OwnMarket.
    error OnlyMarket();

    /// @notice Caller is not the VaultFactory.
    error OnlyFactory();

    /// @notice Caller is not the protocol admin (registry owner).
    error OnlyAdmin();

    /// @notice A zero address was provided.
    error ZeroAddress();

    /// @notice A zero amount was provided.
    error ZeroAmount();

    /// @notice The vault is not registered.
    error VaultNotRegistered(address vault);

    /// @notice The vault is already registered.
    error VaultAlreadyRegistered(address vault);

    /// @notice Opening this exposure would breach the per-asset USD ceiling.
    error AssetCapBreached(bytes32 asset, uint256 attemptedUSD, uint256 capUSD);

    /// @notice Opening this exposure would breach the global utilisation cap.
    error GlobalUtilizationBreached(uint256 projectedBps, uint256 maxBps);

    /// @notice Not enough outstanding exposure to close the requested units.
    error InsufficientExposure(bytes32 asset, uint256 have, uint256 want);

    /// @notice No collateral has been pulled yet (global collateral is zero).
    error CollateralNotInitialized();

    /// @notice No price mark is available for the asset (never pulled, or the pull returned zero).
    error PriceUnavailable(bytes32 asset);

    /// @notice Deregistering the vault would push global utilisation over the cap.
    error DeregisterWouldBreachUtilization();

    // ──────────────────────────────────────────────────────────
    //  Mutation — market only
    // ──────────────────────────────────────────────────────────

    /// @notice Atomically check and commit new exposure for a mint. Reverts on cap breach.
    /// @param vault The vault whose VM filled the order.
    /// @param asset Asset ticker.
    /// @param units eToken units minted (18 decimals).
    function openExposure(address vault, bytes32 asset, uint256 units) external;

    /// @notice Reduce global exposure for a redeem.
    /// @param vault The vault whose VM filled the redeem.
    /// @param asset Asset ticker.
    /// @param units eToken units redeemed (18 decimals).
    function closeExposure(address vault, bytes32 asset, uint256 units) external;

    // ──────────────────────────────────────────────────────────
    //  Keeper — permissionless
    // ──────────────────────────────────────────────────────────

    /// @notice Pull an asset's price fresh from its oracle and re-mark global exposure.
    /// @param asset Asset ticker.
    function pullAssetPrice(
        bytes32 asset
    ) external;

    /// @notice Pull a vault's collateral price fresh from the oracle and re-mark its collateral.
    /// @param vault The vault address.
    function pullCollateralPrice(
        address vault
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Registration — factory only
    // ──────────────────────────────────────────────────────────

    /// @notice Register a newly deployed vault and cache its collateral scaling.
    /// @param vault           The vault address.
    /// @param collateralAsset Oracle ticker used to price the vault's collateral.
    function registerVault(address vault, bytes32 collateralAsset) external;

    /// @notice Deregister a vault, removing its collateral from the global pool.
    /// @dev Reverts if removing the collateral would breach global utilisation.
    /// @param vault The vault address.
    function deregisterVault(
        address vault
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @notice Set the per-asset USD issuance ceiling. 0 blocks minting that asset.
    /// @param asset  Asset ticker.
    /// @param capUSD New ceiling (18-decimal USD).
    function setAssetCapUSD(bytes32 asset, uint256 capUSD) external;

    /// @notice Set the global maximum utilisation in basis points.
    /// @param bps New cap in basis points.
    function setGlobalMaxUtilizationBps(
        uint256 bps
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice Whether releasing `assets` of collateral from `vault` would breach global utilisation.
    /// @param vault  The vault address.
    /// @param assets Collateral amount (vault asset units) to be released.
    /// @return True if the withdrawal would push utilisation over the cap.
    function withdrawalBreachesUtil(address vault, uint256 assets) external view returns (bool);

    /// @notice Current global utilisation in basis points.
    function globalUtilizationBps() external view returns (uint256);

    /// @notice Running total of global exposure in 18-decimal USD.
    function globalExposureUSD() external view returns (uint256);

    /// @notice Running total of global collateral in 18-decimal USD.
    function globalCollateralUSD() external view returns (uint256);

    /// @notice Current price mark for an asset (18 decimals).
    function assetMark(
        bytes32 asset
    ) external view returns (uint256);

    /// @notice Current collateral mark for a vault (18-decimal USD).
    function collateralMark(
        address vault
    ) external view returns (uint256);

    /// @notice Oracle ticker used to price a registered vault's collateral.
    function vaultCollateralAsset(
        address vault
    ) external view returns (bytes32);

    /// @notice Total outstanding eToken units for an asset (18 decimals).
    function globalAssetUnits(
        bytes32 asset
    ) external view returns (uint256);

    /// @notice Per-asset USD issuance ceiling (18-decimal USD). 0 = minting blocked.
    function assetCapUSD(
        bytes32 asset
    ) external view returns (uint256);

    /// @notice Global maximum utilisation in basis points.
    function globalMaxUtilizationBps() external view returns (uint256);

    /// @notice Whether a vault is registered.
    function isRegisteredVault(
        address vault
    ) external view returns (bool);
}
