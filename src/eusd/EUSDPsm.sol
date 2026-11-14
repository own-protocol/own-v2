// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IEUSD} from "../interfaces/IEUSD.sol";
import {IEUSDPsm} from "../interfaces/IEUSDPsm.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title EUSDPsm — eUSD peg stability module
/// @notice See {IEUSDPsm}. Holds the EUSD MINTER_ROLE.
/// @dev Runs behind an ERC-1967 proxy (UUPS, ADMIN-gated upgrades); storage is append-only across
///      upgrades. Per asset, `balance × scale ≥ debt` holds after every call: a mint adds
///      `assetIn × scale ≥ eusdOut` to the reserve and the debt grows by `eusdOut`; a redeem takes
///      `assetOut × scale ≤ eusdIn` out and the debt falls by `eusdIn`. Fees and rounding stay in
///      the reserve as surplus.
contract EUSDPsm is IEUSDPsm, Initializable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEUSDPsm
    uint16 public constant override MAX_FEE_BPS = 100;

    /// @dev ProtocolRegistry role for listing, ceilings, fees, surplus and upgrades.
    bytes32 private constant ADMIN = keccak256("ADMIN");

    /// @dev ProtocolRegistry role for pausing mints.
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice ProtocolRegistry used to resolve the ADMIN and OPERATOR roles and the treasury.
    IProtocolRegistry public registry;

    /// @dev The eUSD token.
    IEUSD private _eusd;

    /// @inheritdoc IEUSDPsm
    uint256 public override totalDebt;

    /// @dev Per-asset settings and book.
    mapping(address => AssetConfig) private _configs;

    /// @dev Listed assets, in listing order.
    address[] private _assets;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    /// @dev Reverts unless the caller holds ADMIN in the registry.
    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    /// @dev Reverts unless the caller holds OPERATOR in the registry.
    modifier onlyOperator() {
        if (!registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperator();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Construction / initialization (UUPS)
    // ──────────────────────────────────────────────────────────

    /// @dev Locks the implementation's initializers; it is only used behind a proxy.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy (called once, in the proxy's constructor).
    /// @param registry_ ProtocolRegistry contract address.
    /// @param eusd_     EUSD token address (this PSM must hold its MINTER_ROLE).
    function initialize(address registry_, address eusd_) external initializer {
        if (registry_ == address(0) || eusd_ == address(0)) revert ZeroAddress();
        registry = IProtocolRegistry(registry_);
        _eusd = IEUSD(eusd_);
    }

    /// @dev UUPS upgrade gate: ADMIN only.
    function _authorizeUpgrade(
        address
    ) internal view override onlyAdmin {}

    // ──────────────────────────────────────────────────────────
    //  External — swaps
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEUSDPsm
    function mint(
        address asset,
        uint256 assetIn,
        uint256 minEusdOut
    ) external override nonReentrant returns (uint256 eusdOut) {
        AssetConfig storage cfg = _requireListed(asset);
        if (cfg.mintPaused) revert MintingPaused(asset);
        uint256 fee;
        (eusdOut, fee) = _previewMint(cfg, assetIn);
        if (eusdOut == 0) revert ZeroAmount();
        if (eusdOut < minEusdOut) revert InsufficientOutput(eusdOut, minEusdOut);
        uint256 debt = cfg.debt + eusdOut;
        if (debt > cfg.debtCeiling) revert DebtCeilingExceeded(debt, cfg.debtCeiling);

        cfg.debt = debt;
        totalDebt += eusdOut;

        uint256 before = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assetIn);
        uint256 received = IERC20(asset).balanceOf(address(this)) - before;
        if (received != assetIn) revert TransferAmountMismatch(assetIn, received);
        _eusd.mint(msg.sender, eusdOut);
        emit Minted(asset, msg.sender, assetIn, eusdOut, fee);
    }

    /// @inheritdoc IEUSDPsm
    function redeem(
        address asset,
        uint256 eusdIn,
        uint256 minAssetOut
    ) external override nonReentrant returns (uint256 assetOut) {
        AssetConfig storage cfg = _requireListed(asset);
        uint256 debt = cfg.debt;
        if (eusdIn > debt) revert InsufficientDebt(eusdIn, debt);
        uint256 fee;
        (assetOut, fee) = _previewRedeem(cfg, eusdIn);
        if (assetOut == 0) revert ZeroAmount();
        if (assetOut < minAssetOut) revert InsufficientOutput(assetOut, minAssetOut);

        cfg.debt = debt - eusdIn;
        totalDebt -= eusdIn;

        _eusd.burn(msg.sender, eusdIn);
        IERC20(asset).safeTransfer(msg.sender, assetOut);
        emit Redeemed(asset, msg.sender, eusdIn, assetOut, fee);
    }

    // ──────────────────────────────────────────────────────────
    //  External — admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEUSDPsm
    function addAsset(
        address asset,
        uint256 debtCeiling,
        uint16 mintFeeBps,
        uint16 redeemFeeBps
    ) external override onlyAdmin {
        if (asset == address(0)) revert ZeroAddress();
        if (asset == address(_eusd)) revert UnsupportedAsset(asset);
        AssetConfig storage cfg = _configs[asset];
        if (cfg.listed) revert AssetAlreadyListed(asset);
        _checkFee(mintFeeBps);
        _checkFee(redeemFeeBps);
        uint8 decimals = IERC20Metadata(asset).decimals();
        if (decimals > 18) revert UnsupportedDecimals(decimals);

        cfg.listed = true;
        cfg.decimals = decimals;
        cfg.mintFeeBps = mintFeeBps;
        cfg.redeemFeeBps = redeemFeeBps;
        cfg.debtCeiling = debtCeiling;
        _assets.push(asset);
        emit AssetAdded(asset, decimals, debtCeiling, mintFeeBps, redeemFeeBps);
    }

    /// @inheritdoc IEUSDPsm
    function setDebtCeiling(address asset, uint256 debtCeiling) external override onlyAdmin {
        _requireListed(asset).debtCeiling = debtCeiling;
        emit DebtCeilingSet(asset, debtCeiling);
    }

    /// @inheritdoc IEUSDPsm
    function setFees(address asset, uint16 mintFeeBps, uint16 redeemFeeBps) external override onlyAdmin {
        AssetConfig storage cfg = _requireListed(asset);
        _checkFee(mintFeeBps);
        _checkFee(redeemFeeBps);
        cfg.mintFeeBps = mintFeeBps;
        cfg.redeemFeeBps = redeemFeeBps;
        emit FeesSet(asset, mintFeeBps, redeemFeeBps);
    }

    /// @inheritdoc IEUSDPsm
    function setMintPaused(address asset, bool paused) external override onlyOperator {
        _requireListed(asset).mintPaused = paused;
        emit MintPausedSet(asset, paused);
    }

    /// @inheritdoc IEUSDPsm
    function withdrawSurplus(address asset, uint256 amount) external override onlyAdmin nonReentrant {
        AssetConfig storage cfg = _requireListed(asset);
        if (amount == 0) revert ZeroAmount();
        uint256 available = _surplus(cfg, asset);
        if (amount > available) revert InsufficientSurplus(amount, available);
        address to = registry.treasury();
        if (to == address(0)) revert ZeroAddress();
        IERC20(asset).safeTransfer(to, amount);
        emit SurplusWithdrawn(asset, to, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEUSDPsm
    function eusd() external view override returns (address) {
        return address(_eusd);
    }

    /// @inheritdoc IEUSDPsm
    function assetConfig(
        address asset
    ) external view override returns (AssetConfig memory) {
        return _configs[asset];
    }

    /// @inheritdoc IEUSDPsm
    function assetCount() external view override returns (uint256) {
        return _assets.length;
    }

    /// @inheritdoc IEUSDPsm
    function assetAt(
        uint256 index
    ) external view override returns (address) {
        return _assets[index];
    }

    /// @inheritdoc IEUSDPsm
    function surplus(
        address asset
    ) external view override returns (uint256) {
        return _surplus(_requireListedView(asset), asset);
    }

    /// @inheritdoc IEUSDPsm
    function previewMint(address asset, uint256 assetIn) external view override returns (uint256, uint256) {
        return _previewMint(_requireListedView(asset), assetIn);
    }

    /// @inheritdoc IEUSDPsm
    function previewRedeem(address asset, uint256 eusdIn) external view override returns (uint256, uint256) {
        return _previewRedeem(_requireListedView(asset), eusdIn);
    }

    // ──────────────────────────────────────────────────────────
    //  Private
    // ──────────────────────────────────────────────────────────

    /// @dev The asset's config, reverting unless it is listed.
    /// @param asset The asset.
    /// @return cfg Its config.
    function _requireListed(
        address asset
    ) private view returns (AssetConfig storage cfg) {
        cfg = _configs[asset];
        if (!cfg.listed) revert AssetNotListed(asset);
    }

    /// @dev Same as {_requireListed}, for views.
    /// @param asset The asset.
    /// @return Its config.
    function _requireListedView(
        address asset
    ) private view returns (AssetConfig storage) {
        return _requireListed(asset);
    }

    /// @dev Revert if a fee is above the cap.
    /// @param feeBps The fee.
    function _checkFee(
        uint16 feeBps
    ) private pure {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps);
    }

    /// @dev Units of eUSD per unit of the asset.
    /// @param cfg The asset's config.
    /// @return The scale.
    function _scale(
        AssetConfig storage cfg
    ) private view returns (uint256) {
        return 10 ** (18 - cfg.decimals);
    }

    /// @dev eUSD out and fee for paying `assetIn`.
    /// @param cfg     The asset's config.
    /// @param assetIn Asset units paid.
    /// @return eusdOut eUSD out (18 decimals).
    /// @return fee     eUSD-equivalent kept (18 decimals).
    function _previewMint(
        AssetConfig storage cfg,
        uint256 assetIn
    ) private view returns (uint256 eusdOut, uint256 fee) {
        uint256 gross = assetIn * _scale(cfg);
        // Rounded up: the fee is protocol-favourable.
        fee = Math.mulDiv(gross, cfg.mintFeeBps, BPS, Math.Rounding.Ceil);
        eusdOut = gross - fee;
    }

    /// @dev Asset out and fee for burning `eusdIn`.
    /// @param cfg    The asset's config.
    /// @param eusdIn eUSD burned (18 decimals).
    /// @return assetOut Asset units out.
    /// @return fee      eUSD-equivalent kept, including rounding to asset units (18 decimals).
    function _previewRedeem(
        AssetConfig storage cfg,
        uint256 eusdIn
    ) private view returns (uint256 assetOut, uint256 fee) {
        uint256 scale = _scale(cfg);
        // Fee rounded up and asset out rounded down: both protocol-favourable.
        uint256 net = eusdIn - Math.mulDiv(eusdIn, cfg.redeemFeeBps, BPS, Math.Rounding.Ceil);
        assetOut = net / scale;
        fee = eusdIn - assetOut * scale;
    }

    /// @dev Reserve above what covers the asset's debt.
    /// @param cfg   The asset's config.
    /// @param asset The asset.
    /// @return Surplus (asset units).
    function _surplus(AssetConfig storage cfg, address asset) private view returns (uint256) {
        // Debt rounded up to asset units: the covered part is protocol-favourable.
        uint256 covered = Math.ceilDiv(cfg.debt, _scale(cfg));
        uint256 balance = IERC20(asset).balanceOf(address(this));
        return balance > covered ? balance - covered : 0;
    }
}
