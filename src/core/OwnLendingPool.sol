// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOwnLendingPool} from "../interfaces/IOwnLendingPool.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IAaveV3Pool} from "../interfaces/external/IAaveV3Pool.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {OwnAToken} from "../tokens/OwnAToken.sol";
import {OwnDebtToken} from "../tokens/OwnDebtToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OwnLendingPool — single-asset, zero-rate lending pool
/// @notice Protocol-owned replacement for an external Aave V3 deployment on chains
///         where Aave is unavailable. One stablecoin reserve, a 1:1 aToken, and
///         principal-only debt: the pool charges no interest — all lending interest
///         is charged by the BorrowManager premium layer, which reads this pool's
///         `currentVariableBorrowRate` as 0.
///
///         Implements exactly the {IAaveV3Pool} subset the protocol consumes, so it
///         drops in as the `aavePool` for LendingRouter (supply/withdraw), BorrowManager
///         (delegated borrow/repay, health reads), and OwnVault (collateral wiring).
///
///         Supply is allowlist-gated (router-only by policy); borrow, repay, and
///         withdraw are permissionless, mirroring Aave.
///
///         Deliberately omitted vs Aave: liquidation (with a zero rate, health can
///         only change at gated borrow/withdraw/aToken-transfer sites, so HF < 1 is
///         unreachable), flashloans, interest indexes (fixed at 1 RAY), and
///         multi-reserve support.
contract OwnLendingPool is IOwnLendingPool, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @dev Aave RAY unit (1e27) — reported for index/rate fields.
    uint256 private constant RAY = 1e27;

    /// @dev Aave base-currency unit (1e8 = $1); the underlying is a $1 stablecoin.
    uint256 private constant BASE_CURRENCY_UNIT = 1e8;

    bytes32 private constant ADMIN = keccak256("ADMIN");

    /// @inheritdoc IOwnLendingPool
    address public immutable override underlying;

    /// @inheritdoc IOwnLendingPool
    address public immutable override aToken;

    /// @inheritdoc IOwnLendingPool
    address public immutable override variableDebtToken;

    /// @notice ProtocolRegistry used to resolve the ADMIN role.
    IProtocolRegistry public immutable registry;

    /// @dev Underlying decimals, cached for base-currency scaling.
    uint8 private immutable _underlyingDecimals;

    /// @inheritdoc IOwnLendingPool
    uint256 public override ltvBps;

    /// @inheritdoc IOwnLendingPool
    uint256 public override liquidationThresholdBps;

    /// @inheritdoc IOwnLendingPool
    mapping(address => bool) public override supplierAllowed;

    /// @inheritdoc IOwnLendingPool
    mapping(address => uint256) public override debtOf;

    /// @inheritdoc IOwnLendingPool
    uint256 public override totalDebt;

    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    modifier onlyKnownReserve(
        address asset
    ) {
        if (asset != underlying) revert UnknownReserve(asset);
        _;
    }

    /// @param registry_   ProtocolRegistry (ADMIN role source).
    /// @param underlying_ The single reserve asset (lending stablecoin).
    /// @param aTokenName    aToken ERC-20 name.
    /// @param aTokenSymbol  aToken ERC-20 symbol.
    /// @param debtTokenName   Debt token name.
    /// @param debtTokenSymbol Debt token symbol.
    /// @param ltvBps_ Borrow LTV (BPS).
    /// @param liquidationThresholdBps_ Liquidation threshold (BPS).
    constructor(
        address registry_,
        address underlying_,
        string memory aTokenName,
        string memory aTokenSymbol,
        string memory debtTokenName,
        string memory debtTokenSymbol,
        uint256 ltvBps_,
        uint256 liquidationThresholdBps_
    ) {
        if (registry_ == address(0) || underlying_ == address(0)) revert ZeroAddress();
        _validateLtvConfig(ltvBps_, liquidationThresholdBps_);

        registry = IProtocolRegistry(registry_);
        underlying = underlying_;
        ltvBps = ltvBps_;
        liquidationThresholdBps = liquidationThresholdBps_;

        uint8 dec = IERC20Metadata(underlying_).decimals();
        _underlyingDecimals = dec;
        aToken = address(new OwnAToken(aTokenName, aTokenSymbol, dec, address(this)));
        variableDebtToken = address(new OwnDebtToken(debtTokenName, debtTokenSymbol, dec, address(this)));

        emit LtvConfigUpdated(ltvBps_, liquidationThresholdBps_);
    }

    // ──────────────────────────────────────────────────────────
    //  Supply / withdraw
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAaveV3Pool
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 /*referralCode*/
    ) external override nonReentrant onlyKnownReserve(asset) {
        if (amount == 0) revert ZeroAmount();
        if (onBehalfOf == address(0)) revert ZeroAddress();
        if (!supplierAllowed[msg.sender]) revert SupplierNotAllowed(msg.sender);

        _pullExact(msg.sender, amount);
        OwnAToken(aToken).mint(onBehalfOf, amount);

        emit Supplied(msg.sender, onBehalfOf, amount);
    }

    /// @inheritdoc IAaveV3Pool
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external override nonReentrant onlyKnownReserve(asset) returns (uint256) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == type(uint256).max) amount = OwnAToken(aToken).balanceOf(msg.sender);
        if (amount == 0) revert ZeroAmount();

        // Effects: burn the receipt, then health-check the withdrawer's remaining
        // collateral against their debt before the underlying leaves.
        OwnAToken(aToken).burn(msg.sender, amount);
        _requireHealthy(msg.sender);

        IERC20(underlying).safeTransfer(to, amount);

        emit Withdrawn(msg.sender, to, amount);
        return amount;
    }

    // ──────────────────────────────────────────────────────────
    //  Borrow / repay
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAaveV3Pool
    function borrow(
        address asset,
        uint256 amount,
        uint256, /*interestRateMode*/
        uint16, /*referralCode*/
        address onBehalfOf
    ) external override nonReentrant onlyKnownReserve(asset) {
        if (amount == 0) revert ZeroAmount();
        if (onBehalfOf == address(0)) revert ZeroAddress();

        // Delegated borrow consumes credit-delegation allowance (Aave parity).
        if (msg.sender != onBehalfOf) {
            OwnDebtToken(variableDebtToken).consumeAllowance(onBehalfOf, msg.sender, amount);
        }

        uint256 newDebt = debtOf[onBehalfOf] + amount;
        if (newDebt * BPS > OwnAToken(aToken).balanceOf(onBehalfOf) * ltvBps) {
            revert InsufficientCollateral(onBehalfOf);
        }

        debtOf[onBehalfOf] = newDebt;
        totalDebt += amount;

        // Exit-liquidity invariant makes an explicit liquidity check redundant:
        // aggregate LTV headroom never exceeds the pool balance (see
        // {InsufficientCollateral} NatSpec); SafeERC20 backstops regardless.
        IERC20(underlying).safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, onBehalfOf, amount);
    }

    /// @inheritdoc IAaveV3Pool
    function repay(
        address asset,
        uint256 amount,
        uint256, /*interestRateMode*/
        address onBehalfOf
    ) external override nonReentrant onlyKnownReserve(asset) returns (uint256) {
        uint256 outstanding = debtOf[onBehalfOf];
        // Aave V3 parity (error '39'): repaying with no outstanding debt reverts.
        if (outstanding == 0) revert NoDebtOfSelectedType();

        uint256 toRepay = amount > outstanding ? outstanding : amount;

        debtOf[onBehalfOf] = outstanding - toRepay;
        totalDebt -= toRepay;
        _pullExact(msg.sender, toRepay);

        emit Repaid(msg.sender, onBehalfOf, toRepay);
        return toRepay;
    }

    // ──────────────────────────────────────────────────────────
    //  Collateral flag (compatibility no-op)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IAaveV3Pool
    /// @dev Collateral is ALWAYS counted by this pool — the Aave footgun where
    ///      transferred aTokens are not auto-enabled as collateral does not exist
    ///      here. Kept as an event-emitting no-op so OwnVault's
    ///      `enableAaveCollateral` wiring works unchanged.
    function setUserUseReserveAsCollateral(
        address asset,
        bool useAsCollateral
    ) external override onlyKnownReserve(asset) {
        emit CollateralUseSet(msg.sender, useAsCollateral);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnLendingPool
    function setSupplierAllowed(address supplier, bool allowed) external override onlyAdmin {
        if (supplier == address(0)) revert ZeroAddress();
        supplierAllowed[supplier] = allowed;
        emit SupplierAllowedUpdated(supplier, allowed);
    }

    /// @inheritdoc IOwnLendingPool
    function setLtvConfig(uint256 ltvBps_, uint256 liquidationThresholdBps_) external override onlyAdmin {
        _validateLtvConfig(ltvBps_, liquidationThresholdBps_);
        ltvBps = ltvBps_;
        liquidationThresholdBps = liquidationThresholdBps_;
        emit LtvConfigUpdated(ltvBps_, liquidationThresholdBps_);
    }

    // ──────────────────────────────────────────────────────────
    //  aToken hook
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnLendingPool
    function validateTransfer(
        address from
    ) external view override {
        _requireHealthy(from);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnLendingPool
    function availableLiquidity() public view override returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    /// @inheritdoc IAaveV3Pool
    function getReserveData(
        address asset
    ) external view override onlyKnownReserve(asset) returns (ReserveDataLegacy memory data) {
        data.liquidityIndex = uint128(RAY);
        data.variableBorrowIndex = uint128(RAY);
        // Zero borrow rate by design: the whole lending rate lives in the
        // BorrowManager premium curve.
        data.currentVariableBorrowRate = 0;
        data.currentLiquidityRate = 0;
        data.lastUpdateTimestamp = uint40(block.timestamp);
        data.aTokenAddress = aToken;
        data.variableDebtTokenAddress = variableDebtToken;
    }

    /// @inheritdoc IAaveV3Pool
    function getUserAccountData(
        address user
    )
        external
        view
        override
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        uint256 collateral = OwnAToken(aToken).balanceOf(user);
        uint256 debt = debtOf[user];

        totalCollateralBase = _toBase(collateral);
        totalDebtBase = _toBase(debt);
        uint256 maxDebt = collateral.mulDiv(ltvBps, BPS);
        availableBorrowsBase = maxDebt > debt ? _toBase(maxDebt - debt) : 0;
        currentLiquidationThreshold = liquidationThresholdBps;
        ltv = ltvBps;
        healthFactor = debt == 0 ? type(uint256).max : collateral.mulDiv(liquidationThresholdBps * 1e18, debt * BPS);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Pull exactly `amount` of underlying from `from`, reverting on a balance
    ///      shortfall — fee-on-transfer tokens are unsupported by protocol policy.
    /// @param from   Account to pull from (must have approved this pool).
    /// @param amount Exact amount expected to arrive.
    function _pullExact(address from, uint256 amount) private {
        uint256 before = IERC20(underlying).balanceOf(address(this));
        IERC20(underlying).safeTransferFrom(from, address(this), amount);
        if (IERC20(underlying).balanceOf(address(this)) - before != amount) {
            revert FeeOnTransferNotSupported();
        }
    }

    /// @dev Revert unless `user`'s debt is covered by their aToken collateral at the
    ///      liquidation threshold (health factor >= 1). Called after withdrawals and
    ///      aToken transfers — the only sites where an account's health can decrease.
    /// @param user Account whose health is being validated.
    function _requireHealthy(
        address user
    ) private view {
        uint256 debt = debtOf[user];
        if (debt == 0) return;
        if (OwnAToken(aToken).balanceOf(user) * liquidationThresholdBps < debt * BPS) {
            revert HealthCheckFailed(user);
        }
    }

    /// @dev Convert underlying units to Aave base currency (1e8 = $1), assuming the
    ///      underlying is a $1 stablecoin. Used only for the informational `*Base`
    ///      fields of {getUserAccountData}; `healthFactor` never depends on it.
    /// @param amount Amount in underlying units.
    /// @return The value in Aave base currency (1e8 USD).
    function _toBase(
        uint256 amount
    ) private view returns (uint256) {
        return amount.mulDiv(BASE_CURRENCY_UNIT, 10 ** _underlyingDecimals);
    }

    /// @dev Shared LTV/LT bounds check: require 0 < ltv <= lt <= 100% (BPS).
    /// @param ltvBps_                  Proposed borrow LTV.
    /// @param liquidationThresholdBps_ Proposed liquidation threshold.
    function _validateLtvConfig(uint256 ltvBps_, uint256 liquidationThresholdBps_) private pure {
        if (ltvBps_ == 0 || ltvBps_ > liquidationThresholdBps_ || liquidationThresholdBps_ > BPS) {
            revert InvalidLtvConfig(ltvBps_, liquidationThresholdBps_);
        }
    }
}
