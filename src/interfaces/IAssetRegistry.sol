// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetConfig, PsmConfig} from "./types/Types.sol";

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

    /// @notice Emitted when an asset is migrated to a new token (e.g. stock split).
    /// @param ticker   Asset ticker.
    /// @param oldToken Previous active eToken (now legacy).
    /// @param newToken New active eToken.
    /// @param ratio    New tokens per old token (1e18-scaled).
    event TokenMigrated(bytes32 indexed ticker, address indexed oldToken, address indexed newToken, uint256 ratio);

    /// @notice Emitted when a (asset, wrapper) PSM configuration is set or replaced.
    /// @param ticker       Asset ticker.
    /// @param wrapper      Wrapper token address.
    /// @param reserveVault ReserveVault holding the wrapper reserve.
    event PsmConfigUpdated(bytes32 indexed ticker, address indexed wrapper, address indexed reserveVault);

    /// @notice Emitted when a wrapper's PSM pause flag is toggled.
    /// @param ticker  Asset ticker.
    /// @param wrapper Wrapper token address.
    /// @param paused  New pause flag.
    event PsmPausedUpdated(bytes32 indexed ticker, address indexed wrapper, bool paused);

    /// @notice Emitted when trustless DvP fills (psmFillOrder) are paused or resumed for an asset.
    /// @param ticker Asset ticker.
    /// @param paused New pause flag.
    event PsmFillPausedUpdated(bytes32 indexed ticker, bool paused);

    /// @notice Emitted when the global PSM ratio-jump bound is updated.
    /// @param oldBps Previous bound (BPS; 0 = unconfigured pre-deploy default).
    /// @param newBps New bound (BPS; always non-zero once configured).
    event RatioJumpBoundUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when a wrapper's last-used conversion ratio is recorded by the market.
    /// @param ticker  Asset ticker.
    /// @param wrapper Wrapper token address.
    /// @param ratio   Conversion ratio used (eTokens per wrapper unit, 1e18).
    event PsmRatioNoted(bytes32 indexed ticker, address indexed wrapper, uint256 ratio);

    /// @notice Emitted when the operator disarms a wrapper's ratio-jump guard (post
    ///         corporate-action acknowledgment); the next PSM operation re-arms it.
    /// @param ticker  Asset ticker.
    /// @param wrapper Wrapper token address.
    event RatioGuardReset(bytes32 indexed ticker, address indexed wrapper);

    /// @notice Emitted when the protocol's share of PSM fill spreads is updated.
    /// @param oldBps Previous share (BPS).
    /// @param newBps New share (BPS).
    event PsmFillSpreadShareUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when a vault's lending allowlist entry for an asset is updated.
    /// @param ticker  Asset ticker.
    /// @param vault   Vault whose bound BorrowManager the entry gates.
    /// @param allowed New allowlist flag.
    event LendingVaultAllowedUpdated(bytes32 indexed ticker, address indexed vault, bool allowed);

    /// @notice Emitted when a maker's allowlist entry for an asset is updated.
    /// @param ticker  Asset ticker.
    /// @param signer  Maker's quote-signing key.
    /// @param allowed New allowlist flag.
    event MakerAllowedUpdated(bytes32 indexed ticker, address indexed signer, bool allowed);

    /// @notice Emitted when a vault's force-execute candidate-pool entry for an asset is updated.
    /// @param ticker  Asset ticker.
    /// @param vault   Candidate collateral-source vault.
    /// @param allowed New pool flag.
    event ForceExecuteVaultAllowedUpdated(bytes32 indexed ticker, address indexed vault, bool allowed);

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

    /// @notice The asset is halted; its frozen halt price cannot be re-denominated by a migration.
    error AssetHalted(bytes32 ticker);

    /// @notice Caller does not hold the asset-registry admin role.
    error OnlyAdmin();

    /// @notice Caller does not hold the asset-registry operator role.
    error OnlyOperator();

    /// @notice Caller is not the market contract.
    error OnlyMarket();

    /// @notice The reserve vault is not registered on the VaultManager as an RWA vault backing
    ///         this ticker (`vaultBackedAsset(reserveVault) != ticker`).
    error ReserveVaultMismatch(address reserveVault, bytes32 ticker);

    /// @notice The reserve vault holds a different token than the wrapper being configured.
    error WrapperMismatch(address wrapper, address vaultAsset);

    /// @notice No PSM configuration exists for this (ticker, wrapper) pair.
    error PsmNotConfigured(bytes32 ticker, address wrapper);

    /// @notice The ratio-jump bound must be non-zero and at most BPS (100%).
    error InvalidRatioJumpBound();

    /// @notice The PSM fill spread share must be at most BPS (100%).
    error InvalidSpreadShare();

    /// @notice A non-zero spread share routes fees to the treasury, which is not configured.
    error TreasuryNotSet();

    /// @notice The vault is RWA-registered (a ReserveVault); it never binds a BorrowManager and
    ///         cannot enter the lending allowlist.
    error RwaVaultNotEligible(address vault);

    /// @notice The signer is not registered on the VaultManager's signer registry.
    error SignerNotRegistered(address signer);

    /// @notice The vault is not registered on the VaultManager.
    error VaultNotRegistered(address vault);

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
    //  PSM configuration
    // ──────────────────────────────────────────────────────────

    /// @notice Configure (or replace) the ReserveVault backing a wrapper for `ticker`. Admin-only.
    ///         The vault must be registered on the VaultManager with `backedAsset == ticker` and
    ///         must hold `wrapper` as its asset. Re-configuring resets the ratio-jump guard.
    /// @param ticker       Asset ticker.
    /// @param wrapper      Wrapper token address (e.g. ondoTSLA).
    /// @param reserveVault ReserveVault holding the wrapper reserve.
    function setPsmConfig(bytes32 ticker, address wrapper, address reserveVault) external;

    /// @notice Pause or resume PSM operations for one wrapper. Operator-only (instant response).
    /// @param ticker  Asset ticker.
    /// @param wrapper Wrapper token address.
    /// @param paused  New pause flag.
    function setPsmPaused(bytes32 ticker, address wrapper, bool paused) external;

    /// @notice Pause or resume trustless DvP fills (psmFillOrder) for an asset — the fill channel
    ///         only; psmMint/psmRedeem and the RFQ paths are unaffected. Default false = live.
    ///         Operator-only (instant response).
    /// @param ticker Asset ticker.
    /// @param paused New pause flag.
    function setPsmFillPaused(bytes32 ticker, bool paused) external;

    /// @notice Whether trustless DvP fills (psmFillOrder) are paused for `ticker`.
    /// @param ticker Asset ticker.
    /// @return True if fills are paused.
    function isPsmFillPaused(
        bytes32 ticker
    ) external view returns (bool);

    /// @notice Set the global PSM ratio-jump bound in BPS (max per-operation drift of the derived
    ///         conversion ratio). Must be non-zero and ≤ BPS; zero is the pre-deploy default that
    ///         disables PSM mint/redeem and can never be set again. Admin-only.
    /// @param bps New bound in basis points.
    function setRatioJumpBoundBps(
        uint256 bps
    ) external;

    /// @notice Set the protocol's share of the spread captured by PSM fills — the gap between a
    ///         resting order's limit price and the mark, paid in the fill's stablecoin leg to the
    ///         treasury. At most BPS (100%); zero (the default) disables the fee. A non-zero
    ///         share requires the treasury to be configured. Admin-only.
    /// @param bps New share in basis points.
    function setPsmFillSpreadShareBps(
        uint256 bps
    ) external;

    /// @notice Protocol share of PSM fill spreads (BPS; 0 = no fee).
    function psmFillSpreadShareBps() external view returns (uint256);

    /// @notice Disarm a wrapper's ratio-jump guard after an acknowledged corporate action; the
    ///         next PSM operation re-arms it. Operator-only.
    /// @param ticker  Asset ticker.
    /// @param wrapper Wrapper token address.
    function resetRatioGuard(bytes32 ticker, address wrapper) external;

    /// @notice Record the conversion ratio used by a PSM operation (ratio-jump guard state).
    ///         Market-only.
    /// @param ticker  Asset ticker.
    /// @param wrapper Wrapper token address.
    /// @param ratio   Conversion ratio used (eTokens per wrapper unit, 1e18-scaled).
    function notePsmRatio(bytes32 ticker, address wrapper, uint256 ratio) external;

    /// @notice PSM configuration for a (ticker, wrapper) pair. Reverts if not configured.
    /// @param ticker  Asset ticker.
    /// @param wrapper Wrapper token address.
    /// @return config The PSM configuration.
    function getPsmConfig(bytes32 ticker, address wrapper) external view returns (PsmConfig memory config);

    /// @notice All wrapper tokens ever configured for `ticker` (ops/indexing enumeration).
    /// @param ticker Asset ticker.
    /// @return wrappers Array of configured wrapper token addresses.
    function getPsmWrappers(
        bytes32 ticker
    ) external view returns (address[] memory wrappers);

    /// @notice Global PSM ratio-jump bound (BPS; 0 = unconfigured — PSM mint/redeem inert).
    function ratioJumpBoundBps() external view returns (uint256);

    // ──────────────────────────────────────────────────────────
    //  Lending allowlist
    // ──────────────────────────────────────────────────────────

    /// @notice Allow or revoke lending against `ticker` by the BorrowManager bound to `vault`.
    ///         Default-deny: borrows revert until the (asset, vault) pair is allowed. Revocation
    ///         blocks new borrows only — existing positions still repay, liquidate, and
    ///         halt-settle. RWA vaults (ReserveVaults) are never eligible. Admin-only.
    /// @param ticker  Asset ticker.
    /// @param vault   Vault whose bound BorrowManager the entry gates.
    /// @param allowed New allowlist flag.
    function setLendingVaultAllowed(bytes32 ticker, address vault, bool allowed) external;

    /// @notice Whether the BorrowManager bound to `vault` may open new borrows against `ticker`.
    /// @param ticker Asset ticker.
    /// @param vault  Vault whose bound BorrowManager is checked.
    /// @return True if the (asset, vault) pair is allowed.
    function isLendingVaultAllowed(bytes32 ticker, address vault) external view returns (bool);

    // ──────────────────────────────────────────────────────────
    //  Maker allowlist
    // ──────────────────────────────────────────────────────────

    /// @notice Allow or revoke `signer` as a maker for `ticker`. Default-deny: quote settlement
    ///         and reserve recovery revert until the (asset, signer) pair is allowed. Scopes each
    ///         signer key to its assets (leaked-key blast-radius containment, composing with the
    ///         settle band). Granting requires the signer to be registered on the VaultManager;
    ///         revocation is always possible. Admin-only.
    /// @param ticker  Asset ticker.
    /// @param signer  Maker's quote-signing key.
    /// @param allowed New allowlist flag.
    function setMakerAllowed(bytes32 ticker, address signer, bool allowed) external;

    /// @notice Whether `signer` may settle quotes for `ticker` (OwnMarket) and recover reserve
    ///         surplus from `ticker`'s ReserveVaults (ReserveVault.withdraw).
    /// @param ticker Asset ticker.
    /// @param signer Maker's quote-signing key.
    /// @return True if the (asset, signer) pair is allowed.
    function isMakerAllowed(bytes32 ticker, address signer) external view returns (bool);

    // ──────────────────────────────────────────────────────────
    //  Force-execute vault allowlist
    // ──────────────────────────────────────────────────────────

    /// @notice Admit or remove `vault` from the admin-approved pool of collateral sources for
    ///         `ticker` force-executions. The redeemer picks any allowlisted vault at execution
    ///         time — force-execution is the user's last-resort exit, so source flexibility is
    ///         deliberate. An empty pool (the default) disables force-execution for the asset
    ///         (fail-safe). Granting requires the vault to be registered on the VaultManager and
    ///         non-RWA; revocation is always possible and bites immediately. Admin-only.
    /// @param ticker  Asset ticker.
    /// @param vault   Collateral-source vault.
    /// @param allowed New pool flag.
    function setForceExecuteVaultAllowed(bytes32 ticker, address vault, bool allowed) external;

    /// @notice Whether `vault` may source collateral for `ticker` force-executions.
    /// @param ticker Asset ticker.
    /// @param vault  Collateral-source vault.
    /// @return True if the (asset, vault) pair is in the pool.
    function isForceExecuteVaultAllowed(bytes32 ticker, address vault) external view returns (bool);

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
