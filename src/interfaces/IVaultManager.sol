// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVaultManager — Central pooled risk accounting + global protocol controls
/// @notice Owns all global risk math and the protocol-wide control surface. Per-collateral
///         vaults keep custody, LP shares, yield, and lending; this manager pools the risk
///         across every vault and governs who can trade, what they pay with, and which assets
///         are paused or permanently halted.
///
///         Risk caps (both O(1)):
///           1. Global utilisation — solvency: `globalExposureUSD / globalCollateralUSD <= maxBps`.
///           2. Per-asset USD ceiling — concentration: `globalAssetUnits[asset] * mark <= assetCapUSD`.
///              `assetCapUSD == 0` blocks minting that asset (safe default).
///
///         Exposure/collateral are valued at keeper-cached marks refreshed by permissionless
///         price pulls. There is no `(vault, asset)` attribution — exposure is purely global
///         per asset. A halted vault's collateral is excluded from the global pool; a paused
///         vault's collateral still counts.
///
///         Control surface (all admin-set unless noted):
///           - Global signer registry: each authorised signer carries a linked settlement
///             address. Mint proceeds flow to that address; redeem payouts come from it.
///           - Global payment token: the single order-settlement currency for all vaults.
///           - Global + per-asset trading pause (temporary): blocks order execution and force-execute.
///           - Per-asset halt (permanent) at a fixed price + a halt redeem address holding stables.
///           - Global claim threshold: delay before a resting redeem order can be force-executed.
interface IVaultManager {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    event VaultRegistered(address indexed vault, bytes32 indexed collateralAsset);
    event VaultDeregistered(address indexed vault);

    /// @notice Emitted when exposure is opened (eTokens minted) against an asset.
    event ExposureOpened(bytes32 indexed asset, uint256 units, uint256 markUSD);

    /// @notice Emitted when exposure is closed (eTokens redeemed) against an asset.
    event ExposureClosed(bytes32 indexed asset, uint256 units, uint256 markUSD);

    event AssetPricePulled(bytes32 indexed asset, uint256 oldMark, uint256 newMark);
    event CollateralPricePulled(address indexed vault, uint256 oldMarkUSD, uint256 newMarkUSD);
    event AssetCapUpdated(bytes32 indexed asset, uint256 capUSD);
    event GlobalMaxUtilizationUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when a registered vault notifies its halt/unhalt transition.
    event VaultCollateralExcluded(address indexed vault, uint256 removedMarkUSD);
    event VaultCollateralReincluded(address indexed vault, uint256 addedMarkUSD);

    // ── Control surface ──────────────────────────────────────
    event SignerRegistered(address indexed signer, address indexed linkedAddress);
    event SignerLinkedAddressUpdated(address indexed signer, address indexed linkedAddress);
    event SignerRemoved(address indexed signer);
    event PaymentTokenUpdated(address indexed oldToken, address indexed newToken);
    event TradingPausedUpdated(bool paused);
    event AssetTradingPausedUpdated(bytes32 indexed asset, bool paused);
    event AssetHalted(bytes32 indexed asset, uint256 haltPrice);
    event HaltRedeemAddressUpdated(address indexed oldAddr, address indexed newAddr);
    event ClaimThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    error OnlyMarket();
    error OnlyFactory();
    error OnlyAdmin();
    error OnlyRegisteredVault();
    error ZeroAddress();
    error ZeroAmount();
    error VaultNotRegistered(address vault);
    error VaultAlreadyRegistered(address vault);
    error AssetCapBreached(bytes32 asset, uint256 attemptedUSD, uint256 capUSD);
    error GlobalUtilizationBreached(uint256 projectedBps, uint256 maxBps);
    error InsufficientExposure(bytes32 asset, uint256 have, uint256 want);
    error CollateralNotInitialized();
    error PriceUnavailable(bytes32 asset);
    error DeregisterWouldBreachUtilization();
    error NotSigner(address signer);
    error AlreadySigner(address signer);
    error AssetAlreadyHalted(bytes32 asset);
    error InvalidHaltPrice();
    error VaultAlreadyExcluded(address vault);

    // ──────────────────────────────────────────────────────────
    //  Mutation — market only
    // ──────────────────────────────────────────────────────────

    /// @notice Atomically check and commit new exposure for a mint. Reverts on cap breach.
    function openExposure(bytes32 asset, uint256 units) external;

    /// @notice Reduce global exposure for a redeem.
    function closeExposure(bytes32 asset, uint256 units) external;

