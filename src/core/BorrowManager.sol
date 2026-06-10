// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";

import {IBorrowManager} from "../interfaces/IBorrowManager.sol";
import {IEToken} from "../interfaces/IEToken.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IOwnMarket} from "../interfaces/IOwnMarket.sol";
import {IOwnVault} from "../interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {IAaveV3Pool} from "../interfaces/external/IAaveV3Pool.sol";
import {InterestRateModel} from "../libraries/InterestRateModel.sol";
import {LendingMath} from "../libraries/LendingMath.sol";

import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BorrowManager — eToken-collateralised borrowing (Aave-funded)
/// @notice One-per-vault stateful borrow manager implementing the venue-neutral {IBorrowManager}.
///         Borrowers deposit eTokens as collateral; the manager borrows the protocol's stablecoin
///         (USDC) and forwards it to the borrower. Each (borrower, asset) carries its own position.
///         Interest accrues on a single global cumulative index using a two-slope utilization curve
///         (the borrow rate is vault-wide, so one index prices every position). Liquidation is
///         signed-price gated and partial: the liquidator names a repay amount, capped by an
///         HF-gated close factor, and the bonus-based seize must fit the position's remaining
///         collateral.
///
///         **Funding source (Aave V3):** this implementation sources the loaned stablecoin from
///         Aave V3 via the vault's credit delegation — `pool.borrow(onBehalf=vault)` /
///         `pool.repay(onBehalf=vault)` — and reads the live Aave variable borrow rate as its base
///         rate. A future Morpho or in-house manager can implement {IBorrowManager} with a different
///         funding source while reusing the same vault, market, and risk wiring.
///
///         The manager is self-contained: it tracks its own outstanding debt, enforces a vault-wide
///         hard cap (`targetLtvBps` × vault collateral), and derives utilization for the rate curve.
contract BorrowManager is IBorrowManager, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    uint256 internal constant AAVE_VARIABLE_RATE_MODE = 2;

    /// @dev Aave V3 uses RAY (1e27) for rate scaling.
    uint256 internal constant RAY = 1e27;

    /// @dev Health-factor cutoff for the liquidation close factor (PRECISION = 1.0).
    ///      A liquidatable position with `hf` above this is only *partially*
    ///      closable (capped at {liquidationCloseFactorBps}); at or below it the
    ///      position can be fully closed in one call. Mirrors Aave V3's
    ///      `CLOSE_FACTOR_HF_THRESHOLD` (0.95).
    uint256 internal constant CLOSE_FACTOR_HF_THRESHOLD = 0.95e18;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    address public immutable override vault;
    address public immutable override stablecoin;
    address public immutable debtToken;
    address public immutable aavePool;
    IProtocolRegistry public immutable registry;

    /// @dev Decimals of the borrow stablecoin (cached for USD conversion).
    uint8 internal immutable _stableDecimals;

    // ──────────────────────────────────────────────────────────
    //  Configuration (admin-mutable)
    // ──────────────────────────────────────────────────────────

    InterestRateModel.Params internal _rateParams;

    /// @dev Floor for the Aave-side rate (BPS, annualized). The accrual loop
    ///      uses `max(floor, baseRateBps())` so the protocol always charges
    ///      at least the live Aave variable borrow rate plus the premium curve.
    ///      Admin can raise the floor for additional safety; the live read
    ///      protects LPs even when the admin is silent.
    uint256 public minAaveBorrowRateBps;

    /// @inheritdoc IBorrowManager
    uint256 public override liquidationThresholdBps;
    /// @inheritdoc IBorrowManager
    uint256 public override liquidationBonusBps;
    /// @inheritdoc IBorrowManager
    uint256 public override borrowLtvBps;

    /// @notice Max fraction of a position's debt (BPS) one liquidation may repay
    ///         while the position's health factor is above
    ///         {CLOSE_FACTOR_HF_THRESHOLD}. Below that threshold the cap is lifted
    ///         to 100% so deeply underwater positions can be wound down in one go.
    uint256 public liquidationCloseFactorBps;

    /// @inheritdoc IBorrowManager
    /// @dev Vault-wide target Aave LTV (BPS) that defines the protocol debt
    ///      cap: `maxDebtUSD = vaultManager.collateralMark(vault) × targetLtvBps / BPS`.
    ///      Distinct from `borrowLtvBps`, which caps an individual position.
    uint256 public override targetLtvBps;

    // ──────────────────────────────────────────────────────────
    //  Global debt state
    // ──────────────────────────────────────────────────────────

    /// @dev Cumulative interest index, PRECISION-scaled (starts at PRECISION).
    ///      Single global index: the borrow rate is vault-wide (driven by
    ///      utilization, not the asset), so one index prices every position.
    uint256 internal _index;
    /// @dev Sum of scaled debts across all open positions, every asset.
    uint256 internal _totalScaledDebt;
    /// @dev Last accrual timestamp for the global index.
    uint256 internal _lastAccrual;

    // ──────────────────────────────────────────────────────────
    //  Per-position state
    // ──────────────────────────────────────────────────────────

    /// @dev Per-(borrower, asset) position. principal stored as scaled debt
    ///      so it auto-grows with `_index`. Recover units via
    ///      `LendingMath.scaledToActual(principal, _index)`.
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
        uint256 targetLtvBps_,
        InterestRateModel.Params memory rateParams_
    ) {
        if (
            vault_ == address(0) || stablecoin_ == address(0) || debtToken_ == address(0) || aavePool_ == address(0)
                || registry_ == address(0)
        ) revert ZeroAddress();
        if (targetLtvBps_ == 0 || targetLtvBps_ >= BPS) revert InvalidLtv();

        vault = vault_;
        stablecoin = stablecoin_;
        debtToken = debtToken_;
        aavePool = aavePool_;
        registry = IProtocolRegistry(registry_);
        targetLtvBps = targetLtvBps_;
        _stableDecimals = IERC20Metadata(stablecoin_).decimals();

        _rateParams = rateParams_;

        // Sensible defaults; admin can tune.
        liquidationThresholdBps = 8000; // 80%
        liquidationBonusBps = 500; // 5%
        borrowLtvBps = 7000; // 70%
        liquidationCloseFactorBps = 5000; // 50%

        // Seed the global interest index at 1.0 and stamp the clock.
        _index = PRECISION;
        _lastAccrual = block.timestamp;

        // Pre-approve Aave to pull stablecoin on repay.
        IERC20(stablecoin_).forceApprove(aavePool_, type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────
    //  Borrow
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IBorrowManager
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
        uint256 collateralValueUSD = LendingMath.collateralUSD(eTokenAmount, oraclePrice);
        uint256 maxBorrowUSD = collateralValueUSD.mulDiv(borrowLtvBps, BPS);
        uint256 borrowValueUSD = LendingMath.stableToUSD(stablecoinAmount, _stableDecimals);
        if (borrowValueUSD > maxBorrowUSD) revert InsufficientCollateral(borrowValueUSD, maxBorrowUSD);

        // Protocol-level hard cap: total debt must stay within the vault's
        // collateral-backed target LTV. Scoped so the locals free before the
        // rest of the borrow flow (avoids stack-too-deep without via-ir).
        {
            uint256 cap = maxDebtUSD();
            uint256 projected = totalDebtUSD() + borrowValueUSD;
            if (projected > cap) revert BorrowExceedsCap(projected, cap);
        }

        // Bring the global index forward before recording the position.
        _accrue();
        uint256 idx = _index;

        // Pull eToken collateral into the manager's pooled custody.
        IERC20(eToken).safeTransferFrom(msg.sender, address(this), eTokenAmount);

        // Borrow stablecoin from Aave on the vault's behalf via credit delegation.
        IAaveV3Pool(aavePool).borrow(stablecoin, stablecoinAmount, AAVE_VARIABLE_RATE_MODE, 0, vault);

        // Forward the borrowed stablecoin to the borrower.
        IERC20(stablecoin).safeTransfer(msg.sender, stablecoinAmount);

        // Record position. principal is scaled debt: actual debt grows via index.
        uint256 scaledDebt = LendingMath.actualToScaled(stablecoinAmount, idx);
        _positions[msg.sender][asset] = Position({
            eTokenCollateral: eTokenAmount,
            principal: scaledDebt,
            interestIndex: idx,
            collateralToken: eToken
        });
        _totalScaledDebt += scaledDebt;

        emit Borrowed(msg.sender, asset, eTokenAmount, stablecoinAmount, oraclePrice);
    }

    // ──────────────────────────────────────────────────────────
    //  Repay
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IBorrowManager
    function repay(bytes32 asset, uint256 amount) external nonReentrant returns (uint256 collateralReleased) {
        Position storage p = _positions[msg.sender][asset];
        if (p.principal == 0) revert NoPosition(msg.sender, asset);

        _accrue();
        uint256 idx = _index;

        uint256 currentDebt = LendingMath.scaledToActual(p.principal, idx);
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;
        if (repayAmount == 0) revert ZeroAmount();

        address collateralToken = p.collateralToken;

        // Pull stablecoin from caller.
        IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), repayAmount);

        // Forward to Aave; surplus (premium that exceeds Aave's debt) sweeps to vault as LP yield.
        _repayAaveAndSweep(repayAmount);

        if (repayAmount == currentDebt) {
            // Full close — release all collateral.
            collateralReleased = p.eTokenCollateral;
            _totalScaledDebt -= p.principal;
            delete _positions[msg.sender][asset];
        } else {
            // Partial — release pro-rata; preserves LTV at constant price.
            collateralReleased = p.eTokenCollateral.mulDiv(repayAmount, currentDebt);
            // Rounding direction for scaled-debt reduction: floor so the
            // protocol keeps a sliver more debt vs releasing more collateral
            // (protocol-favorable).
            uint256 scaledRepay = LendingMath.actualToScaled(repayAmount, idx);
            // Defensive: never let scaledRepay exceed stored principal.
            if (scaledRepay > p.principal) scaledRepay = p.principal;
            p.principal -= scaledRepay;
            p.eTokenCollateral -= collateralReleased;
            p.interestIndex = idx;
            _totalScaledDebt -= scaledRepay;
        }

        // Return the exact token posted (may be a legacy token after a migration; borrower converts).
        if (collateralReleased > 0) {
            IERC20(collateralToken).safeTransfer(msg.sender, collateralReleased);
        }

        emit Repaid(msg.sender, asset, repayAmount, collateralReleased, _positions[msg.sender][asset].principal);
    }

    // ──────────────────────────────────────────────────────────
    //  Liquidate
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IBorrowManager
    function liquidate(
        address borrower,
        bytes32 asset,
        uint256 repayAmount,
        bytes calldata priceData
    ) external payable nonReentrant {
        if (_positions[borrower][asset].principal == 0) revert NoPosition(borrower, asset);
        if (repayAmount == 0) revert ZeroAmount();

        _accrue();
        uint256 oraclePrice = _verifyPrice(asset, priceData);
        _liquidate(borrower, asset, repayAmount, oraclePrice);
    }

    /// @dev Partial-or-full liquidation. The liquidator names `repayAmount`; it is
    ///      clamped to the close-factor cap (50% of debt while `hf` is above
    ///      {CLOSE_FACTOR_HF_THRESHOLD}, 100% at or below it). Collateral seized is
    ///      bonus-based and must fit within the position's remaining collateral —
    ///      the liquidator is expected to size `repayAmount` so the seize is
    ///      coverable, and an over-seize reverts rather than letting them overpay.
    ///      A full repay closes the position (residual collateral returned to the
    ///      borrower); a partial repay reduces principal + collateral and leaves
    ///      the position open. When a partial repay consumes all collateral, the
    ///      leftover debt becomes a zero-collateral residual for {absorbBadDebt}.
    function _liquidate(address borrower, bytes32 asset, uint256 repayAmount, uint256 oraclePrice) internal {
        Position storage p = _positions[borrower][asset];
        // Value the posted collateral at its effective price (legacy collateral scales by split ratio).
        uint256 price = _effectivePrice(p.collateralToken, asset, oraclePrice);
        uint256 currentDebt = LendingMath.scaledToActual(p.principal, _index);
        uint256 hf =
            LendingMath.healthFactor(p.eTokenCollateral, currentDebt, price, liquidationThresholdBps, _stableDecimals);
        if (hf >= PRECISION) revert NotLiquidatable(hf);

        // Close factor: cap a single liquidation while the position is only
        // marginally unhealthy; lift the cap once it is deeply underwater.
        uint256 maxRepay =
            hf > CLOSE_FACTOR_HF_THRESHOLD ? currentDebt.mulDiv(liquidationCloseFactorBps, BPS) : currentDebt;
        if (repayAmount > maxRepay) repayAmount = maxRepay;

        // Bonus-based seize; must be coverable by remaining collateral.
        uint256 seize = LendingMath.seizeAmount(repayAmount, price, liquidationBonusBps, _stableDecimals);
        if (seize > p.eTokenCollateral) revert SeizeExceedsCollateral(seize, p.eTokenCollateral);

        // Pull the repay from the liquidator, forward to Aave.
        IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), repayAmount);
        _repayAaveAndSweep(repayAmount);

        address eToken = p.collateralToken;
        uint256 returnedToBorrower;
        if (repayAmount == currentDebt) {
            // Full close — release any collateral left after the seize.
            returnedToBorrower = p.eTokenCollateral - seize;
            _totalScaledDebt -= p.principal;
            delete _positions[borrower][asset];
            if (returnedToBorrower > 0) IERC20(eToken).safeTransfer(borrower, returnedToBorrower);
        } else {
            // Partial — shrink principal + collateral, leave the position open.
            uint256 scaledRepay = LendingMath.actualToScaled(repayAmount, _index);
            if (scaledRepay > p.principal) scaledRepay = p.principal;
            p.principal -= scaledRepay;
            p.eTokenCollateral -= seize;
            p.interestIndex = _index;
            _totalScaledDebt -= scaledRepay;
        }

        if (seize > 0) IERC20(eToken).safeTransfer(msg.sender, seize);

        emit Liquidated(borrower, asset, msg.sender, repayAmount, seize, returnedToBorrower);
    }

    // ──────────────────────────────────────────────────────────
    //  Bad debt
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IBorrowManager
    /// @dev Bad debt only arises once a position's collateral is fully consumed
    ///      by liquidations, leaving uncollateralized book debt that still backs
    ///      a live Aave loan on the vault. The admin (acting for the treasury)
    ///      fronts the full residual stablecoin to repay that Aave loan and clear
    ///      the book debt; `absorbAmount` decides how the realized loss splits:
    ///      the treasury eats `absorbAmount`, and the remainder is released as
    ///      vault collateral (aToken) to the protocol treasury — socializing it to
    ///      LPs via the now-smaller collateral base. The aToken slice is unlocked
    ///      because the matching Aave debt is repaid first. The collateral always
    ///      goes to the registry treasury, never to the caller.
    function absorbBadDebt(
        address borrower,
        bytes32 asset,
        uint256 absorbAmount,
        bytes calldata collateralPriceData
    ) external payable nonReentrant onlyAdmin {
        Position storage p = _positions[borrower][asset];
        if (p.principal == 0) revert NoPosition(borrower, asset);
        if (p.eTokenCollateral != 0) revert PositionStillCollateralized(p.eTokenCollateral);

        _accrue();
        uint256 residual = LendingMath.scaledToActual(p.principal, _index);
        if (absorbAmount > residual) absorbAmount = residual;

        // Caller fronts the full residual; repay the vault's Aave loan and clear
        // the book debt before touching collateral.
        IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), residual);
        _repayAaveAndSweep(residual);
        _totalScaledDebt -= p.principal;
        delete _positions[borrower][asset];

        // LP-socialized slice: reimburse the caller in vault collateral priced
        // off the vault's collateral oracle (aToken ≈ underlying 1:1).
        uint256 collateralReleased;
        uint256 lpLoss = residual - absorbAmount;
        if (lpLoss > 0) {
            bytes32 collatAsset = IVaultManager(registry.vaultManager()).vaultCollateralAsset(vault);
            uint256 collateralPrice = _verifyPrice(collatAsset, collateralPriceData);
            uint256 lpLossUSD = LendingMath.stableToUSD(lpLoss, _stableDecimals);
            collateralReleased = lpLossUSD.mulDiv(PRECISION, collateralPrice);
            if (collateralReleased > 0) {
                // Collateral is released to the protocol treasury (fixed in the vault), not to the
                // caller — the caller fronts the stablecoin; the treasury receives the LP-socialized
                // collateral slice.
                IOwnVault(vault).releaseCollateralForBadDebt(collateralReleased);
            }
        }

        emit BadDebtAbsorbed(borrower, asset, msg.sender, residual, absorbAmount, collateralReleased);
    }

    // ──────────────────────────────────────────────────────────
    //  Halt settlement
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IBorrowManager
    /// @dev Unwinds a position during a permanent asset halt. The eToken collateral needed to
    ///      cover the position's debt at the fixed halt price is seized and redeemed for
    ///      stablecoins through the market's halt redeem path (paid from the halt redeem address),
    ///      the proceeds repay the vault's Aave debt, and any excess collateral is returned to the
    ///      borrower. Assumes the global payment token equals this manager's borrow stablecoin
    ///      (both USDC in the MVP) so redeem proceeds can repay the Aave loan directly. If the
    ///      collateral cannot fully cover the debt, the shortfall is left as a zero-collateral
    ///      residual for {absorbBadDebt}.
    function settleHaltedPosition(address borrower, bytes32 asset) external nonReentrant {
        Position storage p = _positions[borrower][asset];
        if (p.principal == 0) revert NoPosition(borrower, asset);

        IVaultManager vmgr = IVaultManager(registry.vaultManager());
        if (!vmgr.isAssetHalted(asset)) revert AssetNotHalted(asset);
        uint256 haltPrice = vmgr.assetHaltPrice(asset);

        _accrue();
        uint256 idx = _index;
        uint256 currentDebt = LendingMath.scaledToActual(p.principal, idx);

        // The halt redemption settles the active token only; convert legacy collateral first.
        address eToken = _resolveActiveEToken(asset);
        if (p.collateralToken != eToken && p.eTokenCollateral > 0) {
            uint256 converted =
                IOwnMarket(registry.market()).convertLegacy(asset, p.collateralToken, p.eTokenCollateral);
            p.eTokenCollateral = converted;
            p.collateralToken = eToken;
        }

        // eTokens needed to cover the debt at the halt price (ceil — cover the full debt),
        // capped at the position's collateral.
        uint256 debtUSD = LendingMath.stableToUSD(currentDebt, _stableDecimals);
        uint256 eTokenToCover = debtUSD.mulDiv(PRECISION, haltPrice, Math.Rounding.Ceil);
        uint256 collateral = p.eTokenCollateral;
        if (eTokenToCover > collateral) eTokenToCover = collateral;

        // Redeem the covering slice at the halt redeem address for stablecoins; the market burns
        // the manager's eTokens and shrinks global exposure.
        uint256 proceeds;
        if (eTokenToCover > 0) {
            proceeds = IOwnMarket(registry.market()).redeemHalted(asset, eTokenToCover);
        }

        // Repay the vault's Aave debt; surplus (over-cover from ceil rounding) sweeps to the manager.
        if (proceeds > 0) _repayAaveAndSweep(proceeds);

        // Reduce book debt by the proceeds (capped at the position's debt).
        uint256 scaledRepay = proceeds >= currentDebt ? p.principal : LendingMath.actualToScaled(proceeds, idx);
        if (scaledRepay > p.principal) scaledRepay = p.principal;
        _totalScaledDebt -= scaledRepay;

        uint256 returnedToBorrower = collateral - eTokenToCover;

        if (scaledRepay == p.principal) {
            // Debt fully cleared — return any leftover collateral and close the position.
            delete _positions[borrower][asset];
            if (returnedToBorrower > 0) IERC20(eToken).safeTransfer(borrower, returnedToBorrower);
        } else {
            // Collateral exhausted before debt — leave a zero-collateral residual for absorbBadDebt.
            p.principal -= scaledRepay;
            p.eTokenCollateral = returnedToBorrower;
            p.interestIndex = idx;
        }

        emit HaltPositionSettled(borrower, asset, eTokenToCover, proceeds, returnedToBorrower);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IBorrowManager
    function rateParams()
        external
        view
        returns (uint64 basePremiumBps, uint64 optimalUtilBps, uint64 slope1Bps, uint64 slope2Bps)
    {
        InterestRateModel.Params memory p = _rateParams;
        return (p.basePremiumBps, p.optimalUtilBps, p.slope1Bps, p.slope2Bps);
    }

    /// @inheritdoc IBorrowManager
    function positionOf(address borrower, bytes32 asset) external view returns (Position memory) {
        return _positions[borrower][asset];
    }

    /// @inheritdoc IBorrowManager
    function debtOf(address borrower, bytes32 asset) external view returns (uint256) {
        Position memory p = _positions[borrower][asset];
        if (p.principal == 0) return 0;
        uint256 idx = _projectedIndex();
        return LendingMath.scaledToActual(p.principal, idx);
    }

    /// @inheritdoc IBorrowManager
    function healthFactor(address borrower, bytes32 asset, uint256 oraclePrice) external view returns (uint256) {
        Position memory p = _positions[borrower][asset];
        if (p.principal == 0) return type(uint256).max;
        uint256 idx = _projectedIndex();
        uint256 currentDebt = LendingMath.scaledToActual(p.principal, idx);
        uint256 price = _effectivePrice(p.collateralToken, asset, oraclePrice);
        return
            LendingMath.healthFactor(p.eTokenCollateral, currentDebt, price, liquidationThresholdBps, _stableDecimals);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IBorrowManager
    function setRateParams(
        InterestRateModel.Params calldata params
    ) external onlyAdmin {
        _rateParams = params;
        emit RateParamsUpdated(params);
    }

    /// @inheritdoc IBorrowManager
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

    /// @notice Set the liquidation close factor (BPS): the max fraction of a
    ///         position's debt one liquidation may repay while its health factor
    ///         is above {CLOSE_FACTOR_HF_THRESHOLD}. Must be in `(0, BPS]`.
    function setLiquidationCloseFactorBps(
        uint256 closeFactorBps
    ) external onlyAdmin {
        if (closeFactorBps == 0 || closeFactorBps > BPS) revert InvalidLiquidationConfig();
        liquidationCloseFactorBps = closeFactorBps;
    }

    /// @inheritdoc IBorrowManager
    function setTargetLtvBps(
        uint256 ltvBps
    ) external onlyAdmin {
        if (ltvBps == 0 || ltvBps >= BPS) revert InvalidLtv();
        emit TargetLtvBpsUpdated(targetLtvBps, ltvBps);
        targetLtvBps = ltvBps;
    }

    // ──────────────────────────────────────────────────────────
    //  Debt / cap / utilization / rate
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IBorrowManager
    /// @dev `totalScaledDebt × index` is the protocol's outstanding stablecoin
    ///      debt; lift it to 18-decimal USD. O(1) — one global index, no
    ///      per-asset iteration. Reads the *stored* index (not projected):
    ///      utilization feeds the rate curve, which feeds {_projectedIndex}, so
    ///      projecting here would recurse. Pending accrual since the last touch
    ///      is excluded — a sub-block-rate dust difference.
    function totalDebtUSD() public view returns (uint256) {
        uint256 idx = _index == 0 ? PRECISION : _index;
        uint256 totalStable = LendingMath.scaledToActual(_totalScaledDebt, idx);
        return LendingMath.stableToUSD(totalStable, _stableDecimals);
    }

    /// @inheritdoc IBorrowManager
    function maxDebtUSD() public view returns (uint256) {
        return IVaultManager(registry.vaultManager()).collateralMark(vault).mulDiv(targetLtvBps, BPS);
    }

    /// @inheritdoc IBorrowManager
    function utilizationBps() public view returns (uint256) {
        uint256 cap = maxDebtUSD();
        if (cap == 0) return 0;
        uint256 util = totalDebtUSD().mulDiv(BPS, cap);
        return util > BPS ? BPS : util;
    }

    /// @inheritdoc IBorrowManager
    function baseRateBps() public view returns (uint256) {
        IAaveV3Pool.ReserveDataLegacy memory data = IAaveV3Pool(aavePool).getReserveData(stablecoin);
        return uint256(data.currentVariableBorrowRate).mulDiv(BPS, RAY);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — accrual
    // ──────────────────────────────────────────────────────────

    /// @dev Advance the global cumulative interest index to `block.timestamp`,
    ///      writing the new index and accrual timestamp. This is the single
    ///      point where debt grows: because positions store *scaled* debt,
    ///      moving the index forward raises every borrower's debt at once.
    ///
    ///      Two short-circuits, in order:
    ///        1. Same block (`dt == 0`) — already current; avoids re-accruing
    ///           when several actions land in one block.
    ///        2. No debt (`_totalScaledDebt == 0`) — skip growth but roll the
    ///           timestamp so an idle period never back-charges the next borrower.
    ///
    ///      Otherwise grow by simple interest over `dt` at the current rate
    ///      (see {_currentRateBps}); compounding happens across touch points.
    ///      The index is seeded to PRECISION and the clock stamped in the
    ///      constructor, so there is no first-touch branch.
    function _accrue() internal {
        uint256 dt = block.timestamp - _lastAccrual;
        if (dt == 0) return;

        if (_totalScaledDebt == 0) {
            _lastAccrual = block.timestamp;
            return;
        }

        _index = LendingMath.accrueIndex(_index, _currentRateBps(), dt);
        _lastAccrual = block.timestamp;
    }

    /// @dev Read-only twin of {_accrue}: returns what the index *would* be at
    ///      `block.timestamp` without writing, so views ({debtOf},
    ///      {healthFactor}) report accrued figures between transactions. Mirrors
    ///      the same short-circuits.
    /// @return The projected index (PRECISION-scaled).
    function _projectedIndex() internal view returns (uint256) {
        uint256 idx = _index == 0 ? PRECISION : _index;
        if (_totalScaledDebt == 0) return idx;
        uint256 dt = block.timestamp - _lastAccrual;
        if (dt == 0) return idx;
        return LendingMath.accrueIndex(idx, _currentRateBps(), dt);
    }

    /// @dev Current annualized borrow rate (BPS) charged to borrowers:
    ///      `aaveRateWithFloor + premium(utilization)`. Global — driven by the
    ///      manager's vault-wide utilization, not by any individual asset.
    function _currentRateBps() internal view returns (uint256) {
        return _aaveRateWithFloor() + InterestRateModel.premium(utilizationBps(), _rateParams);
    }

    /// @dev The Aave-side rate component: `max(baseRateBps, minAaveBorrowRateBps)`.
    ///      The live read protects LPs even if the admin never sets a floor; the
    ///      floor lets the admin charge more for safety.
    function _aaveRateWithFloor() internal view returns (uint256) {
        uint256 live = baseRateBps();
        uint256 floor = minAaveBorrowRateBps;
        return live > floor ? live : floor;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — eligibility / oracle
    // ──────────────────────────────────────────────────────────

    /// @dev Gate a borrow: the asset must be active in the registry, the manager
    ///      must be a registered pass-through holder on the eToken (so dividends
    ///      earned while collateral is in custody can follow the borrower out),
    ///      and the asset must not be effectively paused or halted on the vault.
    /// @param asset  Ticker being borrowed against.
    /// @param eToken Resolved active eToken for `asset`.
    function _validateEligibility(bytes32 asset, address eToken) internal view {
        if (!IAssetRegistry(registry.assetRegistry()).isActiveAsset(asset)) revert AssetNotActive(asset);
        if (!IEToken(eToken).isPassThroughHolder(address(this))) revert PassThroughNotEnabled(eToken);
        IVaultManager vmgr = IVaultManager(registry.vaultManager());
        // Lending pauses with trading: no new borrows while the asset is paused or halted.
        if (vmgr.isAssetHalted(asset) || vmgr.isTradingPaused(asset)) {
            revert VaultEffectivelyHalted();
        }
    }

    /// @dev Resolve the current active eToken for `asset` from the registry.
    ///      Re-resolved per call so a stock-split token swap is always honored.
    function _resolveActiveEToken(
        bytes32 asset
    ) internal view returns (address) {
        return IAssetRegistry(registry.assetRegistry()).getActiveToken(asset);
    }

    /// @dev Price of one `collateralToken` unit given the active asset price. Active collateral uses
    ///      the raw price; legacy collateral scales by its split ratio (legacyUnits × ratio = active).
    function _effectivePrice(
        address collateralToken,
        bytes32 asset,
        uint256 activePrice
    ) internal view returns (uint256) {
        if (collateralToken == _resolveActiveEToken(asset)) return activePrice;
        uint256 ratio = IAssetRegistry(registry.assetRegistry()).legacyRatioToActive(collateralToken);
        return activePrice.mulDiv(ratio, PRECISION);
    }

    /// @dev Verify a signed price proof for `asset` via its primary oracle and
    ///      return the price (18-decimal USD). Forwards `msg.value` to cover any
    ///      oracle update fee (e.g. Pyth); the in-house oracle ignores it.
    /// @param asset     Ticker being priced.
    /// @param priceData Signed price payload.
    /// @return price Verified price, 18-decimal USD per token.
    function _verifyPrice(bytes32 asset, bytes calldata priceData) internal returns (uint256 price) {
        uint8 oracleType = IAssetRegistry(registry.assetRegistry()).getOracleType(asset);
        address oracleAddr = oracleType == 0 ? registry.pythOracle() : registry.inhouseOracle();
        uint256 timestamp;
        (price, timestamp) = IOracleVerifier(oracleAddr).verifyPrice{value: msg.value}(asset, priceData);
        // Risk decisions need a current price (verifyPrice itself does not bound age).
        uint256 maxAge = registry.priceMaxAge();
        if (timestamp > block.timestamp || block.timestamp - timestamp > maxAge) {
            revert StalePrice(timestamp, maxAge);
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — Aave repay
    // ──────────────────────────────────────────────────────────

    /// @dev Repay up to `amount` of the vault's Aave debt on its behalf. Aave
    ///      caps repayment at the outstanding debt and returns the actual amount
    ///      pulled; any surplus (the premium charged above Aave's own rate, or
    ///      an over-repay once Aave debt is exhausted) is the protocol's lending
    ///      fee. It is denominated in the stablecoin — not the vault's collateral
    ///      asset — so it is forwarded to the VM, who handles yield distribution
    ///      (offchain split + `shareYield`), and tracked via {LendingFeeAccrued}.
    /// @param amount Stablecoin amount available to repay (already held here).
    function _repayAaveAndSweep(
        uint256 amount
    ) internal {
        uint256 actualRepaid = IAaveV3Pool(aavePool).repay(stablecoin, amount, AAVE_VARIABLE_RATE_MODE, vault);
        uint256 surplus = amount > actualRepaid ? amount - actualRepaid : 0;
        if (surplus > 0) {
            address vaultManager = IOwnVault(vault).manager();
            IERC20(stablecoin).safeTransfer(vaultManager, surplus);
            emit LendingFeeAccrued(vaultManager, surplus);
        }
    }
}
