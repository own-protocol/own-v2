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

    /// @notice Emitted when a vault is registered into the global pool.
    /// @param vault           Registered vault.
    /// @param collateralAsset Ticker of the vault's collateral asset.
    event VaultRegistered(address indexed vault, bytes32 indexed collateralAsset);

    /// @notice Emitted when a vault is removed from the global pool.
    /// @param vault Deregistered vault.
    event VaultDeregistered(address indexed vault);

    /// @notice Emitted when exposure is opened (eTokens minted) against an asset.
    /// @param asset   Asset ticker.
    /// @param units   eToken units added to global exposure (18 dec).
    /// @param markUSD Per-unit asset mark used (USD, 1e18).
    event ExposureOpened(bytes32 indexed asset, uint256 units, uint256 markUSD);

    /// @notice Emitted when exposure is closed (eTokens redeemed) against an asset.
    /// @param asset   Asset ticker.
    /// @param units   eToken units removed from global exposure (18 dec).
    /// @param markUSD Per-unit asset mark used (USD, 1e18).
    event ExposureClosed(bytes32 indexed asset, uint256 units, uint256 markUSD);

    /// @notice Emitted when a keeper refreshes an asset's cached mark price.
    /// @param asset   Asset ticker.
    /// @param oldMark Previous per-unit mark (USD, 1e18).
    /// @param newMark New per-unit mark (USD, 1e18).
    event AssetPricePulled(bytes32 indexed asset, uint256 oldMark, uint256 newMark);

    /// @notice Emitted when a keeper refreshes a vault's cached collateral mark.
    /// @param vault      Registered vault.
    /// @param oldMarkUSD Previous counted collateral mark (USD, 1e18).
    /// @param newMarkUSD New counted collateral mark, post-cap (USD, 1e18).
    event CollateralPricePulled(address indexed vault, uint256 oldMarkUSD, uint256 newMarkUSD);

    /// @notice Emitted when a vault's concentration cap binds — its raw collateral exceeds its
    ///         allowed share, so only `countedMarkUSD` (< rawMarkUSD) counts toward global collateral.
    /// @param vault          Registered vault.
    /// @param rawMarkUSD     Uncapped collateral value (USD, 1e18).
    /// @param countedMarkUSD Capped value counted toward the pool (USD, 1e18).
    event CollateralCapApplied(address indexed vault, uint256 rawMarkUSD, uint256 countedMarkUSD);

    /// @notice Emitted when an asset's per-asset USD concentration cap is set.
    /// @param asset  Asset ticker.
    /// @param capUSD New cap (USD, 1e18); 0 blocks minting the asset.
    event AssetCapUpdated(bytes32 indexed asset, uint256 capUSD);

    /// @notice Emitted when the global max utilisation cap is updated.
    /// @param oldBps Previous cap (BPS).
    /// @param newBps New cap (BPS).
    event GlobalMaxUtilizationUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when the global settle-price band is updated.
    /// @param oldBps Previous band (BPS).
    /// @param newBps New band (BPS).
    event SettleBandUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when the max mark age (keeper-mark freshness bound) is updated.
    /// @param oldAge Previous max mark age (seconds).
    /// @param newAge New max mark age (seconds).
    event MaxMarkAgeUpdated(uint256 oldAge, uint256 newAge);

    /// @notice Emitted when a vault's collateral concentration cap (bps of total) is updated.
    /// @param vault  Registered vault.
    /// @param oldBps Previous cap (BPS; 0 = uncapped).
    /// @param newBps New cap (BPS; 0 = uncapped).
    event CollateralCapUpdated(address indexed vault, uint256 oldBps, uint256 newBps);

    /// @notice Emitted when a halting vault's collateral is dropped from the global pool.
    /// @param vault         Halted vault.
    /// @param removedMarkUSD Collateral value removed from the pool (USD, 1e18).
    event VaultCollateralExcluded(address indexed vault, uint256 removedMarkUSD);

    /// @notice Emitted when a vault's collateral mark is reduced ahead of a bad-debt collateral release.
    /// @param vault          Releasing vault.
    /// @param assets         Collateral token amount leaving the vault.
    /// @param removedMarkUSD Collateral value removed from the pool (USD, 1e18).
    event CollateralMarkReduced(address indexed vault, uint256 assets, uint256 removedMarkUSD);

    /// @notice Emitted when an unhalting vault's collateral is re-added to the global pool.
    /// @param vault       Unhalted vault.
    /// @param addedMarkUSD Collateral value re-added to the pool, post-cap (USD, 1e18).
    event VaultCollateralReincluded(address indexed vault, uint256 addedMarkUSD);

    // ── Control surface ──────────────────────────────────────
    /// @notice Emitted when a signer is authorised with a linked settlement address.
    /// @param signer        Authorised signer.
    /// @param linkedAddress Mint sink / redeem source bound to the signer.
    event SignerRegistered(address indexed signer, address indexed linkedAddress);

    /// @notice Emitted when a signer's linked settlement address is changed.
    /// @param signer        Signer.
    /// @param linkedAddress New mint sink / redeem source.
    event SignerLinkedAddressUpdated(address indexed signer, address indexed linkedAddress);

    /// @notice Emitted when a signer is revoked.
    /// @param signer Removed signer.
    event SignerRemoved(address indexed signer);

    /// @notice Emitted when the global order-settlement payment token is changed.
    /// @param oldToken Previous payment token.
    /// @param newToken New payment token.
    event PaymentTokenUpdated(address indexed oldToken, address indexed newToken);

    /// @notice Emitted when global trading pause is toggled.
    /// @param paused True if all order execution / force-execute is now blocked.
    event TradingPausedUpdated(bool paused);

    /// @notice Emitted when per-asset trading pause is toggled.
    /// @param asset  Asset ticker.
    /// @param paused True if trading for `asset` is now blocked.
    event AssetTradingPausedUpdated(bytes32 indexed asset, bool paused);

    /// @notice Emitted when an asset is permanently halted at a fixed settlement price.
    /// @param asset     Halted asset ticker.
    /// @param haltPrice Fixed redeem settlement price (USD, 1e18).
    event AssetHalted(bytes32 indexed asset, uint256 haltPrice);

    /// @notice Emitted when the wallet settling halted-asset redemptions is changed.
    /// @param oldAddr Previous halt redeem address.
    /// @param newAddr New halt redeem address.
    event HaltRedeemAddressUpdated(address indexed oldAddr, address indexed newAddr);

    /// @notice Emitted when the force-execute claim threshold is changed.
    /// @param oldThreshold Previous delay before a resting redeem can be force-executed (seconds).
    /// @param newThreshold New delay (seconds).
    event ClaimThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /// @notice Emitted when the designated force-execution collateral vault is changed.
    /// @param oldVault Previous force-execute vault (0 = disabled).
    /// @param newVault New force-execute vault (0 = disabled).
    event ForceExecuteVaultUpdated(address indexed oldVault, address indexed newVault);

    /// @notice Emitted when an asset's exposure is re-denominated for a stock split.
    /// @param asset    Asset ticker.
    /// @param ratio    New units per old unit (1e18-scaled).
    /// @param newUnits Re-denominated global unit count (18 dec).
    /// @param newMark  Re-denominated per-unit mark (USD, 1e18).
    event SplitApplied(bytes32 indexed asset, uint256 ratio, uint256 newUnits, uint256 newMark);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Caller is not the market contract.
    error OnlyMarket();
    /// @notice Caller is not the admin.
    error OnlyAdmin();
    /// @notice Caller is not the operator.
    error OnlyOperator();
    /// @notice Caller is not a registered vault.
    error OnlyRegisteredVault();
    /// @notice Caller is not the asset registry.
    error OnlyAssetRegistry();
    /// @notice A required address was the zero address.
    error ZeroAddress();
    /// @notice A required amount was zero.
    error ZeroAmount();
    /// @notice Vault is not registered.
    error VaultNotRegistered(address vault);
    /// @notice Vault is already registered.
    error VaultAlreadyRegistered(address vault);
    /// @notice Collateral asset ticker is zero / invalid.
    error InvalidCollateralAsset();
    /// @notice Mint would breach the asset's per-asset USD concentration cap.
    /// @param attemptedUSD Asset exposure after the mint (USD, 1e18).
    /// @param capUSD       Maximum allowed exposure (USD, 1e18).
    error AssetCapBreached(bytes32 asset, uint256 attemptedUSD, uint256 capUSD);
    /// @notice Mint would breach the global utilisation cap.
    /// @param projectedBps Utilisation after the mint (BPS).
    /// @param maxBps       Maximum allowed utilisation (BPS).
    error GlobalUtilizationBreached(uint256 projectedBps, uint256 maxBps);
    /// @notice Redeem exceeds the asset's recorded global exposure.
    /// @param have Current global exposure units (18 dec).
    /// @param want Units requested to close (18 dec).
    error InsufficientExposure(bytes32 asset, uint256 have, uint256 want);
    /// @notice Global collateral has not been initialised.
    error CollateralNotInitialized();
    /// @notice No price is available for the asset.
    error PriceUnavailable(bytes32 asset);
    /// @notice Deregistering the vault would push global utilisation over the cap.
    error DeregisterWouldBreachUtilization();
    /// @notice Address is not a registered signer.
    error NotSigner(address signer);
    /// @notice Address is already a registered signer.
    error AlreadySigner(address signer);
    /// @notice Asset is already permanently halted.
    error AssetAlreadyHalted(bytes32 asset);
    /// @notice Halt price is zero / invalid.
    error InvalidHaltPrice();
    /// @notice Split ratio is zero.
    error InvalidRatio();
    /// @notice Vault's collateral is already excluded from the pool.
    error VaultAlreadyExcluded(address vault);

    /// @notice The settle band is zero or exceeds 100% (BPS).
    error InvalidSettleBand();

    /// @notice The claim threshold is zero. Zero disables force-execution and cannot be set; the
    ///         only zero state is the pre-deploy default.
    error InvalidClaimThreshold();

    /// @notice The max mark age is zero (would render every mark instantly stale and block minting);
    ///         the only zero state is the pre-deploy default.
    error InvalidMaxMarkAge();

    /// @notice The collateral concentration cap is >= BPS (100%); use 0 to disable it.
    error InvalidCollateralCap();

    /// @notice The asset mark valuing new exposure is older than the max mark age.
    error StaleAssetMark(bytes32 asset, uint256 markUpdatedAt, uint256 maxAge);

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
    //  Registration — admin only
    // ──────────────────────────────────────────────────────────

    /// @notice Register an admin-deployed vault and cache its collateral scaling. Admin-only.
    function registerVault(address vault, bytes32 collateralAsset) external;

    /// @notice Deregister a vault, removing its collateral from the global pool. Reverts if removing
    ///         it would breach global utilisation. Admin-only.
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

    /// @notice Called by a vault BEFORE it transfers collateral out of the pool (bad-debt release),
    ///         so the cached mark and global collateral drop atomically with the real assets — no
    ///         stale window for the withdrawal gate. Reduces the mark proportionally to `assets`.
    /// @param assets Collateral token amount about to leave the vault.
    function onCollateralReleased(
        uint256 assets
    ) external;

    /// @notice Whether a registered vault's collateral is currently excluded from the pool.
    function isVaultExcluded(
        address vault
    ) external view returns (bool);

    // ──────────────────────────────────────────────────────────
    //  Admin — risk parameters
    // ──────────────────────────────────────────────────────────

    function setAssetCapUSD(bytes32 asset, uint256 capUSD) external;

    /// @notice Re-denominate an asset's exposure for a stock split: units *= ratio, mark /= ratio.
    ///         USD exposure is invariant. Admin-only; run while the asset is paused.
    /// @param asset Asset ticker.
    /// @param ratio New units per old unit, 1e18-scaled (e.g. 3:1 split => 3e18).
    function applySplit(bytes32 asset, uint256 ratio) external;
    function setGlobalMaxUtilizationBps(
        uint256 bps
    ) external;

    /// @notice Set the global settle-price band (bps): quote settle prices on the execute/fill
    ///         paths must fall within ±band of the asset mark. Must be 0 < bps <= BPS. Admin-only.
    function setSettleBandBps(
        uint256 bps
    ) external;

    /// @notice Set the max age (seconds) for keeper-cached asset marks consumed by risk-increasing
    ///         exposure opens. Must be non-zero (zero is the pre-deploy default and blocks minting).
    ///         Admin-only.
    function setMaxMarkAge(
        uint256 age
    ) external;

    /// @notice Set a vault's collateral concentration cap: the max share (bps of total counted
    ///         collateral) this vault may contribute. The excess does not count toward global
    ///         collateral (so it cannot back minting or lending) — it is re-applied on the next
    ///         `pullCollateralPrice`. `0` disables the cap (uncapped); must be `< BPS`. Admin-only.
    /// @param vault Registered vault.
    /// @param bps   Concentration cap in basis points (0 = uncapped).
    function setCollateralCapBps(address vault, uint256 bps) external;

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

    /// @notice Set the delay before a resting redeem order can be force-executed. Must be non-zero
    ///         (zero is reserved for the pre-deploy default and disables force-execution). Admin-only.
    function setClaimThreshold(
        uint256 threshold
    ) external;
    function claimThreshold() external view returns (uint256);

    /// @notice Set the protocol-designated vault that sources collateral for force-execution.
    ///         `address(0)` clears it and disables force-execution (fail-safe default); a real vault
    ///         must be registered and not excluded. Operator-only; rotate to the healthiest vault.
    function setForceExecuteVault(
        address vault
    ) external;
    /// @notice The designated force-execution collateral vault, or `address(0)` if force-execution
    ///         is currently disabled.
    function forceExecuteVault() external view returns (address);

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

    /// @notice Global settle-price band in bps; execute/fill settle prices must be within ±band of the mark.
    function settleBandBps() external view returns (uint256);

    /// @notice Max age (seconds) for keeper-cached asset marks consumed by `openExposure`.
    function maxMarkAge() external view returns (uint256);

    /// @notice A vault's collateral concentration cap in bps of total counted collateral (0 = uncapped).
    function collateralCapBps(
        address vault
    ) external view returns (uint256);

    /// @notice Timestamp of the last `pullAssetPrice` that set the asset's mark (0 if never set).
    function assetMarkUpdatedAt(
        bytes32 asset
    ) external view returns (uint256);
    function isRegisteredVault(
        address vault
    ) external view returns (bool);

    /// @notice All currently-registered vault addresses (ops/indexing; not used on-chain).
    function getAllVaults() external view returns (address[] memory);
}
