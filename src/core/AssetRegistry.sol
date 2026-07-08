// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";

import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IReserveVault} from "../interfaces/IReserveVault.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {AssetConfig, BPS, PRECISION, PsmConfig} from "../interfaces/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AssetRegistry — Asset whitelisting and token tracking
/// @notice Manages the set of tradeable assets, their active eToken addresses,
///         legacy tokens (post-split), and collateral parameters.
contract AssetRegistry is IAssetRegistry {
    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice ProtocolRegistry used to resolve ADMIN / OPERATOR roles.
    IProtocolRegistry public immutable registry;

    /// @dev Ticker → asset configuration.
    mapping(bytes32 => AssetConfig) private _assets;

    /// @dev Ticker → whether it has been registered (to distinguish from default struct).
    mapping(bytes32 => bool) private _registered;

    /// @dev Legacy token → conversion ratio (1e18) to the current active token.
    mapping(address => uint256) private _legacyRatio;

    /// @dev Ticker → wrapper token → PSM configuration.
    mapping(bytes32 => mapping(address => PsmConfig)) private _psmConfigs;

    /// @dev Ticker → wrapper tokens ever configured (ops/indexing enumeration; no on-chain iteration).
    mapping(bytes32 => address[]) private _psmWrappers;

    /// @dev Max per-op drift of the derived PSM ratio (BPS). 0 = unconfigured (mint/redeem inert).
    uint256 private _ratioJumpBoundBps;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    bytes32 private constant ADMIN = keccak256("ADMIN");
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    modifier onlyOperator() {
        if (!registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperator();
        _;
    }

    modifier onlyMarket() {
        if (msg.sender != registry.market()) revert OnlyMarket();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param registry_ ProtocolRegistry address (resolves ADMIN / OPERATOR roles).
    constructor(
        address registry_
    ) {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = IProtocolRegistry(registry_);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAssetRegistry
    function addAsset(bytes32 ticker, address eToken, AssetConfig calldata config) external onlyAdmin {
        if (_registered[ticker]) revert AssetAlreadyExists(ticker);
        if (eToken == address(0)) revert ZeroAddress();

        _assets[ticker] = config;
        _assets[ticker].activeToken = eToken;
        _assets[ticker].active = true;
        // Clear legacy tokens (fresh start)
        delete _assets[ticker].legacyTokens;
        _registered[ticker] = true;

        emit AssetAdded(ticker, eToken);
    }

    /// @inheritdoc IAssetRegistry
    function updateAssetConfig(bytes32 ticker, AssetConfig calldata config) external onlyAdmin {
        if (!_registered[ticker]) revert AssetNotFound(ticker);

        // Preserve activeToken, legacyTokens, and active — only update configurable params
        _assets[ticker].volatilityLevel = config.volatilityLevel;
        _assets[ticker].oracleType = config.oracleType;

        emit AssetUpdated(ticker, _assets[ticker]);
    }

    /// @inheritdoc IAssetRegistry
    function setAssetActive(bytes32 ticker, bool active) external onlyOperator {
        if (!_registered[ticker]) revert AssetNotFound(ticker);

        _assets[ticker].active = active;

        emit AssetActiveUpdated(ticker, active);
    }

    /// @inheritdoc IAssetRegistry
    function migrateToken(bytes32 ticker, address newToken, uint256 ratio) external onlyAdmin {
        if (!_registered[ticker]) revert AssetNotFound(ticker);
        // A halted asset's mark is frozen at its fixed halt price; applySplit re-denominates units/mark
        // but not the halt price, which would desync redeemHalted payouts — block migration while halted.
        if (IVaultManager(registry.vaultManager()).isAssetHalted(ticker)) revert AssetHalted(ticker);
        if (newToken == address(0)) revert ZeroAddress();
        if (ratio == 0) revert InvalidRatio();
        if (newToken == _assets[ticker].activeToken || _legacyRatio[newToken] != 0) {
            revert InvalidNewToken(newToken);
        }

        // Re-base existing legacy tokens so each still converts directly to the new active token.
        address[] storage legacy = _assets[ticker].legacyTokens;
        for (uint256 i; i < legacy.length;) {
            _legacyRatio[legacy[i]] = Math.mulDiv(_legacyRatio[legacy[i]], ratio, PRECISION);
            unchecked {
                ++i;
            }
        }

        address oldToken = _assets[ticker].activeToken;
        _legacyRatio[oldToken] = ratio;
        legacy.push(oldToken);
        _assets[ticker].activeToken = newToken;

        // Re-denominate exposure in the SAME tx, so there is never a window where the new legacy
        // ratio is live (convertLegacy mintable) while VaultManager units/mark are un-rescaled.
        IVaultManager(registry.vaultManager()).applySplit(ticker, ratio);

        emit TokenMigrated(ticker, oldToken, newToken, ratio);
    }

    /// @inheritdoc IAssetRegistry
    function legacyRatioToActive(
        address token
    ) external view returns (uint256) {
        return _legacyRatio[token];
    }

    // ──────────────────────────────────────────────────────────
    //  PSM configuration
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAssetRegistry
    function setPsmConfig(bytes32 ticker, address wrapper, address reserveVault) external onlyAdmin {
        if (!_registered[ticker]) revert AssetNotFound(ticker);
        if (wrapper == address(0) || reserveVault == address(0)) revert ZeroAddress();
        // Vault must be RWA-registered for this ticker and custody this wrapper.
        if (IVaultManager(registry.vaultManager()).vaultBackedAsset(reserveVault) != ticker) {
            revert ReserveVaultMismatch(reserveVault, ticker);
        }
        address vaultAsset = IReserveVault(reserveVault).asset();
        if (vaultAsset != wrapper) revert WrapperMismatch(wrapper, vaultAsset);

        PsmConfig storage cfg = _psmConfigs[ticker][wrapper];
        if (cfg.reserveVault == address(0)) _psmWrappers[ticker].push(wrapper);
        cfg.reserveVault = reserveVault;
        // (Re)configuration disarms the ratio-jump guard; the next PSM operation re-arms it.
        cfg.lastUsedRatio = 0;

        emit PsmConfigUpdated(ticker, wrapper, reserveVault);
    }

    /// @inheritdoc IAssetRegistry
    function setPsmPaused(bytes32 ticker, address wrapper, bool paused) external onlyOperator {
        PsmConfig storage cfg = _psmConfigs[ticker][wrapper];
        if (cfg.reserveVault == address(0)) revert PsmNotConfigured(ticker, wrapper);
        cfg.paused = paused;
        emit PsmPausedUpdated(ticker, wrapper, paused);
    }

    /// @inheritdoc IAssetRegistry
    function setRatioJumpBoundBps(
        uint256 bps
    ) external onlyAdmin {
        // Fail-closed: zero (pre-deploy default) can never be set again; > 100% is meaningless.
        if (bps == 0 || bps > BPS) revert InvalidRatioJumpBound();
        uint256 old = _ratioJumpBoundBps;
        _ratioJumpBoundBps = bps;
        emit RatioJumpBoundUpdated(old, bps);
    }

    /// @inheritdoc IAssetRegistry
    function resetRatioGuard(bytes32 ticker, address wrapper) external onlyOperator {
        PsmConfig storage cfg = _psmConfigs[ticker][wrapper];
        if (cfg.reserveVault == address(0)) revert PsmNotConfigured(ticker, wrapper);
        cfg.lastUsedRatio = 0;
        emit RatioGuardReset(ticker, wrapper);
    }

    /// @inheritdoc IAssetRegistry
    function notePsmRatio(bytes32 ticker, address wrapper, uint256 ratio) external onlyMarket {
        _psmConfigs[ticker][wrapper].lastUsedRatio = ratio;
        emit PsmRatioNoted(ticker, wrapper, ratio);
    }

    /// @inheritdoc IAssetRegistry
    function getPsmConfig(bytes32 ticker, address wrapper) external view returns (PsmConfig memory config) {
        config = _psmConfigs[ticker][wrapper];
        if (config.reserveVault == address(0)) revert PsmNotConfigured(ticker, wrapper);
    }

    /// @inheritdoc IAssetRegistry
    function getPsmWrappers(
        bytes32 ticker
    ) external view returns (address[] memory) {
        return _psmWrappers[ticker];
    }

    /// @inheritdoc IAssetRegistry
    function ratioJumpBoundBps() external view returns (uint256) {
        return _ratioJumpBoundBps;
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
            }
        }

        return false;
    }

    /// @inheritdoc IAssetRegistry
    function getOracleType(
        bytes32 ticker
    ) external view returns (uint8) {
        if (!_registered[ticker]) revert AssetNotFound(ticker);
        return _assets[ticker].oracleType;
    }
}
