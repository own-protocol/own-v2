// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAaveBorrowManager} from "../interfaces/IAaveBorrowManager.sol";
import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IEToken} from "../interfaces/IEToken.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IOwnVault} from "../interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IAaveV3Pool} from "../interfaces/external/IAaveV3Pool.sol";
import {InterestRateModel} from "../libraries/InterestRateModel.sol";

import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AaveBorrowManager — User borrowing against eTokens via vault Aave credit
/// @notice One-per-vault stateful manager. Borrowers deposit eTokens as
///         collateral; the manager borrows the vault's stablecoin (USDC) from
///         Aave V3 via credit delegation and forwards it to the borrower. Each
///         (borrower, asset) carries its own position. Interest accrues on the
///         manager's per-asset cumulative index using a two-slope utilization
///         curve. Liquidation is full-close, signed-price gated, with bonus
///         capped at remaining collateral.
contract AaveBorrowManager is IAaveBorrowManager, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant AAVE_VARIABLE_RATE_MODE = 2;

    /// @dev Aave V3 uses RAY (1e27) for rate scaling.
    uint256 internal constant RAY = 1e27;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    address public immutable override vault;
    address public immutable override stablecoin;
    address public immutable override debtToken;
    address public immutable override aavePool;
    IProtocolRegistry public immutable registry;

    /// @dev Decimals of the borrow stablecoin (cached for USD conversion).
    uint8 internal immutable _stableDecimals;

    // ──────────────────────────────────────────────────────────
    //  Configuration (admin-mutable)
    // ──────────────────────────────────────────────────────────

    InterestRateModel.Params internal _rateParams;

    /// @dev Manager-wide borrow cap (in stablecoin units) used for utilization.
    ///      Zero means no cap → utilization = 0 → premium = base only.
    uint256 public borrowCap;

    /// @dev Floor for the Aave-side rate (BPS, annualized). The accrual loop
    ///      uses `max(floor, liveAaveRate)` so the protocol always charges at
    ///      least the live Aave variable borrow rate plus the premium curve.
    ///      Admin can raise the floor for additional safety; the live read
    ///      protects LPs even when the admin is silent.
    uint256 public minAaveBorrowRateBps;

    /// @inheritdoc IAaveBorrowManager
    uint256 public override liquidationThresholdBps;
    /// @inheritdoc IAaveBorrowManager
    uint256 public override liquidationBonusBps;
    /// @inheritdoc IAaveBorrowManager
    uint256 public override borrowLtvBps;

    // ──────────────────────────────────────────────────────────
    //  Per-asset state
    // ──────────────────────────────────────────────────────────

    /// @dev Cumulative interest index, PRECISION-scaled (starts at PRECISION).
    mapping(bytes32 => uint256) internal _index;
    /// @dev Sum of scaled debts across all positions for an asset.
    mapping(bytes32 => uint256) internal _totalScaledDebt;
    /// @dev Last accrual timestamp per asset.
    mapping(bytes32 => uint256) internal _lastAccrual;

    // ──────────────────────────────────────────────────────────
    //  Per-position state
    // ──────────────────────────────────────────────────────────

    /// @dev Per-(borrower, asset) position. principal stored as scaled debt
    ///      so it auto-grows with `_index`. Recover units via
    ///      `_currentDebt(asset, scaledDebt)`.
    mapping(address => mapping(bytes32 => Position)) internal _positions;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != Ownable(address(registry)).owner()) revert OnlyAdmin();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    constructor(
        address vault_,
        address stablecoin_,
        address debtToken_,
        address aavePool_,
        address registry_,
        InterestRateModel.Params memory rateParams_
    ) {
        if (
            vault_ == address(0) || stablecoin_ == address(0) || debtToken_ == address(0) || aavePool_ == address(0)
                || registry_ == address(0)
        ) revert ZeroAddress();

        vault = vault_;
        stablecoin = stablecoin_;
        debtToken = debtToken_;
        aavePool = aavePool_;
        registry = IProtocolRegistry(registry_);
        _stableDecimals = IERC20Metadata(stablecoin_).decimals();

        _rateParams = rateParams_;

        // Sensible defaults; admin can tune.
        liquidationThresholdBps = 8000; // 80%
        liquidationBonusBps = 500; // 5%
        borrowLtvBps = 7000; // 70%

        // Pre-approve Aave to pull stablecoin on repay.
        IERC20(stablecoin_).forceApprove(aavePool_, type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────
    //  Borrow
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAaveBorrowManager
    function borrow(
        bytes32 asset,
        uint256 eTokenAmount,
        uint256 stablecoinAmount,
        bytes calldata priceData
    ) external payable nonReentrant {
        if (eTokenAmount == 0 || stablecoinAmount == 0) revert ZeroAmount();
        if (_positions[msg.sender][asset].principal != 0) revert PositionAlreadyOpen(msg.sender, asset);

        address eToken = _resolveActiveEToken(asset);
        _validateEligibility(asset, eToken);

        uint256 oraclePrice = _verifyPrice(asset, priceData);

        // LTV check at borrow time.
        uint256 collateralValueUSD = eTokenAmount.mulDiv(oraclePrice, PRECISION);
        uint256 maxBorrowUSD = collateralValueUSD.mulDiv(borrowLtvBps, BPS);
        uint256 borrowValueUSD = _stableToUSD(stablecoinAmount);
        if (borrowValueUSD > maxBorrowUSD) revert InsufficientCollateral(borrowValueUSD, maxBorrowUSD);

        // Bring asset index forward before recording the position.
        _accrueAsset(asset);
        uint256 idx = _index[asset];

        // Pull eToken collateral into the manager's pooled custody.
        IERC20(eToken).safeTransferFrom(msg.sender, address(this), eTokenAmount);

        // Borrow stablecoin from Aave on the vault's behalf via credit delegation.
        IAaveV3Pool(aavePool).borrow(stablecoin, stablecoinAmount, AAVE_VARIABLE_RATE_MODE, 0, vault);

        // Forward the borrowed stablecoin to the borrower.
        IERC20(stablecoin).safeTransfer(msg.sender, stablecoinAmount);

        // Record position. principal is scaled debt: actual debt grows via index.
        uint256 scaledDebt = stablecoinAmount.mulDiv(PRECISION, idx);
        _positions[msg.sender][asset] =
            Position({eTokenCollateral: eTokenAmount, principal: scaledDebt, interestIndex: idx});
        _totalScaledDebt[asset] += scaledDebt;

        emit Borrowed(msg.sender, asset, eTokenAmount, stablecoinAmount, oraclePrice);
    }

    // ──────────────────────────────────────────────────────────
    //  Repay
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAaveBorrowManager
    function repay(bytes32 asset, uint256 amount) external nonReentrant returns (uint256 collateralReleased) {
        Position storage p = _positions[msg.sender][asset];
        if (p.principal == 0) revert NoPosition(msg.sender, asset);

        _accrueAsset(asset);
        uint256 idx = _index[asset];

        uint256 currentDebt = p.principal.mulDiv(idx, PRECISION);
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;
        if (repayAmount == 0) revert ZeroAmount();

        // Pull stablecoin from caller.
        IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), repayAmount);

        // Forward to Aave; surplus (premium that exceeds Aave's debt) sweeps to vault as LP yield.
        _repayAaveAndSweep(repayAmount);

        if (repayAmount == currentDebt) {
            // Full close — release all collateral.
            collateralReleased = p.eTokenCollateral;
            _totalScaledDebt[asset] -= p.principal;
            delete _positions[msg.sender][asset];
        } else {
            // Partial — release pro-rata; preserves LTV at constant price.
            collateralReleased = p.eTokenCollateral.mulDiv(repayAmount, currentDebt);
            // Rounding direction for scaled-debt reduction: floor so the
            // protocol keeps a sliver more debt vs releasing more collateral
            // (protocol-favorable).
            uint256 scaledRepay = repayAmount.mulDiv(PRECISION, idx);
            // Defensive: never let scaledRepay exceed stored principal.
            if (scaledRepay > p.principal) scaledRepay = p.principal;
            p.principal -= scaledRepay;
            p.eTokenCollateral -= collateralReleased;
            p.interestIndex = idx;
            _totalScaledDebt[asset] -= scaledRepay;
        }

        // Send eToken collateral back. Pass-through holders mapping must include
        // the manager so dividends earned during the borrow window follow the
        // borrower on this transfer.
        if (collateralReleased > 0) {
            address eToken = _resolveActiveEToken(asset);
            IERC20(eToken).safeTransfer(msg.sender, collateralReleased);
        }

        emit Repaid(msg.sender, asset, repayAmount, collateralReleased, _positions[msg.sender][asset].principal);
    }

    // ──────────────────────────────────────────────────────────
    //  Liquidate
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAaveBorrowManager
    function liquidate(address borrower, bytes32 asset, bytes calldata priceData) external payable nonReentrant {
        if (_positions[borrower][asset].principal == 0) revert NoPosition(borrower, asset);

        _accrueAsset(asset);
        uint256 oraclePrice = _verifyPrice(asset, priceData);
        _liquidate(borrower, asset, oraclePrice);
    }

    function _liquidate(address borrower, bytes32 asset, uint256 oraclePrice) internal {
        Position storage p = _positions[borrower][asset];
        uint256 currentDebt = p.principal.mulDiv(_index[asset], PRECISION);
        if (_healthFactorFromValues(p.eTokenCollateral, currentDebt, oraclePrice) >= PRECISION) {
            revert NotLiquidatable(_healthFactorFromValues(p.eTokenCollateral, currentDebt, oraclePrice));
        }

        // Pull full debt from liquidator, repay Aave.
        IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), currentDebt);
        _repayAaveAndSweep(currentDebt);

        // Compute seize amount in eToken units; cap at remaining collateral.
        uint256 actualSeize = _capSeize(_targetSeize(currentDebt, oraclePrice), p.eTokenCollateral);
        uint256 residual = p.eTokenCollateral - actualSeize;

        _totalScaledDebt[asset] -= p.principal;
        delete _positions[borrower][asset];

        address eToken = _resolveActiveEToken(asset);
        if (actualSeize > 0) IERC20(eToken).safeTransfer(msg.sender, actualSeize);
        if (residual > 0) IERC20(eToken).safeTransfer(borrower, residual);

        emit Liquidated(borrower, asset, msg.sender, currentDebt, actualSeize, residual);
    }

    /// @dev Target seize in eToken units: `currentDebt * (1+bonus) / oraclePrice`.
    function _targetSeize(uint256 currentDebt, uint256 oraclePrice) internal view returns (uint256) {
        uint256 withBonusUSD = _stableToUSD(currentDebt).mulDiv(BPS + liquidationBonusBps, BPS);
        return withBonusUSD.mulDiv(PRECISION, oraclePrice);
    }

    function _capSeize(uint256 target, uint256 available) internal pure returns (uint256) {
        return target > available ? available : target;
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAaveBorrowManager
    function rateParams()
        external
        view
        returns (uint64 basePremiumBps, uint64 optimalUtilBps, uint64 slope1Bps, uint64 slope2Bps)
    {
        InterestRateModel.Params memory p = _rateParams;
        return (p.basePremiumBps, p.optimalUtilBps, p.slope1Bps, p.slope2Bps);
    }

    /// @inheritdoc IAaveBorrowManager
    function positionOf(address borrower, bytes32 asset) external view returns (Position memory) {
        return _positions[borrower][asset];
    }

    /// @inheritdoc IAaveBorrowManager
    function debtOf(address borrower, bytes32 asset) external view returns (uint256) {
        Position memory p = _positions[borrower][asset];
        if (p.principal == 0) return 0;
        uint256 idx = _projectedIndex(asset);
        return p.principal.mulDiv(idx, PRECISION);
    }

    /// @inheritdoc IAaveBorrowManager
    function healthFactor(address borrower, bytes32 asset, uint256 oraclePrice) external view returns (uint256) {
        Position memory p = _positions[borrower][asset];
        if (p.principal == 0) return type(uint256).max;
        uint256 idx = _projectedIndex(asset);
        uint256 currentDebt = p.principal.mulDiv(idx, PRECISION);
        return _healthFactorFromValues(p.eTokenCollateral, currentDebt, oraclePrice);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAaveBorrowManager
    function setRateParams(
        InterestRateModel.Params calldata params
    ) external onlyAdmin {
        _rateParams = params;
        emit RateParamsUpdated(params);
    }

    /// @inheritdoc IAaveBorrowManager
    function setLiquidationConfig(uint256 liquidationThresholdBps_, uint256 liquidationBonusBps_) external onlyAdmin {
        if (
            liquidationThresholdBps_ == 0 || liquidationThresholdBps_ > BPS || liquidationThresholdBps_ <= borrowLtvBps
                || liquidationBonusBps_ > BPS
        ) revert InvalidLiquidationConfig();
        liquidationThresholdBps = liquidationThresholdBps_;
        liquidationBonusBps = liquidationBonusBps_;
        emit LiquidationConfigUpdated(liquidationThresholdBps_, liquidationBonusBps_);
    }

    /// @notice Set the borrow LTV (BPS). Must be lower than `liquidationThresholdBps`.
    function setBorrowLtvBps(
        uint256 ltvBps
    ) external onlyAdmin {
        if (ltvBps == 0 || ltvBps >= liquidationThresholdBps) revert InvalidLiquidationConfig();
        borrowLtvBps = ltvBps;
    }

    /// @notice Set the minimum Aave-side rate floor (BPS, annualized). The
    ///         actual rate used at accrual is `max(floor, liveAaveRate)`.
    function setMinAaveBorrowRateBps(
        uint256 rateBps
    ) external onlyAdmin {
        minAaveBorrowRateBps = rateBps;
    }

    /// @notice Read Aave's current variable borrow rate for the manager's
    ///         stablecoin, converted from RAY to BPS. Safe to call off-chain
    ///         to inspect the live rate.
    function liveAaveRateBps() external view returns (uint256) {
        return _liveAaveRateBps();
    }

    /// @notice Admin-set per-manager borrow cap (stablecoin units). Drives
    ///         utilization in the rate curve. Zero means uncapped (util = 0).
    function setBorrowCap(
        uint256 cap
    ) external onlyAdmin {
        borrowCap = cap;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — accrual
    // ──────────────────────────────────────────────────────────

    function _accrueAsset(
        bytes32 asset
    ) internal {
        uint256 last = _lastAccrual[asset];
        if (last == 0) {
            _index[asset] = PRECISION;
            _lastAccrual[asset] = block.timestamp;
            return;
        }
        uint256 dt = block.timestamp - last;
        if (dt == 0) return;

        if (_totalScaledDebt[asset] == 0) {
            _lastAccrual[asset] = block.timestamp;
            return;
        }

        uint256 rateBps = _currentRateBps(asset);
        uint256 idx = _index[asset];
        // index += index * rate * dt / (BPS * SECONDS_PER_YEAR)
        uint256 growth = idx.mulDiv(rateBps * dt, BPS * SECONDS_PER_YEAR);
        _index[asset] = idx + growth;
        _lastAccrual[asset] = block.timestamp;
    }

    function _projectedIndex(
        bytes32 asset
    ) internal view returns (uint256) {
        uint256 last = _lastAccrual[asset];
        uint256 idx = _index[asset];
        if (idx == 0) return PRECISION;
        if (last == 0 || _totalScaledDebt[asset] == 0) return idx;
        uint256 dt = block.timestamp - last;
        if (dt == 0) return idx;
        uint256 rateBps = _currentRateBps(asset);
        return idx + idx.mulDiv(rateBps * dt, BPS * SECONDS_PER_YEAR);
    }

    function _currentRateBps(
        bytes32 asset
    ) internal view returns (uint256) {
        uint256 utilBps = _utilizationBps(asset);
        return _aaveRateWithFloor() + InterestRateModel.premium(utilBps, _rateParams);
    }

    /// @dev Live Aave rate, floored at `minAaveBorrowRateBps`.
    function _aaveRateWithFloor() internal view returns (uint256) {
        uint256 live = _liveAaveRateBps();
        uint256 floor = minAaveBorrowRateBps;
        return live > floor ? live : floor;
    }

    /// @dev Read Aave's variable borrow rate for our stablecoin and convert
    ///      RAY (1e27, annualized) → BPS (10_000 = 100% APR).
    function _liveAaveRateBps() internal view returns (uint256) {
        IAaveV3Pool.ReserveDataLegacy memory data = IAaveV3Pool(aavePool).getReserveData(stablecoin);
        return uint256(data.currentVariableBorrowRate).mulDiv(BPS, RAY);
    }

    function _utilizationBps(
        bytes32 asset
    ) internal view returns (uint256) {
        uint256 cap = borrowCap;
        if (cap == 0) return 0;
        uint256 totalDebt = _totalScaledDebt[asset].mulDiv(_index[asset], PRECISION);
        return totalDebt.mulDiv(BPS, cap);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — eligibility / oracle
    // ──────────────────────────────────────────────────────────

    function _validateEligibility(bytes32 asset, address eToken) internal view {
        if (!IOwnVault(vault).isAssetSupported(asset)) revert AssetNotSupportedByVault(asset);
        if (!IAssetRegistry(registry.assetRegistry()).isActiveAsset(asset)) revert AssetNotActive(asset);
        if (!IEToken(eToken).isPassThroughHolder(address(this))) revert PassThroughNotEnabled(eToken);
        if (IOwnVault(vault).isEffectivelyHalted(asset) || IOwnVault(vault).isEffectivelyPaused(asset)) {
            revert VaultEffectivelyHalted();
        }
    }

    function _resolveActiveEToken(
        bytes32 asset
    ) internal view returns (address) {
        return IAssetRegistry(registry.assetRegistry()).getActiveToken(asset);
    }

    function _verifyPrice(bytes32 asset, bytes calldata priceData) internal returns (uint256 price) {
        uint8 oracleType = IAssetRegistry(registry.assetRegistry()).getOracleType(asset);
        address oracleAddr = oracleType == 0 ? registry.pythOracle() : registry.inhouseOracle();
        (price,) = IOracleVerifier(oracleAddr).verifyPrice{value: msg.value}(asset, priceData);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — Aave repay
    // ──────────────────────────────────────────────────────────

    /// @dev Repay up to `amount` of the vault's Aave debt. Any surplus stays
    ///      on this contract; we forward it to the vault as LP-side fee yield.
    function _repayAaveAndSweep(
        uint256 amount
    ) internal {
        uint256 actualRepaid = IAaveV3Pool(aavePool).repay(stablecoin, amount, AAVE_VARIABLE_RATE_MODE, vault);
        uint256 surplus = amount > actualRepaid ? amount - actualRepaid : 0;
        if (surplus > 0) {
            IERC20(stablecoin).safeTransfer(vault, surplus);
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — math helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Convert stablecoin native units to USD (18 decimals).
    function _stableToUSD(
        uint256 amount
    ) internal view returns (uint256) {
        if (_stableDecimals == 18) return amount;
        if (_stableDecimals < 18) return amount * 10 ** (18 - _stableDecimals);
        return amount / 10 ** (_stableDecimals - 18);
    }

    function _healthFactorFromValues(
        uint256 collateral,
        uint256 currentDebt,
        uint256 oraclePrice
    ) internal view returns (uint256) {
        if (currentDebt == 0) return type(uint256).max;
        // collateralUSD = collateral * price / 1e18
        uint256 collateralUSD = collateral.mulDiv(oraclePrice, PRECISION);
        // adjustedCollateralUSD = collateralUSD * threshold / BPS
        uint256 adjusted = collateralUSD.mulDiv(liquidationThresholdBps, BPS);
        uint256 debtUSD = _stableToUSD(currentDebt);
        // hf = adjusted / debtUSD, scaled to PRECISION (1e18 = 1.0).
        return adjusted.mulDiv(PRECISION, debtUSD);
    }
}
