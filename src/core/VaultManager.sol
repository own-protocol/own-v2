// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title VaultManager — Central pooled risk accounting + global protocol controls
/// @notice Owns all global risk math (exposure / utilisation / collateral) and the protocol-wide
///         control surface: the signer registry, the payment token, trading pause, asset halts,
///         and the claim threshold. Vaults keep custody, LP shares, yield, and lending; this
///         manager pools risk globally. Exposure and collateral are valued only at keeper-cached
///         marks refreshed by permissionless price pulls. Risk paths are O(1): `_globalExposureUSD`
///         and `_globalCollateralUSD` are running totals.
/// @dev No external calls reach untrusted code (oracle/vault reads are views), so no ReentrancyGuard.
contract VaultManager is IVaultManager {
    using Math for uint256;

    // ──────────────────────────────────────────────────────────
    //  State — risk accounting
    // ──────────────────────────────────────────────────────────

    /// @notice Protocol registry used to resolve market, factory, admin, oracle, and asset registry.
    IProtocolRegistry public immutable registry;

    /// @inheritdoc IVaultManager
    uint256 public override globalMaxUtilizationBps;

    /// @inheritdoc IVaultManager
    uint256 public override settleBandBps;

    /// @inheritdoc IVaultManager
    uint256 public override maxMarkAge;

    /// @dev Running Σ _assetExposureUSD[a] (18-decimal USD).
    uint256 private _globalExposureUSD;

    /// @dev Running Σ collateralMark[vault] over non-excluded vaults (18-decimal USD).
    uint256 private _globalCollateralUSD;

    mapping(bytes32 => uint256) private _assetMark;
    mapping(bytes32 => uint256) private _assetMarkUpdatedAt;
    mapping(bytes32 => uint256) private _globalAssetUnits;
    mapping(bytes32 => uint256) private _assetExposureUSD;
    mapping(bytes32 => uint256) private _assetCapUSD;

    mapping(address => bool) private _registered;
    mapping(address => bytes32) private _vaultCollateralAsset;
    mapping(address => uint256) private _collateralScale;
    mapping(address => uint256) private _collateralMark;

    /// @dev Vault → concentration cap (bps of total counted collateral); 0 = uncapped.
    mapping(address => uint256) private _collateralCapBps;

    /// @dev Enumerable set of registered vaults (ops/indexing convenience; no on-chain iteration).
    address[] private _vaultList;
    /// @dev Vault → 1-based index into `_vaultList` (0 = not present), for O(1) swap-remove.
    mapping(address => uint256) private _vaultIndex;

    /// @dev Vault → whether its collateral is currently excluded from the global pool (halted vault).
    mapping(address => bool) private _excluded;

    // ──────────────────────────────────────────────────────────
    //  State — control surface
    // ──────────────────────────────────────────────────────────

    /// @dev Authorised signer → linked settlement address (mint sink / redeem source).
    mapping(address => address) private _signerLinked;
    mapping(address => bool) private _isSigner;

    /// @dev Single global order-settlement currency for all vaults.
    address private _paymentToken;

    /// @dev Global temporary trading pause (blocks order execution + force-execute).
    bool private _tradingPaused;
    mapping(bytes32 => bool) private _assetTradingPaused;

    /// @dev Permanent per-asset halt with a fixed settlement price.
    mapping(bytes32 => bool) private _assetHalted;
    mapping(bytes32 => uint256) private _assetHaltPrice;

    /// @dev Wallet holding stables used to settle redemptions of halted assets.
    address private _haltRedeemAddress;

    /// @dev Delay after a resting redeem order is placed before it can be force-executed.
    uint256 private _claimThreshold;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyMarket() {
        if (msg.sender != registry.market()) revert OnlyMarket();
        _;
    }

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

    modifier onlyRegisteredVault() {
        if (!_registered[msg.sender]) revert OnlyRegisteredVault();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    constructor(
        IProtocolRegistry registry_
    ) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    // ──────────────────────────────────────────────────────────
    //  Mutation — market only
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function openExposure(bytes32 asset, uint256 units) external override onlyMarket {
        if (units == 0) revert ZeroAmount();

        uint256 mark = _assetMark[asset];
        if (mark == 0) revert PriceUnavailable(asset);
        // Risk-increasing path: the mark valuing new exposure must be keeper-fresh. closeExposure
        // (risk-reducing) is intentionally exempt.
        if (block.timestamp - _assetMarkUpdatedAt[asset] > maxMarkAge) {
            revert StaleAssetMark(asset, _assetMarkUpdatedAt[asset], maxMarkAge);
        }
        if (_globalCollateralUSD == 0) revert CollateralNotInitialized();

        uint256 newUnits = _globalAssetUnits[asset] + units;
        uint256 newAssetUSD = newUnits.mulDiv(mark, PRECISION);
        uint256 cap = _assetCapUSD[asset];
        if (newAssetUSD > cap) revert AssetCapBreached(asset, newAssetUSD, cap);

        uint256 projExposure = _globalExposureUSD - _assetExposureUSD[asset] + newAssetUSD;
        uint256 projUtil = projExposure.mulDiv(BPS, _globalCollateralUSD);
        if (projUtil > globalMaxUtilizationBps) revert GlobalUtilizationBreached(projUtil, globalMaxUtilizationBps);

        _globalAssetUnits[asset] = newUnits;
        _assetExposureUSD[asset] = newAssetUSD;
        _globalExposureUSD = projExposure;

        emit ExposureOpened(asset, units, mark);
    }

    /// @inheritdoc IVaultManager
    function closeExposure(bytes32 asset, uint256 units) external override onlyMarket {
        if (units == 0) revert ZeroAmount();

        uint256 have = _globalAssetUnits[asset];
        if (have < units) revert InsufficientExposure(asset, have, units);

        uint256 mark = _assetMark[asset];
        if (mark == 0) revert PriceUnavailable(asset);
        uint256 newUnits = have - units;
        uint256 newAssetUSD = newUnits.mulDiv(mark, PRECISION);
        _globalExposureUSD = _globalExposureUSD - _assetExposureUSD[asset] + newAssetUSD;
        _assetExposureUSD[asset] = newAssetUSD;
        _globalAssetUnits[asset] = newUnits;

        emit ExposureClosed(asset, units, mark);
    }

    // ──────────────────────────────────────────────────────────
    //  Keeper — permissionless
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function pullAssetPrice(
        bytes32 asset
    ) external override {
        // A permanently halted asset is marked at its fixed halt price; keepers cannot re-mark it.
        if (_assetHalted[asset]) {
            uint256 hp = _assetHaltPrice[asset];
            uint256 old0 = _assetMark[asset];
            if (hp != old0) {
                uint256 haltedUSD = _globalAssetUnits[asset].mulDiv(hp, PRECISION);
                _globalExposureUSD = _globalExposureUSD - _assetExposureUSD[asset] + haltedUSD;
                _assetExposureUSD[asset] = haltedUSD;
                _assetMark[asset] = hp;
                _assetMarkUpdatedAt[asset] = block.timestamp;
                emit AssetPricePulled(asset, old0, hp);
            }
            return;
        }

        uint256 price = _resolvePrice(asset);
        if (price == 0) revert PriceUnavailable(asset);

        uint256 old = _assetMark[asset];
        uint256 newAssetUSD = _globalAssetUnits[asset].mulDiv(price, PRECISION);
        _globalExposureUSD = _globalExposureUSD - _assetExposureUSD[asset] + newAssetUSD;
        _assetExposureUSD[asset] = newAssetUSD;
        _assetMark[asset] = price;
        _assetMarkUpdatedAt[asset] = block.timestamp;

        emit AssetPricePulled(asset, old, price);
    }

    /// @inheritdoc IVaultManager
    function pullCollateralPrice(
        address vault
    ) external override {
        if (!_registered[vault]) revert VaultNotRegistered(vault);
        if (_excluded[vault]) revert VaultAlreadyExcluded(vault);

        uint256 price = _resolvePrice(_vaultCollateralAsset[vault]);
        if (price == 0) revert PriceUnavailable(_vaultCollateralAsset[vault]);

        uint256 rawMark = (IERC4626(vault).totalAssets() * _collateralScale[vault]).mulDiv(price, PRECISION);
        uint256 old = _collateralMark[vault];
        uint256 others = _globalCollateralUSD - old;
        uint256 newMark = _cappedContribution(vault, rawMark, others);
        _globalCollateralUSD = others + newMark;
        _collateralMark[vault] = newMark;

        emit CollateralPricePulled(vault, old, newMark);
        if (newMark < rawMark) emit CollateralCapApplied(vault, rawMark, newMark);
    }

    // ──────────────────────────────────────────────────────────
    //  Registration — admin only
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function registerVault(address vault, bytes32 collateralAsset) external override onlyAdmin {
        if (vault == address(0)) revert ZeroAddress();
        if (collateralAsset == bytes32(0)) revert InvalidCollateralAsset();
        if (_registered[vault]) revert VaultAlreadyRegistered(vault);

        _registered[vault] = true;
        _vaultCollateralAsset[vault] = collateralAsset;
        _collateralScale[vault] = 10 ** (18 - IERC20Metadata(IERC4626(vault).asset()).decimals());

        _vaultList.push(vault);
        _vaultIndex[vault] = _vaultList.length; // 1-based

        emit VaultRegistered(vault, collateralAsset);
    }

    /// @inheritdoc IVaultManager
    function deregisterVault(
        address vault
    ) external override onlyAdmin {
        if (!_registered[vault]) revert VaultNotRegistered(vault);

        // Removing this collateral must not push global utilisation over the cap.
        uint256 projCollateral = _globalCollateralUSD - _collateralMark[vault];
        if (_globalExposureUSD != 0) {
            if (projCollateral == 0 || _globalExposureUSD.mulDiv(BPS, projCollateral) > globalMaxUtilizationBps) {
                revert DeregisterWouldBreachUtilization();
            }
        }
        _globalCollateralUSD = projCollateral;

        // O(1) swap-remove from the enumerable list.
        uint256 idx = _vaultIndex[vault]; // 1-based
        uint256 lastIdx = _vaultList.length;
        if (idx != lastIdx) {
            address lastVault = _vaultList[lastIdx - 1];
            _vaultList[idx - 1] = lastVault;
            _vaultIndex[lastVault] = idx;
        }
        _vaultList.pop();
        delete _vaultIndex[vault];

        delete _collateralMark[vault];
        delete _collateralCapBps[vault];
        delete _registered[vault];
        delete _vaultCollateralAsset[vault];
        delete _collateralScale[vault];
        delete _excluded[vault];

        emit VaultDeregistered(vault);
    }

    // ──────────────────────────────────────────────────────────
    //  Vault halt notifications — registered vault only
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function onVaultHalted() external override onlyRegisteredVault {
        if (_excluded[msg.sender]) revert VaultAlreadyExcluded(msg.sender);
        uint256 removed = _collateralMark[msg.sender];
        _globalCollateralUSD -= removed;
        _collateralMark[msg.sender] = 0;
        _excluded[msg.sender] = true;
        emit VaultCollateralExcluded(msg.sender, removed);
    }

    /// @inheritdoc IVaultManager
    function onVaultUnhalted() external override onlyRegisteredVault {
        if (!_excluded[msg.sender]) return;
        _excluded[msg.sender] = false;

        uint256 price = _resolvePrice(_vaultCollateralAsset[msg.sender]);
        if (price == 0) revert PriceUnavailable(_vaultCollateralAsset[msg.sender]);
        uint256 rawMark = (IERC4626(msg.sender).totalAssets() * _collateralScale[msg.sender]).mulDiv(price, PRECISION);
        // The unhalting vault currently contributes 0, so the rest of the pool is the full global.
        uint256 newMark = _cappedContribution(msg.sender, rawMark, _globalCollateralUSD);
        _globalCollateralUSD += newMark;
        _collateralMark[msg.sender] = newMark;
        emit VaultCollateralReincluded(msg.sender, newMark);
        if (newMark < rawMark) emit CollateralCapApplied(msg.sender, rawMark, newMark);
    }

    /// @inheritdoc IVaultManager
    function onCollateralReleased(
        uint256 assets
    ) external override onlyRegisteredVault {
        uint256 mark = _collateralMark[msg.sender];
        if (mark == 0) return; // excluded/unmarked vault — nothing in the pool to reduce
        uint256 ta = IERC4626(msg.sender).totalAssets();
        uint256 removedUSD = ta == 0 ? mark : mark.mulDiv(assets, ta);
        if (removedUSD > mark) removedUSD = mark;
        _collateralMark[msg.sender] = mark - removedUSD;
        _globalCollateralUSD -= removedUSD;
        emit CollateralMarkReduced(msg.sender, assets, removedUSD);
    }

    /// @inheritdoc IVaultManager
    function isVaultExcluded(
        address vault
    ) external view override returns (bool) {
        return _excluded[vault];
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — risk parameters
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function setAssetCapUSD(bytes32 asset, uint256 capUSD) external override onlyAdmin {
        _assetCapUSD[asset] = capUSD;
        emit AssetCapUpdated(asset, capUSD);
    }

    /// @inheritdoc IVaultManager
    function applySplit(bytes32 asset, uint256 ratio) external override onlyAdmin {
        if (ratio == 0) revert InvalidRatio();
        // USD exposure is split-invariant: only the unit count and per-unit mark are re-denominated.
        _globalAssetUnits[asset] = _globalAssetUnits[asset].mulDiv(ratio, PRECISION);
        uint256 mark = _assetMark[asset];
        if (mark != 0) _assetMark[asset] = mark.mulDiv(PRECISION, ratio);
        emit SplitApplied(asset, ratio, _globalAssetUnits[asset], _assetMark[asset]);
    }

    /// @inheritdoc IVaultManager
    function setGlobalMaxUtilizationBps(
        uint256 bps
    ) external override onlyAdmin {
        uint256 old = globalMaxUtilizationBps;
        globalMaxUtilizationBps = bps;
        emit GlobalMaxUtilizationUpdated(old, bps);
    }

    /// @inheritdoc IVaultManager
    function setSettleBandBps(
        uint256 bps
    ) external override onlyAdmin {
        if (bps == 0 || bps > BPS) revert InvalidSettleBand();
        uint256 old = settleBandBps;
        settleBandBps = bps;
        emit SettleBandUpdated(old, bps);
    }

    /// @inheritdoc IVaultManager
    function setMaxMarkAge(
        uint256 age
    ) external override onlyAdmin {
        // Zero would render every mark instantly stale and block minting; reserved for the
        // pre-deploy default. Once configured it stays non-zero.
        if (age == 0) revert InvalidMaxMarkAge();
        uint256 old = maxMarkAge;
        maxMarkAge = age;
        emit MaxMarkAgeUpdated(old, age);
    }

    /// @inheritdoc IVaultManager
    function setCollateralCapBps(address vault, uint256 bps) external override onlyAdmin {
        if (!_registered[vault]) revert VaultNotRegistered(vault);
        // 0 disables the cap; BPS (100%) and above are meaningless and divide-by-zero in the share
        // formula. The new cap takes effect on the vault's next pullCollateralPrice.
        if (bps >= BPS) revert InvalidCollateralCap();
        uint256 old = _collateralCapBps[vault];
        _collateralCapBps[vault] = bps;
        emit CollateralCapUpdated(vault, old, bps);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — signer registry
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function registerSigner(address signer, address linkedAddress) external override onlyAdmin {
        if (signer == address(0) || linkedAddress == address(0)) revert ZeroAddress();
        if (_isSigner[signer]) revert AlreadySigner(signer);
        _isSigner[signer] = true;
        _signerLinked[signer] = linkedAddress;
        emit SignerRegistered(signer, linkedAddress);
    }

    /// @inheritdoc IVaultManager
    function updateSignerLinkedAddress(address signer, address linkedAddress) external override onlyAdmin {
        if (!_isSigner[signer]) revert NotSigner(signer);
        if (linkedAddress == address(0)) revert ZeroAddress();
        _signerLinked[signer] = linkedAddress;
        emit SignerLinkedAddressUpdated(signer, linkedAddress);
    }

    /// @inheritdoc IVaultManager
    function removeSigner(
        address signer
    ) external override onlyOperator {
        if (!_isSigner[signer]) revert NotSigner(signer);
        delete _isSigner[signer];
        delete _signerLinked[signer];
        emit SignerRemoved(signer);
    }

    /// @inheritdoc IVaultManager
    function isSigner(
        address account
    ) external view override returns (bool) {
        return _isSigner[account];
    }

    /// @inheritdoc IVaultManager
    function signerLinkedAddress(
        address signer
    ) external view override returns (address) {
        return _signerLinked[signer];
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — payment token
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function setPaymentToken(
        address token
    ) external override onlyAdmin {
        if (token == address(0)) revert ZeroAddress();
        if (IERC20Metadata(token).decimals() > 18) revert ZeroAddress();
        address old = _paymentToken;
        _paymentToken = token;
        emit PaymentTokenUpdated(old, token);
    }

    /// @inheritdoc IVaultManager
    function paymentToken() external view override returns (address) {
        return _paymentToken;
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — trading pause (temporary)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function setTradingPaused(
        bool paused
    ) external override onlyOperator {
        _tradingPaused = paused;
        emit TradingPausedUpdated(paused);
    }

    /// @inheritdoc IVaultManager
    function setAssetTradingPaused(bytes32 asset, bool paused) external override onlyOperator {
        _assetTradingPaused[asset] = paused;
        emit AssetTradingPausedUpdated(asset, paused);
    }

    /// @inheritdoc IVaultManager
    function isTradingPaused(
        bytes32 asset
    ) external view override returns (bool) {
        return _tradingPaused || _assetTradingPaused[asset];
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — asset halt (permanent)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function haltAsset(bytes32 asset, uint256 haltPrice) external override onlyOperator {
        if (haltPrice == 0) revert InvalidHaltPrice();
        if (_assetHalted[asset]) revert AssetAlreadyHalted(asset);
        _assetHalted[asset] = true;
        _assetHaltPrice[asset] = haltPrice;

        // Re-mark outstanding exposure at the fixed halt price so utilisation reflects the freeze.
        uint256 haltedUSD = _globalAssetUnits[asset].mulDiv(haltPrice, PRECISION);
        _globalExposureUSD = _globalExposureUSD - _assetExposureUSD[asset] + haltedUSD;
        _assetExposureUSD[asset] = haltedUSD;
        _assetMark[asset] = haltPrice;
        _assetMarkUpdatedAt[asset] = block.timestamp;

        emit AssetHalted(asset, haltPrice);
    }

    /// @inheritdoc IVaultManager
    function setHaltRedeemAddress(
        address addr
    ) external override onlyAdmin {
        if (addr == address(0)) revert ZeroAddress();
        address old = _haltRedeemAddress;
        _haltRedeemAddress = addr;
        emit HaltRedeemAddressUpdated(old, addr);
    }

    /// @inheritdoc IVaultManager
    function isAssetHalted(
        bytes32 asset
    ) external view override returns (bool) {
        return _assetHalted[asset];
    }

    /// @inheritdoc IVaultManager
    function assetHaltPrice(
        bytes32 asset
    ) external view override returns (uint256) {
        return _assetHaltPrice[asset];
    }

    /// @inheritdoc IVaultManager
    function haltRedeemAddress() external view override returns (address) {
        return _haltRedeemAddress;
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — claim threshold
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function setClaimThreshold(
        uint256 threshold
    ) external override onlyAdmin {
        // Zero disables force-execution and is reserved for the pre-deploy default; once configured
        // it can never be reset to zero.
        if (threshold == 0) revert InvalidClaimThreshold();
        uint256 old = _claimThreshold;
        _claimThreshold = threshold;
        emit ClaimThresholdUpdated(old, threshold);
    }

    /// @inheritdoc IVaultManager
    function claimThreshold() external view override returns (uint256) {
        return _claimThreshold;
    }

    // ──────────────────────────────────────────────────────────
    //  Views — risk accounting
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function withdrawalBreachesUtil(address vault, uint256 assets) external view override returns (bool) {
        uint256 ta = IERC4626(vault).totalAssets();
        if (ta == 0) return true;

        uint256 releasedUSD = _collateralMark[vault].mulDiv(assets, ta);
        uint256 projCollateral = releasedUSD >= _globalCollateralUSD ? 0 : _globalCollateralUSD - releasedUSD;
        if (projCollateral == 0) return _globalExposureUSD != 0;
        return _globalExposureUSD.mulDiv(BPS, projCollateral) > globalMaxUtilizationBps;
    }

    /// @inheritdoc IVaultManager
    function globalUtilizationBps() external view override returns (uint256) {
        if (_globalCollateralUSD == 0) return _globalExposureUSD == 0 ? 0 : type(uint256).max;
        return _globalExposureUSD.mulDiv(BPS, _globalCollateralUSD);
    }

    /// @inheritdoc IVaultManager
    function globalExposureUSD() external view override returns (uint256) {
        return _globalExposureUSD;
    }

    /// @inheritdoc IVaultManager
    function globalCollateralUSD() external view override returns (uint256) {
        return _globalCollateralUSD;
    }

    /// @inheritdoc IVaultManager
    function assetMark(
        bytes32 asset
    ) external view override returns (uint256) {
        return _assetMark[asset];
    }

    /// @inheritdoc IVaultManager
    function assetMarkUpdatedAt(
        bytes32 asset
    ) external view override returns (uint256) {
        return _assetMarkUpdatedAt[asset];
    }

    /// @inheritdoc IVaultManager
    function collateralMark(
        address vault
    ) external view override returns (uint256) {
        return _collateralMark[vault];
    }

    /// @inheritdoc IVaultManager
    function collateralCapBps(
        address vault
    ) external view override returns (uint256) {
        return _collateralCapBps[vault];
    }

    /// @inheritdoc IVaultManager
    function vaultCollateralAsset(
        address vault
    ) external view override returns (bytes32) {
        return _vaultCollateralAsset[vault];
    }

    /// @inheritdoc IVaultManager
    function globalAssetUnits(
        bytes32 asset
    ) external view override returns (uint256) {
        return _globalAssetUnits[asset];
    }

    /// @inheritdoc IVaultManager
    function assetCapUSD(
        bytes32 asset
    ) external view override returns (uint256) {
        return _assetCapUSD[asset];
    }

    /// @inheritdoc IVaultManager
    function isRegisteredVault(
        address vault
    ) external view override returns (bool) {
        return _registered[vault];
    }

    /// @inheritdoc IVaultManager
    function getAllVaults() external view override returns (address[] memory) {
        return _vaultList;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Cap a vault's counted collateral contribution to its concentration share. `others` is
    ///      the global counted collateral excluding this vault. Solving `counted <= cap/BPS ·
    ///      (others + counted)` gives `counted <= cap · others / (BPS − cap)`, so the vault counts at
    ///      most `cap` bps of the total. A `0` (or `>= BPS`) cap is disabled and returns `rawMark`.
    function _cappedContribution(address vault, uint256 rawMark, uint256 others) private view returns (uint256) {
        uint256 cap = _collateralCapBps[vault];
        if (cap == 0 || cap >= BPS) return rawMark;
        uint256 maxCounted = others.mulDiv(cap, BPS - cap);
        return rawMark < maxCounted ? rawMark : maxCounted;
    }

    /// @dev Resolve the last-verified oracle price for an asset.
    function _resolvePrice(
        bytes32 asset
    ) private view returns (uint256 price) {
        uint8 oracleType = IAssetRegistry(registry.assetRegistry()).getOracleType(asset);
        address oracle = oracleType == 0 ? registry.pythOracle() : registry.inhouseOracle();
        (price,) = IOracleVerifier(oracle).getPrice(asset);
    }
}
