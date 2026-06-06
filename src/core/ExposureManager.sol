// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IExposureManager} from "../interfaces/IExposureManager.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ExposureManager — Central, pooled exposure / utilisation / collateral accounting
/// @notice Owns all global risk math for the protocol. Vaults keep custody, LP shares, yield, and
///         lending; this manager pools risk globally. Exposure and collateral are valued only at
///         keeper-cached marks (Maker `spot`-style) refreshed by permissionless pokes. All paths are
///         O(1): `_globalExposureUSD` and `_globalCollateralUSD` are running totals.
/// @dev No external calls reach untrusted code (oracle/vault reads are views), so no ReentrancyGuard.
contract ExposureManager is IExposureManager {
    using Math for uint256;

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice Protocol registry used to resolve market, factory, admin, oracle, and asset registry.
    IProtocolRegistry public immutable registry;

    /// @inheritdoc IExposureManager
    uint256 public override globalMaxUtilizationBps;

    /// @dev Running Σ globalAssetUnits[a] × assetMark[a] / 1e18 (18-decimal USD).
    uint256 private _globalExposureUSD;

    /// @dev Running Σ collateralMark[vault] (18-decimal USD).
    uint256 private _globalCollateralUSD;

    /// @dev Asset ticker → price mark (18-decimal USD per 18-decimal unit).
    mapping(bytes32 => uint256) private _assetMark;

    /// @dev Asset ticker → total outstanding eToken units (18 decimals).
    mapping(bytes32 => uint256) private _globalAssetUnits;

    /// @dev Asset ticker → per-asset USD issuance ceiling (0 = minting blocked).
    mapping(bytes32 => uint256) private _assetCapUSD;

    /// @dev Vault → whether it is registered.
    mapping(address => bool) private _registered;

    /// @dev Vault → oracle ticker used to price its collateral.
    mapping(address => bytes32) private _vaultCollateralAsset;

    /// @dev Vault → 10 ** (18 - collateralDecimals), cached at registration.
    mapping(address => uint256) private _collateralScale;

    /// @dev Vault → collateral mark (18-decimal USD).
    mapping(address => uint256) private _collateralMark;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    /// @dev Restrict to the OwnMarket contract.
    modifier onlyMarket() {
        if (msg.sender != registry.market()) revert OnlyMarket();
        _;
    }

    /// @dev Restrict to the VaultFactory contract.
    modifier onlyFactory() {
        if (msg.sender != registry.vaultFactory()) revert OnlyFactory();
        _;
    }

    /// @dev Restrict to the protocol admin (registry owner).
    modifier onlyAdmin() {
        if (msg.sender != Ownable(address(registry)).owner()) revert OnlyAdmin();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param registry_ The protocol registry.
    constructor(
        IProtocolRegistry registry_
    ) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    // ──────────────────────────────────────────────────────────
    //  Mutation — market only
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IExposureManager
    function openExposure(address vault, bytes32 asset, uint256 units) external override onlyMarket {
        if (!_registered[vault]) revert VaultNotRegistered(vault);
        if (units == 0) revert ZeroAmount();

        uint256 mark = _assetMark[asset];
        if (mark == 0) revert PriceUnavailable(asset);
        if (_globalCollateralUSD == 0) revert CollateralNotInitialized();

        uint256 newUnits = _globalAssetUnits[asset] + units;
        uint256 newAssetUSD = newUnits.mulDiv(mark, PRECISION);
        uint256 cap = _assetCapUSD[asset];
        if (newAssetUSD > cap) revert AssetCapBreached(asset, newAssetUSD, cap);

        uint256 projExposure = _globalExposureUSD + units.mulDiv(mark, PRECISION);
        uint256 projUtil = projExposure.mulDiv(BPS, _globalCollateralUSD);
        if (projUtil > globalMaxUtilizationBps) revert GlobalUtilizationBreached(projUtil, globalMaxUtilizationBps);

        _globalAssetUnits[asset] = newUnits;
        _globalExposureUSD = projExposure;

        emit ExposureOpened(vault, asset, units, mark);
    }

    /// @inheritdoc IExposureManager
    function closeExposure(address vault, bytes32 asset, uint256 units) external override onlyMarket {
        if (units == 0) revert ZeroAmount();

        uint256 have = _globalAssetUnits[asset];
        if (have < units) revert InsufficientExposure(asset, have, units);

        uint256 mark = _assetMark[asset];
        _globalAssetUnits[asset] = have - units;
        // No underflow: this asset's contribution to the running sum is part of `_globalExposureUSD`.
        _globalExposureUSD -= units.mulDiv(mark, PRECISION);

        emit ExposureClosed(vault, asset, units, mark);
    }

    // ──────────────────────────────────────────────────────────
    //  Keeper — permissionless
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IExposureManager
    function pokeAssetPrice(
        bytes32 asset
    ) external override {
        uint256 price = _resolvePrice(asset);
        if (price == 0) revert PriceUnavailable(asset);

        uint256 old = _assetMark[asset];
        uint256 u = _globalAssetUnits[asset];
        _globalExposureUSD = _globalExposureUSD - u.mulDiv(old, PRECISION) + u.mulDiv(price, PRECISION);
        _assetMark[asset] = price;

        emit AssetPricePoked(asset, old, price);
    }

    /// @inheritdoc IExposureManager
    function pokeCollateral(
        address vault
    ) external override {
        if (!_registered[vault]) revert VaultNotRegistered(vault);

        uint256 price = _resolvePrice(_vaultCollateralAsset[vault]);
        if (price == 0) revert PriceUnavailable(_vaultCollateralAsset[vault]);

        uint256 newMark = (IERC4626(vault).totalAssets() * _collateralScale[vault]).mulDiv(price, PRECISION);
        uint256 old = _collateralMark[vault];
        _globalCollateralUSD = _globalCollateralUSD - old + newMark;
        _collateralMark[vault] = newMark;

        emit CollateralPoked(vault, old, newMark);
    }

    // ──────────────────────────────────────────────────────────
    //  Registration — factory only
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IExposureManager
    function registerVault(address vault, bytes32 collateralAsset) external override onlyFactory {
        if (vault == address(0)) revert ZeroAddress();
        if (_registered[vault]) revert VaultAlreadyRegistered(vault);

        _registered[vault] = true;
        _vaultCollateralAsset[vault] = collateralAsset;
        _collateralScale[vault] = 10 ** (18 - IERC20Metadata(IERC4626(vault).asset()).decimals());

        emit VaultRegistered(vault, collateralAsset);
    }

    /// @inheritdoc IExposureManager
    function deregisterVault(
        address vault
    ) external override onlyFactory {
        if (!_registered[vault]) revert VaultNotRegistered(vault);

        // Removing this collateral must not push global utilisation over the cap.
        uint256 projCollateral = _globalCollateralUSD - _collateralMark[vault];
        if (_globalExposureUSD != 0) {
            if (projCollateral == 0 || _globalExposureUSD.mulDiv(BPS, projCollateral) > globalMaxUtilizationBps) {
                revert DeregisterWouldBreachUtilization();
            }
        }
        _globalCollateralUSD = projCollateral;

        delete _collateralMark[vault];
        delete _registered[vault];
        delete _vaultCollateralAsset[vault];
        delete _collateralScale[vault];

        emit VaultDeregistered(vault);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IExposureManager
    function setAssetCapUSD(bytes32 asset, uint256 capUSD) external override onlyAdmin {
        _assetCapUSD[asset] = capUSD;
        emit AssetCapUpdated(asset, capUSD);
    }

    /// @inheritdoc IExposureManager
    function setGlobalMaxUtilizationBps(
        uint256 bps
    ) external override onlyAdmin {
        uint256 old = globalMaxUtilizationBps;
        globalMaxUtilizationBps = bps;
        emit GlobalMaxUtilizationUpdated(old, bps);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IExposureManager
    function withdrawalBreachesUtil(address vault, uint256 assets) external view override returns (bool) {
        uint256 ta = IERC4626(vault).totalAssets();
        if (ta == 0) return true;

        uint256 releasedUSD = _collateralMark[vault].mulDiv(assets, ta);
        uint256 projCollateral = releasedUSD >= _globalCollateralUSD ? 0 : _globalCollateralUSD - releasedUSD;
        if (projCollateral == 0) return _globalExposureUSD != 0;
        return _globalExposureUSD.mulDiv(BPS, projCollateral) > globalMaxUtilizationBps;
    }

    /// @inheritdoc IExposureManager
    function globalUtilizationBps() external view override returns (uint256) {
        if (_globalCollateralUSD == 0) return _globalExposureUSD == 0 ? 0 : type(uint256).max;
        return _globalExposureUSD.mulDiv(BPS, _globalCollateralUSD);
    }

    /// @inheritdoc IExposureManager
    function globalExposureUSD() external view override returns (uint256) {
        return _globalExposureUSD;
    }

    /// @inheritdoc IExposureManager
    function globalCollateralUSD() external view override returns (uint256) {
        return _globalCollateralUSD;
    }

    /// @inheritdoc IExposureManager
    function assetMark(
        bytes32 asset
    ) external view override returns (uint256) {
        return _assetMark[asset];
    }

    /// @inheritdoc IExposureManager
    function collateralMark(
        address vault
    ) external view override returns (uint256) {
        return _collateralMark[vault];
    }

    /// @inheritdoc IExposureManager
    function vaultCollateralAsset(
        address vault
    ) external view override returns (bytes32) {
        return _vaultCollateralAsset[vault];
    }

    /// @inheritdoc IExposureManager
    function globalAssetUnits(
        bytes32 asset
    ) external view override returns (uint256) {
        return _globalAssetUnits[asset];
    }

    /// @inheritdoc IExposureManager
    function assetCapUSD(
        bytes32 asset
    ) external view override returns (uint256) {
        return _assetCapUSD[asset];
    }

    /// @inheritdoc IExposureManager
    function isRegisteredVault(
        address vault
    ) external view override returns (bool) {
        return _registered[vault];
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Resolve the last-verified oracle price for an asset, mirroring OwnVault's resolution.
    /// @param asset Asset ticker.
    /// @return price The cached price (18 decimals); 0 if unavailable.
    function _resolvePrice(
        bytes32 asset
    ) private view returns (uint256 price) {
        uint8 oracleType = IAssetRegistry(registry.assetRegistry()).getOracleType(asset);
        address oracle = oracleType == 0 ? registry.pythOracle() : registry.inhouseOracle();
        (price,) = IOracleVerifier(oracle).getPrice(asset);
    }
}
