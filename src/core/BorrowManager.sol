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

import {BPS, PRECISION, VaultStatus} from "../interfaces/types/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BorrowManager — eToken-collateralised borrowing
/// @notice One-per-vault borrow manager implementing the venue-neutral {IBorrowManager}. Borrowers
///         post eTokens as collateral and receive the manager's stablecoin, sourced from an
///         Aave-V3-compatible lending pool via the vault's credit delegation. Each
///         (borrower, asset) pair carries its own position. Interest accrues on a single vault-wide
///         index: the pool's live variable rate (with an admin floor) plus a two-slope utilization
///         premium. Liquidation is signed-price gated and partial — an HF-gated close factor caps
///         the repay, and the bonus-based seize is capped at the position's remaining collateral.
///         The manager tracks its own book debt and enforces a vault-wide cap
///         (`targetLtvBps` × vault collateral mark).
/// @dev    Each vault binds exactly one manager for its lifetime (`OwnVault.setBorrowManager` is
///         one-shot); the interest-index floor attributes the vault's entire pool debt to this book
///         and relies on that. Runs behind a per-vault ERC-1967 proxy (UUPS): upgrades are
///         ADMIN-gated ({_authorizeUpgrade}) and independent per vault, the bound proxy address
///         never changes, and storage layout is append-only across implementations.
contract BorrowManager is IBorrowManager, Initializable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    /// @dev Aave V3 interest-rate mode for variable-rate borrows.
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
    //  Bound configuration (initializer-set, fixed thereafter)
    // ──────────────────────────────────────────────────────────
    // Effectively immutable: set once in {initialize}, never mutated. Held in
    // proxy storage (not immutables) so each per-vault proxy carries its own
    // binding over the shared implementation.

    /// @inheritdoc IBorrowManager
    address public override vault;
    /// @inheritdoc IBorrowManager
    address public override stablecoin;
    /// @dev Decimals of the borrow stablecoin (cached for USD conversion). Packs with `stablecoin`.
    uint8 internal _stableDecimals;
    /// @notice Variable debt token tracking the vault's live pool-side debt in `stablecoin`.
    address public debtToken;
    /// @notice Aave-V3-compatible lending pool funding the loans via the vault's credit delegation.
    address public aavePool;
    /// @notice Protocol registry (roles + protocol contract lookups).
    IProtocolRegistry public registry;

    // ──────────────────────────────────────────────────────────
    //  Configuration (admin-mutable)
    // ──────────────────────────────────────────────────────────

    /// @dev Two-slope interest-rate curve parameters; exposed via {rateParams}.
    InterestRateModel.Params internal _rateParams;

    /// @dev Floor for the Aave-side rate (BPS, annualized). The accrual loop
    ///      uses `max(floor, baseRateBps())` so the protocol always charges
    ///      at least the live Aave variable borrow rate plus the premium curve.
    ///      Admin can raise the floor for additional safety; the live read
    ///      protects LPs even when the admin is silent.
    uint256 public minAaveBorrowRateBps;

    /// @inheritdoc IBorrowManager
    uint256 public override interestBufferBps;

    /// @inheritdoc IBorrowManager
    uint256 public override minClaimHealthFactor;

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

    /// @dev Per-asset borrow blocklist. Borrowing is enabled for every asset by default; admin can
    ///      disable specific tickers (e.g. thin liquidity unsafe as collateral). Keyed by ticker so
    ///      the setting survives stock-split token migrations.
    mapping(bytes32 => bool) private _assetBorrowDisabled;

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

    /// @inheritdoc IBorrowManager
    /// @dev Deleted on {clearDebt} and when a fresh position is opened, so a permission never
    ///      carries over to a later position. Appended storage (UUPS layout is append-only).
    mapping(address => mapping(bytes32 => ClearingPermission)) public override debtClearingPermission;

    // ──────────────────────────────────────────────────────────
    //  Access control
    // ──────────────────────────────────────────────────────────

    /// @dev Role ids in the registry's AccessControl.
    bytes32 private constant ADMIN = keccak256("ADMIN");
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    // Modifier bodies inline at every use site; delegating to a shared internal
    // check keeps one copy of the role-read + revert in the bytecode.

    /// @dev Restrict to the protocol ADMIN role.
    modifier onlyAdmin() {
        _checkAdmin();
        _;
    }

    /// @dev Restrict to the protocol OPERATOR role.
    modifier onlyOperator() {
        _checkOperator();
        _;
    }

    /// @dev Revert unless the caller holds the protocol ADMIN role.
    function _checkAdmin() internal view {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
    }

    /// @dev Revert unless the caller holds the protocol OPERATOR role.
    function _checkOperator() internal view {
        if (!registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperator();
    }

    // ──────────────────────────────────────────────────────────
    //  Construction / initialization (UUPS)
    // ──────────────────────────────────────────────────────────

    /// @dev The implementation is only ever used behind per-vault ERC-1967 proxies; lock its own
    ///      initializers so the bare implementation can never be initialized or taken over.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize a per-vault manager proxy (runs once, in the proxy's constructor call).
    /// @param vault_        The vault this manager is bound to (1:1, permanent).
    /// @param stablecoin_   Stablecoin lent out by this manager.
    /// @param debtToken_    The pool's variable debt token for `stablecoin_` (reads the vault's live debt).
    /// @param aavePool_     Aave-V3-compatible lending pool funding the loans.
    /// @param registry_     Protocol registry (roles + contract lookups).
    /// @param targetLtvBps_ Vault-wide target pool LTV (BPS) backing the protocol debt cap.
    /// @param rateParams_   Interest-rate curve parameters.
    function initialize(
        address vault_,
        address stablecoin_,
        address debtToken_,
        address aavePool_,
        address registry_,
        uint256 targetLtvBps_,
        InterestRateModel.Params calldata rateParams_
    ) external initializer {
        if (
            vault_ == address(0) || stablecoin_ == address(0) || debtToken_ == address(0) || aavePool_ == address(0)
                || registry_ == address(0)
        ) revert ZeroAddress();
        if (targetLtvBps_ == 0 || targetLtvBps_ >= BPS) revert InvalidLtv();
        if (rateParams_.optimalUtilBps == 0 || rateParams_.optimalUtilBps >= BPS) revert InvalidRateParams();

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
        interestBufferBps = 100; // retain 1% of earned interest as a safety buffer
        minClaimHealthFactor = 1.1e18; // refuse claims that would leave the vault's Aave HF below 1.1

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
        (uint256 scaledDebt, uint256 oraclePrice, uint256 idx) =
            _executeBorrow(asset, eToken, eTokenAmount, stablecoinAmount, eTokenAmount, 0, priceData);

        // A fresh position must not inherit a clearing permission granted on an earlier one.
        delete debtClearingPermission[msg.sender][asset];
        _positions[msg.sender][asset] = Position({
            eTokenCollateral: eTokenAmount,
            principal: scaledDebt,
            interestIndex: idx,
            collateralToken: eToken
        });
        _totalScaledDebt += scaledDebt;

        emit Borrowed(msg.sender, asset, eTokenAmount, stablecoinAmount, oraclePrice);

        _refundExcessEth();
    }

    /// @inheritdoc IBorrowManager
    function borrowMore(
        bytes32 asset,
        uint256 eTokenAmount,
        uint256 stablecoinAmount,
        bytes calldata priceData
    ) external payable nonReentrant {
        if (stablecoinAmount == 0) revert ZeroAmount();
        Position storage p = _positions[msg.sender][asset];
        if (p.principal == 0) revert NoPosition(msg.sender, asset);

        address eToken = _resolveActiveEToken(asset);
        // Never mix tokens: legacy collateral (post-migration) is repay-only.
        if (p.collateralToken != eToken) revert CollateralTokenMismatch();

        (uint256 scaledDebt, uint256 oraclePrice, uint256 idx) = _executeBorrow(
            asset, eToken, eTokenAmount, stablecoinAmount, p.eTokenCollateral + eTokenAmount, p.principal, priceData
        );

        p.eTokenCollateral += eTokenAmount;
        p.principal += scaledDebt;
        p.interestIndex = idx;
        _totalScaledDebt += scaledDebt;

        emit Borrowed(msg.sender, asset, eTokenAmount, stablecoinAmount, oraclePrice);

        _refundExcessEth();
    }

    /// @dev Shared borrow engine for {borrow} and {borrowMore}: gates eligibility, verifies the
    ///      signed price against the band, accrues, checks the whole-position LTV
    ///      (`priorScaledDebt` + new borrow vs `totalCollateral`) and the vault-wide debt cap,
    ///      pulls the top-up collateral, and draws the stablecoin from Aave to the borrower.
    ///      A fresh borrow passes `priorScaledDebt = 0`, collapsing the LTV check to the
    ///      new amounts alone. The caller records the position delta and emits {Borrowed}.
    /// @return scaledDebt  Scaled-debt delta to add to the position (non-zero).
    /// @return oraclePrice Verified asset price (18-dec USD).
    /// @return idx         Post-accrual interest index the delta was scaled at.
    function _executeBorrow(
        bytes32 asset,
        address eToken,
        uint256 eTokenAmount,
        uint256 stablecoinAmount,
        uint256 totalCollateral,
        uint256 priorScaledDebt,
        bytes calldata priceData
    ) internal returns (uint256 scaledDebt, uint256 oraclePrice, uint256 idx) {
        _validateEligibility(asset);

        oraclePrice = _verifyPrice(asset, priceData);
        _checkPriceBand(asset, oraclePrice);

        _accrue();
        idx = _index;

        // LTV check on the whole position: prior debt (accrued) + new borrow vs total collateral.
        {
            uint256 debtValueUSD = LendingMath.stableToUSD(
                LendingMath.scaledToActual(priorScaledDebt, idx) + stablecoinAmount, _stableDecimals
            );
            uint256 maxBorrowUSD = LendingMath.collateralUSD(totalCollateral, oraclePrice).mulDiv(borrowLtvBps, BPS);
            if (debtValueUSD > maxBorrowUSD) revert InsufficientCollateral(debtValueUSD, maxBorrowUSD);
        }

        // Protocol-level hard cap: total debt must stay within the vault's
        // collateral-backed target LTV. Scoped so the locals free before the
        // rest of the borrow flow (avoids stack-too-deep without via-ir).
        {
            uint256 cap = maxDebtUSD();
            uint256 projected = totalDebtUSD() + LendingMath.stableToUSD(stablecoinAmount, _stableDecimals);
            if (projected > cap) revert BorrowExceedsCap(projected, cap);
        }

        // Pull eToken collateral into the manager's pooled custody.
        if (eTokenAmount > 0) IERC20(eToken).safeTransferFrom(msg.sender, address(this), eTokenAmount);

        // Borrow stablecoin from Aave on the vault's behalf via credit delegation and forward it.
        _drawFromAave(stablecoinAmount);
        {
            // Aave blocks HF < 1.0 on the draw itself; enforce the same configured margin every
            // collateral-decreasing path checks, so borrows can't enter the band where LP exits revert.
            uint256 hf = _vaultAaveHealthFactor();
            if (hf < minClaimHealthFactor) revert VaultUnsafeHealthFactor(hf);
        }
        IERC20(stablecoin).safeTransfer(msg.sender, stablecoinAmount);

        // principal is scaled debt: actual debt grows via index. A zero scaled
        // debt would collide with the "no position" sentinel.
        scaledDebt = LendingMath.actualToScaled(stablecoinAmount, idx);
        if (scaledDebt == 0) revert AmountTooSmall();
    }

    /// @inheritdoc IBorrowManager
    function addCollateral(bytes32 asset, uint256 eTokenAmount) external nonReentrant {
        if (eTokenAmount == 0) revert ZeroAmount();
        Position storage p = _positions[msg.sender][asset];
        if (p.principal == 0) revert NoPosition(msg.sender, asset);

        p.eTokenCollateral += eTokenAmount;
        // Pull more of the exact token the position holds (never mixes active/legacy collateral).
        IERC20(p.collateralToken).safeTransferFrom(msg.sender, address(this), eTokenAmount);

        emit CollateralAdded(msg.sender, asset, eTokenAmount, p.eTokenCollateral);
    }

    // ──────────────────────────────────────────────────────────
    //  Repay
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IBorrowManager
    function repay(bytes32 asset, uint256 amount) external nonReentrant returns (uint256 collateralReleased) {
        uint256 repayAmount;
        address collateralToken;
        (repayAmount, collateralReleased, collateralToken) = _repayPosition(msg.sender, asset, amount);

        // Return the exact token posted (may be a legacy token after a migration; borrower converts).
        if (collateralReleased > 0) {
            IERC20(collateralToken).safeTransfer(msg.sender, collateralReleased);
        }

        emit Repaid(msg.sender, asset, repayAmount, collateralReleased, _positions[msg.sender][asset].principal);
    }

    /// @dev Shared repay engine for {repay} and {clearDebt}: pulls up to `amount` stablecoin from
    ///      `msg.sender` (clamped to the position's current debt), forwards it to Aave, and shrinks
    ///      `(borrower, asset)` — a full repay closes the position and releases all collateral, a
    ///      partial one releases pro-rata (preserves LTV at constant price). The caller routes the
    ///      released collateral and emits its own event.
    function _repayPosition(
        address borrower,
        bytes32 asset,
        uint256 amount
    ) internal returns (uint256 repayAmount, uint256 collateralReleased, address collateralToken) {
        Position storage p = _positions[borrower][asset];
        if (p.principal == 0) revert NoPosition(borrower, asset);

        _accrue();
        uint256 idx = _index;

        uint256 currentDebt = LendingMath.scaledToActual(p.principal, idx);
        repayAmount = amount > currentDebt ? currentDebt : amount;
        if (repayAmount == 0) revert ZeroAmount();

        collateralToken = p.collateralToken;

        // Pull stablecoin from caller.
        IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), repayAmount);

        // Forward to Aave; surplus (premium that exceeds Aave's debt) sweeps to vault as LP yield.
        _repayAaveAndSweep(repayAmount);

        if (repayAmount == currentDebt) {
            // Full close — release all collateral.
            collateralReleased = p.eTokenCollateral;
            _totalScaledDebt -= p.principal;
            delete _positions[borrower][asset];
        } else {
            // Partial — release pro-rata; preserves LTV at constant price.
            collateralReleased = p.eTokenCollateral.mulDiv(repayAmount, currentDebt);
            // Rounding direction for scaled-debt reduction: floor so the
            // protocol keeps a sliver more debt vs releasing more collateral
            // (protocol-favorable).
            uint256 scaledRepay = LendingMath.actualToScaled(repayAmount, idx);
            if (scaledRepay == 0) revert AmountTooSmall();
            // Defensive: never let scaledRepay exceed stored principal.
            if (scaledRepay > p.principal) scaledRepay = p.principal;
            p.principal -= scaledRepay;
            p.eTokenCollateral -= collateralReleased;
            p.interestIndex = idx;
            _totalScaledDebt -= scaledRepay;
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Debt clearing (borrower-permissioned third-party close)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IBorrowManager
    function setDebtClearingPermission(bytes32 asset, address clearer, uint256 feeBps) external {
        if (_positions[msg.sender][asset].principal == 0) revert NoPosition(msg.sender, asset);
        if (feeBps > BPS) revert InvalidClearingFee();

        if (feeBps == 0) delete debtClearingPermission[msg.sender][asset];
        else debtClearingPermission[msg.sender][asset] = ClearingPermission({clearer: clearer, feeBps: uint96(feeBps)});

        emit DebtClearingPermissionSet(msg.sender, asset, clearer, feeBps);
    }

    /// @inheritdoc IBorrowManager
    function clearDebt(
        address borrower,
        bytes32 asset,
        uint256 repayAmount
    ) external nonReentrant returns (uint256 debtRepaid) {
        if (_positions[borrower][asset].principal == 0) revert NoPosition(borrower, asset);
        ClearingPermission memory perm = debtClearingPermission[borrower][asset];
        if (perm.feeBps == 0 || (perm.clearer != address(0) && perm.clearer != msg.sender)) {
            revert NotAuthorizedToClear(msg.sender);
        }

        (uint256 repaid, uint256 collateralReleased, address collateralToken) =
            _repayPosition(borrower, asset, repayAmount);
        debtRepaid = repaid;

        // The permission outlives partial clears; a full close retires it with the position.
        if (_positions[borrower][asset].principal == 0) delete debtClearingPermission[borrower][asset];

        // Split the released slice. Fee rounds down — the borrower keeps the crumb.
        uint256 fee = collateralReleased.mulDiv(perm.feeBps, BPS);
        if (fee > 0) IERC20(collateralToken).safeTransfer(msg.sender, fee);
        uint256 returned = collateralReleased - fee;
        if (returned > 0) IERC20(collateralToken).safeTransfer(borrower, returned);

        emit DebtCleared(borrower, asset, msg.sender, repaid, fee, returned);
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
        // Halted assets settle only via settleHaltedPosition() at the frozen halt price (GPT5-H-01).
        if (_vaultManager().isAssetHalted(asset)) revert VaultEffectivelyHalted();

        _accrue();
        uint256 oraclePrice = _verifyPrice(asset, priceData);
        _checkPriceBand(asset, oraclePrice);
        _liquidate(borrower, asset, repayAmount, oraclePrice);
        _refundExcessEth();
    }

    /// @inheritdoc IBorrowManager
    function accrue() external {
        _accrue();
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

        // Cap the bonus-seize at the remaining collateral instead of reverting: a deeply underwater
        // position seizes all of it, driving collateral to exactly 0 so the residual stays absorbable
        // (no sub-seize-unit dust crumb stranded).
        uint256 seize = LendingMath.seizeAmount(repayAmount, price, liquidationBonusBps, _stableDecimals);
        if (seize > p.eTokenCollateral) seize = p.eTokenCollateral;

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
            // Zero scaled repay would seize collateral without reducing debt.
            uint256 scaledRepay = LendingMath.actualToScaled(repayAmount, _index);
            if (scaledRepay == 0) revert AmountTooSmall();
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
    ) external payable nonReentrant onlyOperator {
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

        // LP-socialized slice: release vault collateral to the protocol treasury, priced
        // off the vault's collateral oracle (aToken ≈ underlying 1:1).
        uint256 collateralReleased;
        uint256 lpLoss = residual - absorbAmount;
        if (lpLoss > 0) {
            uint256 lpLossUSD = LendingMath.stableToUSD(lpLoss, _stableDecimals);
            collateralReleased = _convertToCollateral(lpLossUSD, collateralPriceData);
            if (collateralReleased > 0) {
                // Collateral is released to the protocol treasury (fixed in the vault), not to the
                // caller — the caller fronts the stablecoin; the treasury receives the LP-socialized
                // collateral slice.
                IOwnVault(vault).releaseCollateralForBadDebt(collateralReleased);
            }
        }

        emit BadDebtAbsorbed(borrower, asset, msg.sender, residual, absorbAmount, collateralReleased);

        _refundExcessEth();
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

        IVaultManager vmgr = _vaultManager();
        if (!vmgr.isAssetHalted(asset)) revert AssetNotHalted(asset);
        // Proceeds below are accounted in stablecoin units; the assumption must hold on-chain.
        if (vmgr.paymentToken() != stablecoin) revert PaymentTokenMismatch();
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
    //  Collateral dividends (lending revenue, swept to the VM)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IBorrowManager
    function sweepDividends(
        address eToken
    ) external nonReentrant returns (uint256 amount) {
        if (!_assetRegistry().isValidToken(IEToken(eToken).ticker(), eToken)) {
            revert InvalidEToken(eToken);
        }
        amount = IEToken(eToken).claimableRewards(address(this));
        if (amount == 0) revert NoDividendsToSweep();

        // Realize the pooled dividends, then forward them to the VM (fixed destination), matching the
        // premium sweep in {_repayAaveAndSweep}. The VM handles downstream distribution off-chain.
        IEToken(eToken).claimRewards();
        address beneficiary = _boundManager();
        IERC20(IEToken(eToken).rewardToken()).safeTransfer(beneficiary, amount);

        emit DividendsSwept(eToken, beneficiary, amount);
    }

    /// @inheritdoc IBorrowManager
    function claimEarnedInterest(
        uint256 amount
    ) external nonReentrant {
        address mgr = _boundManager();
        if (msg.sender != mgr) revert OnlyManager();
        if (amount == 0) revert ZeroAmount();

        _accrue();
        uint256 claimable = claimableInterest();
        if (amount > claimable) revert ClaimExceedsClaimable(amount, claimable);

        // The interest is earned but not yet collected from borrowers, so draw the cash from the
        // vault's Aave credit line. Borrower repayments later retire this draw via the smaller surplus
        // left to sweep in {_repayAaveAndSweep}; the carry (Aave interest on the draw) is borne by the VM.
        _drawFromAave(amount);

        // Aave blocks HF < 1.0 on the borrow itself; this enforces a configurable margin above that.
        uint256 hf = _vaultAaveHealthFactor();
        if (hf < minClaimHealthFactor) revert ClaimUnsafeHealthFactor(hf);

        IERC20(stablecoin).safeTransfer(mgr, amount);
        emit InterestClaimed(mgr, amount);
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
    function requireVaultHealthy() external view {
        // Aave only blocks HF < 1.0 on its own actions; enforce the configured margin above it after
        // collateral leaves on a release, so the vault's Aave position can't be driven to liquidation.
        uint256 hf = _vaultAaveHealthFactor();
        if (hf < minClaimHealthFactor) revert VaultUnsafeHealthFactor(hf);
    }

    /// @inheritdoc IBorrowManager
    function isAssetBorrowable(
        bytes32 asset
    ) external view returns (bool) {
        return !_assetBorrowDisabled[asset];
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
        if (params.optimalUtilBps == 0 || params.optimalUtilBps >= BPS) revert InvalidRateParams();
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

    /// @notice Set the per-position borrow LTV. Admin-only.
    /// @param ltvBps New borrow LTV (BPS); must be in `(0, liquidationThresholdBps)`.
    function setBorrowLtvBps(
        uint256 ltvBps
    ) external onlyAdmin {
        if (ltvBps == 0 || ltvBps >= liquidationThresholdBps) revert InvalidLiquidationConfig();
        borrowLtvBps = ltvBps;
    }

    /// @notice Set the minimum Aave-side rate floor; the rate used at accrual is
    ///         `max(floor, liveAaveRate)`. Admin-only.
    /// @param rateBps New floor (BPS, annualized); 0 disables the floor.
    function setMinAaveBorrowRateBps(
        uint256 rateBps
    ) external onlyAdmin {
        // Bounded at 100% APR — a floor is a minimum base rate, so no legitimate value nears this; the
        // cap keeps `rate * dt` in accrueIndex from overflowing and bricking accrual.
        if (rateBps > BPS) revert InvalidMinAaveBorrowRate();
        minAaveBorrowRateBps = rateBps;
    }

    /// @notice Set the liquidation close factor — the max fraction of a position's debt one
    ///         liquidation may repay while its health factor is above
    ///         {CLOSE_FACTOR_HF_THRESHOLD}. Admin-only.
    /// @param closeFactorBps New close factor (BPS); must be in `(0, BPS]`.
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

    /// @inheritdoc IBorrowManager
    function setAssetBorrowable(bytes32 asset, bool borrowable) external onlyOperator {
        _assetBorrowDisabled[asset] = !borrowable;
        emit AssetBorrowableUpdated(asset, borrowable);
    }

    /// @inheritdoc IBorrowManager
    function setInterestBufferBps(
        uint256 bps
    ) external onlyAdmin {
        // Must retain a non-zero buffer (keeps claims strictly below earned interest, so the index
        // floor never activates and borrowers are never over-charged) and cannot exceed 100%.
        if (bps == 0 || bps > BPS) revert InvalidInterestBuffer();
        uint256 old = interestBufferBps;
        interestBufferBps = bps;
        emit InterestBufferUpdated(old, bps);
    }

    /// @inheritdoc IBorrowManager
    function setMinClaimHealthFactor(
        uint256 hf
    ) external onlyAdmin {
        // At least Aave's own liquidation floor (1.0); the margin above it is the admin's risk choice.
        if (hf < PRECISION) revert InvalidMinClaimHealthFactor();
        uint256 old = minClaimHealthFactor;
        minClaimHealthFactor = hf;
        emit MinClaimHealthFactorUpdated(old, hf);
    }

    /// @dev UUPS upgrade gate: only the protocol ADMIN role may upgrade this proxy's
    ///      implementation. Each vault's manager is its own proxy, so upgrades are per-vault.
    function _authorizeUpgrade(
        address
    ) internal view override onlyAdmin {}

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
        return _vaultManager().collateralMark(vault).mulDiv(targetLtvBps, BPS);
    }

    /// @inheritdoc IBorrowManager
    function utilizationBps() public view returns (uint256) {
        uint256 cap = maxDebtUSD();
        // A zeroed cap with live debt (halt, genesis, released collateral) is fully utilised, not idle.
        if (cap == 0) return _totalScaledDebt == 0 ? 0 : BPS;
        uint256 util = totalDebtUSD().mulDiv(BPS, cap);
        return util > BPS ? BPS : util;
    }

    /// @inheritdoc IBorrowManager
    function baseRateBps() public view returns (uint256) {
        IAaveV3Pool.ReserveDataLegacy memory data = IAaveV3Pool(aavePool).getReserveData(stablecoin);
        return uint256(data.currentVariableBorrowRate).mulDiv(BPS, RAY);
    }

    /// @inheritdoc IBorrowManager
    /// @dev Earned, uncollected premium = book debt − the vault's real Aave debt (≥ 0 by the floor).
    function earnedInterest() public view returns (uint256) {
        uint256 book = LendingMath.scaledToActual(_totalScaledDebt, _projectedIndex());
        uint256 aaveDebt = _vaultAaveDebt();
        return book > aaveDebt ? book - aaveDebt : 0;
    }

    /// @inheritdoc IBorrowManager
    /// @dev Buffer is per-claim, not a cumulative reserve: each claim draws from Aave (raising aaveDebt)
    ///      and shrinks the gap, so iterative claims can extract ~all premium. By design — the premium is
    ///      the VM's own revenue; over-claiming only risks its own floor/HF.
    function claimableInterest() public view returns (uint256) {
        return earnedInterest().mulDiv(BPS - interestBufferBps, BPS);
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

        if (_totalScaledDebt == 0) {
            if (dt != 0) _lastAccrual = block.timestamp;
            return;
        }

        if (dt != 0) {
            _index = LendingMath.accrueIndex(_index, _currentRateBps(), dt);
            _lastAccrual = block.timestamp;
        }
        // Never let book debt fall below the vault's real Aave debt (see {_flooredIndex}).
        _index = _flooredIndex(_index);
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
        if (dt != 0) idx = LendingMath.accrueIndex(idx, _currentRateBps(), dt);
        return _flooredIndex(idx);
    }

    /// @dev Floor `idx` so total book debt (`_totalScaledDebt × idx`) never sits below the vault's
    ///      real Aave debt, read from the variable debt token. Aave compounds continuously and can
    ///      outrun our sampled simple-interest model; flooring to the ground truth keeps any
    ///      shortfall on the protocol's premium, never on LPs. The index is monotonic, so this only
    ///      ever raises it.
    ///
    ///      Attributing the vault's entire Aave debt to this book assumes one borrow manager per
    ///      vault — a protocol invariant (`OwnVault.setBorrowManager` is one-shot). The floor is
    ///      skipped on a dust base: spreading residual Aave debt (rounding crumbs of the book/Aave
    ///      divergence) over near-zero scaled units would irreversibly explode the index for every
    ///      position. At dust scale there is no meaningful book left for the floor to protect.
    function _flooredIndex(
        uint256 idx
    ) internal view returns (uint256) {
        if (_totalScaledDebt < 10 ** _stableDecimals) return idx;
        uint256 realAaveDebt = _vaultAaveDebt();
        if (realAaveDebt == 0) return idx;
        uint256 minIndex = realAaveDebt.mulDiv(PRECISION, _totalScaledDebt);
        return idx < minIndex ? minIndex : idx;
    }

    /// @dev Refund ETH left after oracle fees. Pays out the whole balance: the contract has no
    ///      `receive`, but SELFDESTRUCT and coinbase payments bypass it, so force-fed ETH is swept
    ///      by whichever caller next hits a payable entry point (and 1 wei bricks these paths for a
    ///      contract caller with no payable `receive`). Accepted — the deployed venue pays no oracle
    ///      fees, so no path forwards ETH. Snapshot `balance - msg.value` if that ever changes.
    ///      Called last (after all state writes) inside `nonReentrant` entry points.
    function _refundExcessEth() internal {
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok,) = msg.sender.call{value: bal}("");
        if (!ok) revert EthRefundFailed();
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
    //  Internal — shared reads (single bytecode copy per external-call pattern)
    // ──────────────────────────────────────────────────────────

    /// @dev The global VaultManager (risk accounting + control hub), resolved via the registry.
    function _vaultManager() internal view returns (IVaultManager) {
        return IVaultManager(registry.vaultManager());
    }

    /// @dev The AssetRegistry (tickers, active/legacy tokens, oracle config), resolved via the registry.
    function _assetRegistry() internal view returns (IAssetRegistry) {
        return IAssetRegistry(registry.assetRegistry());
    }

    /// @dev The vault's live Aave debt (variable debt token balance).
    function _vaultAaveDebt() internal view returns (uint256) {
        return IERC20(debtToken).balanceOf(vault);
    }

    /// @dev The VM bound to this manager's vault (lending-revenue destination).
    function _boundManager() internal view returns (address) {
        return IOwnVault(vault).manager();
    }

    /// @dev The vault's live Aave health factor.
    function _vaultAaveHealthFactor() internal view returns (uint256 hf) {
        (,,,,, hf) = IAaveV3Pool(aavePool).getUserAccountData(vault);
    }

    /// @dev Draw stablecoin from Aave on the vault's behalf via credit delegation.
    function _drawFromAave(
        uint256 amount
    ) internal {
        IAaveV3Pool(aavePool).borrow(stablecoin, amount, AAVE_VARIABLE_RATE_MODE, 0, vault);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — eligibility / oracle
    // ──────────────────────────────────────────────────────────

    /// @dev Gate a borrow: the asset must be active in the registry, this manager's vault must be
    ///      on the registry's per-asset lending allowlist, the asset must be admin-enabled for
    ///      borrowing on this manager, and not effectively paused or halted on the vault. Borrow-only
    ///      gate: repay/liquidate/halt-settle stay open after an allowlist revocation so existing
    ///      positions wind down.
    /// @param asset Ticker being borrowed against.
    function _validateEligibility(
        bytes32 asset
    ) internal view {
        if (IOwnVault(vault).vaultStatus() != VaultStatus.Active) revert VaultNotActive();
        IAssetRegistry assetRegistry = _assetRegistry();
        if (!assetRegistry.isActiveAsset(asset)) revert AssetNotActive(asset);
        if (!assetRegistry.isLendingVaultAllowed(asset, vault)) revert LendingVaultNotAllowed(asset, vault);
        if (_assetBorrowDisabled[asset]) revert AssetNotBorrowable(asset);
        IVaultManager vmgr = _vaultManager();
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
        return _assetRegistry().getActiveToken(asset);
    }

    /// @dev Price of one `collateralToken` unit given the active asset price. Active collateral uses
    ///      the raw price; legacy collateral scales by its split ratio (legacyUnits × ratio = active).
    function _effectivePrice(
        address collateralToken,
        bytes32 asset,
        uint256 activePrice
    ) internal view returns (uint256) {
        if (collateralToken == _resolveActiveEToken(asset)) return activePrice;
        uint256 ratio = _assetRegistry().legacyRatioToActive(collateralToken);
        return activePrice.mulDiv(ratio, PRECISION);
    }

    /// @dev Verify a signed price proof for `asset` via its primary oracle and
    ///      return the price (18-decimal USD). Forwards `msg.value` to cover any
    ///      oracle update fee (e.g. Pyth); the in-house oracle ignores it.
    /// @param asset     Ticker being priced.
    /// @param priceData Signed price payload.
    /// @return price Verified price, 18-decimal USD per token.
    function _verifyPrice(bytes32 asset, bytes calldata priceData) internal returns (uint256 price) {
        uint8 oracleType = _assetRegistry().getOracleType(asset);
        address oracleAddr = oracleType == 0 ? registry.pythOracle() : registry.inhouseOracle();
        uint256 timestamp;
        // Forward only the verifier's fee; payable entry points refund the surplus.
        uint256 fee = IOracleVerifier(oracleAddr).verifyFee(priceData);
        (price, timestamp) = IOracleVerifier(oracleAddr).verifyPrice{value: fee}(asset, priceData);
        // Risk decisions need a current price (verifyPrice itself does not bound age).
        uint256 maxAge = registry.priceMaxAge();
        if (timestamp > block.timestamp || block.timestamp - timestamp > maxAge) {
            revert StalePrice(timestamp, maxAge);
        }
    }

    /// @dev Bound an inline proof price to ±settleBandBps of the keeper-fresh asset mark (mirrors
    ///      OwnMarket._checkSettleBand) — caps leaked/faulty-signer damage on borrow/liquidate by
    ///      rejecting an off-mark attestation (over-value → over-borrow, under-value → wrongful
    ///      liquidation). Fail-closed: a missing or stale mark reverts.
    function _checkPriceBand(bytes32 asset, uint256 price) internal view {
        IVaultManager vmgr = _vaultManager();
        uint256 mark = vmgr.assetMark(asset);
        if (mark == 0 || block.timestamp - vmgr.assetMarkUpdatedAt(asset) > vmgr.maxMarkAge()) {
            revert PriceMarkStale(asset);
        }
        uint256 band = vmgr.settleBandBps();
        uint256 diff = price > mark ? price - mark : mark - price;
        if (diff * BPS > mark * band) revert PriceOutOfBand(asset, price, mark, band);
    }

    /// @dev Convert an 18-dec USD value to the bound vault's collateral, in native token units
    ///      (fresh-price verified, floored to the asset's decimals — protocol-favorable).
    function _convertToCollateral(uint256 usdValue, bytes calldata collateralPriceData) internal returns (uint256) {
        bytes32 collatAsset = _vaultManager().vaultCollateralAsset(vault);
        uint256 price = _verifyPrice(collatAsset, collateralPriceData);
        uint256 collateral18 = usdValue.mulDiv(PRECISION, price);
        uint256 collatDecimals = IERC20Metadata(IOwnVault(vault).asset()).decimals();
        return collateral18 / (10 ** (18 - collatDecimals));
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
        // Aave's repay reverts on zero outstanding debt, and anyone can drive the vault's pooled debt
        // to zero by repaying on its behalf; skip the call when nothing is owed so closes never brick
        // (the whole amount is surplus then).
        uint256 outstanding = _vaultAaveDebt();
        uint256 actualRepaid =
            outstanding == 0 ? 0 : IAaveV3Pool(aavePool).repay(stablecoin, amount, AAVE_VARIABLE_RATE_MODE, vault);
        uint256 surplus = amount > actualRepaid ? amount - actualRepaid : 0;
        if (surplus > 0) {
            address vaultManager = _boundManager();
            IERC20(stablecoin).safeTransfer(vaultManager, surplus);
            emit LendingFeeAccrued(vaultManager, surplus);
        }
    }
}