    // ──────────────────────────────────────────────────────────
    //  Keeper — permissionless
    // ──────────────────────────────────────────────────────────

    function pullAssetPrice(
        bytes32 asset
    ) external;

    /// @notice Pull a vault's collateral price fresh and re-mark its collateral.
    /// @dev Reverts if the vault is currently excluded (halted).
    function pullCollateralPrice(
        address vault
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Registration — factory only
    // ──────────────────────────────────────────────────────────

    function registerVault(address vault, bytes32 collateralAsset) external;
    function deregisterVault(
        address vault
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Vault halt notifications — registered vault only
    // ──────────────────────────────────────────────────────────

    /// @notice Called by a vault entering Halted status: drop its collateral from the pool.
    function onVaultHalted() external;

    /// @notice Called by a vault leaving Halted status: re-pull its collateral mark.
    function onVaultUnhalted() external;

    /// @notice Whether a registered vault's collateral is currently excluded from the pool.
    function isVaultExcluded(
        address vault
    ) external view returns (bool);

    // ──────────────────────────────────────────────────────────
    //  Admin — risk parameters
    // ──────────────────────────────────────────────────────────

    function setAssetCapUSD(bytes32 asset, uint256 capUSD) external;
    function setGlobalMaxUtilizationBps(
        uint256 bps
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Admin — signer registry
    // ──────────────────────────────────────────────────────────

    /// @notice Authorise a signer with a linked settlement address (mint sink / redeem source).
    function registerSigner(address signer, address linkedAddress) external;

    /// @notice Update an existing signer's linked settlement address.
    function updateSignerLinkedAddress(address signer, address linkedAddress) external;

    /// @notice Revoke a signer.
    function removeSigner(
        address signer
    ) external;

    function isSigner(
        address account
    ) external view returns (bool);

    /// @notice Linked settlement address for a signer (zero if not a signer).
    function signerLinkedAddress(
        address signer
    ) external view returns (address);

    // ──────────────────────────────────────────────────────────
    //  Admin — payment token
    // ──────────────────────────────────────────────────────────

    function setPaymentToken(
        address token
    ) external;
    function paymentToken() external view returns (address);

    // ──────────────────────────────────────────────────────────
    //  Admin — trading pause (temporary)
    // ──────────────────────────────────────────────────────────

    function setTradingPaused(
        bool paused
    ) external;
    function setAssetTradingPaused(bytes32 asset, bool paused) external;

    /// @notice Whether trading for an asset is paused (global OR per-asset). Blocks
    ///         order execution and force-execute.
    function isTradingPaused(
        bytes32 asset
    ) external view returns (bool);

    // ──────────────────────────────────────────────────────────
    //  Admin — asset halt (permanent)
    // ──────────────────────────────────────────────────────────

    /// @notice Permanently halt an asset at a fixed settlement price. Mint and force-execute
    ///         are blocked; redemptions settle from the halt redeem address at `haltPrice`.
    function haltAsset(bytes32 asset, uint256 haltPrice) external;

    /// @notice Set the wallet holding stables used to settle redemptions of halted assets.
    function setHaltRedeemAddress(
        address addr
    ) external;

    function isAssetHalted(
        bytes32 asset
    ) external view returns (bool);
    function assetHaltPrice(
        bytes32 asset
    ) external view returns (uint256);
    function haltRedeemAddress() external view returns (address);

    // ──────────────────────────────────────────────────────────
    //  Admin — claim threshold
    // ──────────────────────────────────────────────────────────

    function setClaimThreshold(
        uint256 threshold
    ) external;
    function claimThreshold() external view returns (uint256);

    // ──────────────────────────────────────────────────────────
    //  Views — risk accounting
    // ──────────────────────────────────────────────────────────

    function withdrawalBreachesUtil(address vault, uint256 assets) external view returns (bool);
    function globalUtilizationBps() external view returns (uint256);
    function globalExposureUSD() external view returns (uint256);
    function globalCollateralUSD() external view returns (uint256);
    function assetMark(
        bytes32 asset
    ) external view returns (uint256);
    function collateralMark(
        address vault
    ) external view returns (uint256);
    function vaultCollateralAsset(
        address vault
    ) external view returns (bytes32);
    function globalAssetUnits(
        bytes32 asset
    ) external view returns (uint256);
    function assetCapUSD(
        bytes32 asset
    ) external view returns (uint256);
    function globalMaxUtilizationBps() external view returns (uint256);
    function isRegisteredVault(
        address vault
    ) external view returns (bool);
}
