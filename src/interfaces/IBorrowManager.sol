// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InterestRateModel} from "../libraries/InterestRateModel.sol";

/// @title IBorrowManager — Provider-neutral borrow-manager interface
/// @notice Borrowers post eTokens as collateral and borrow the protocol's stablecoin (e.g. USDC),
///         handed to the borrower. Each (borrower, asset) carries its own position. Liquidation is
///         signed-price gated and partial: the liquidator names a repay amount, capped by an
///         HF-gated close factor, and the bonus-based seize must fit the position's remaining
///         collateral.
///
///         Pooled per-asset eToken custody: the manager holds one balance of each eToken across all
///         borrowers; per-position bookkeeping tracks each borrower's share.
///
///         This interface is venue-neutral — it says nothing about where the loaned stablecoin
///         comes from. The current implementation (`BorrowManager`) sources it from Aave V3 via the
///         vault's credit delegation; a future Morpho or in-house manager can implement the same
///         interface with a different funding source.
interface IBorrowManager {
    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @notice A user's borrow position for one asset.
    /// @param eTokenCollateral Amount of the posted eToken (18 dec), in `collateralToken` units.
    /// @param principal        Scaled stablecoin debt; actual debt is
    ///                         `principal × index / PRECISION`.
    /// @param interestIndex    Snapshot of the manager's global interest index
    ///                         at the position's last touch (informational).
    /// @param collateralToken  The exact eToken posted. Snapshotted so a later migration does not
    ///                         strand the collateral; legacy collateral is valued at its split ratio.
    struct Position {
        uint256 eTokenCollateral;
        uint256 principal;
        uint256 interestIndex;
        address collateralToken;
    }

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    event Borrowed(
        address indexed borrower,
        bytes32 indexed asset,
        uint256 eTokenCollateral,
        uint256 stablecoinAmount,
        uint256 oraclePrice
    );
    event Repaid(
        address indexed borrower,
        bytes32 indexed asset,
        uint256 repayAmount,
        uint256 collateralReleased,
        uint256 remainingPrincipal
    );
    event Liquidated(
        address indexed borrower,
        bytes32 indexed asset,
        address indexed liquidator,
        uint256 repayAmount,
        uint256 collateralSeized,
        uint256 collateralReturnedToBorrower
    );
    event RateParamsUpdated(InterestRateModel.Params params);
    event LiquidationConfigUpdated(uint256 liquidationThresholdBps, uint256 liquidationBonusBps);
    event TargetLtvBpsUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when the admin changes whether borrowing against an asset is allowed on this
    ///         manager. Borrowing is enabled for every asset by default.
    /// @param asset      Asset ticker.
    /// @param borrowable True if borrowing against `asset` is now allowed.
    event AssetBorrowableUpdated(bytes32 indexed asset, bool borrowable);

    /// @notice Emitted when lending interest revenue (the premium charged above Aave's own rate)
    ///         is forwarded to the manager. The manager handles distribution offchain / via `shareYield`.
    /// @param manager The vault manager (operator) receiving the lending fee.
    /// @param amount  Stablecoin amount of accrued lending fee.
    event LendingFeeAccrued(address indexed manager, uint256 amount);
    event BadDebtAbsorbed(
        address indexed borrower,
        bytes32 indexed asset,
        address indexed caller,
        uint256 residualRepaid,
        uint256 treasuryAbsorbed,
        uint256 collateralReleased
    );

    /// @notice Emitted when a leveraged position is unwound during a permanent asset halt.
    /// @param borrower            Position owner.
    /// @param asset               Halted asset ticker.
    /// @param eTokenRedeemed      eToken collateral seized and redeemed at the halt price.
    /// @param debtRepaid          Stablecoin debt cleared from the proceeds.
    /// @param collateralReturned  eToken collateral returned to the borrower (excess over debt).
    event HaltPositionSettled(
        address indexed borrower,
        bytes32 indexed asset,
        uint256 eTokenRedeemed,
        uint256 debtRepaid,
        uint256 collateralReturned
    );

    /// @notice Emitted when dividends earned on pooled collateral during the borrow term are swept to
    ///         the vault manager as lending revenue.
    /// @param eToken      The eToken whose dividends were swept.
    /// @param beneficiary The vault manager receiving the dividends.
    /// @param amount      Reward tokens forwarded.
    event DividendsSwept(address indexed eToken, address indexed beneficiary, uint256 amount);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error OnlyAdmin();
    error AssetNotActive(bytes32 asset);
    error AssetNotBorrowable(bytes32 asset);
    error VaultEffectivelyHalted();
    error ETokenMismatch(address expected, address actual);
    error InsufficientCollateral(uint256 requested, uint256 maxAllowed);
    error PositionAlreadyOpen(address borrower, bytes32 asset);
    error NoPosition(address borrower, bytes32 asset);
    error NotLiquidatable(uint256 healthFactor);
    error InvalidLiquidationConfig();
    error InvalidLtv();
    error BorrowExceedsCap(uint256 attempted, uint256 cap);
    error SeizeExceedsCollateral(uint256 seize, uint256 available);
    error PositionStillCollateralized(uint256 collateral);
    error AssetNotHalted(bytes32 asset);
    error StalePrice(uint256 timestamp, uint256 maxAge);
    error NoDividendsToSweep();

    // ──────────────────────────────────────────────────────────
    //  Borrower flows
    // ──────────────────────────────────────────────────────────

    /// @notice Open a borrow position by depositing eTokens and borrowing stablecoins.
    /// @dev    Requires `(borrower, asset)` to have no open position.
    /// @param asset            Asset ticker (e.g. bytes32("TSLA")).
    /// @param eTokenAmount     eToken collateral to deposit (18 decimals).
    /// @param stablecoinAmount Stablecoin to borrow (in stablecoin decimals).
    /// @param priceData        Signed price proof verified via the asset's primary oracle.
    function borrow(
        bytes32 asset,
        uint256 eTokenAmount,
        uint256 stablecoinAmount,
        bytes calldata priceData
    ) external payable;

    /// @notice Repay outstanding debt for `(msg.sender, asset)`. Pass
    ///         `type(uint256).max` to fully close. Releases proportional
    ///         collateral on partial repay; full collateral on full repay.
    /// @return collateralReleased eToken units returned to the borrower.
    function repay(bytes32 asset, uint256 amount) external returns (uint256 collateralReleased);

    /// @notice Liquidate an underwater `(borrower, asset)` position.
    /// @dev    The liquidator names `repayAmount`; it is clamped to the
    ///         HF-gated close factor (a fraction of debt while the position is
    ///         only marginally unhealthy, lifted to the full debt once deeply
    ///         underwater). Receives eToken collateral of
    ///         `repayAmount * (1 + bonus) / oraclePrice`, which must fit within
    ///         the remaining collateral (reverts otherwise). A full repay closes
    ///         the position and returns any residual collateral to the borrower;
    ///         a partial repay leaves the position open.
    /// @param  borrower    Underwater position's borrower.
    /// @param  asset       Asset ticker.
    /// @param  repayAmount Stablecoin debt the liquidator wants to repay (pre-cap).
    /// @param  priceData   Signed price proof for `asset`.
    function liquidate(
        address borrower,
        bytes32 asset,
        uint256 repayAmount,
        bytes calldata priceData
    ) external payable;

    /// @notice Permissionless: advance the global interest index to the current block (and floor it
    ///         to the vault's real Aave debt). Lets a keeper keep book debt synced with Aave between
    ///         borrow / repay / liquidate touches, bounding the window where the model can lag.
    function accrue() external;

    /// @notice Close out the residual (zero-collateral) bad debt left after a
    ///         position's collateral has been fully liquidated. Admin-only.
    /// @dev    The caller fronts the *full* residual debt in stablecoin, which
    ///         repays the vault's matching Aave loan and clears the book debt.
    ///         `absorbAmount` is the slice of that loss the caller eats itself
    ///         (donated, no reimbursement); the remainder is socialized to LPs
    ///         and reimbursed to the caller in vault collateral (aToken) priced
    ///         via the vault's collateral oracle. `absorbAmount == residual`
    ///         means the caller absorbs everything (no collateral released);
    ///         `absorbAmount == 0` means LPs absorb everything.
    /// @param  borrower            Borrower whose residual debt is being closed.
    /// @param  asset               Asset ticker of the position.
    /// @param  absorbAmount        Stablecoin loss the caller eats (clamped to residual).
    /// @param  collateralPriceData Signed price proof for the vault's collateral asset.
    function absorbBadDebt(
        address borrower,
        bytes32 asset,
        uint256 absorbAmount,
        bytes calldata collateralPriceData
    ) external payable;

    /// @notice Unwind a leveraged position during a permanent asset halt. Seizes the eToken
    ///         collateral needed to cover the position's debt at the halt price, redeems it for
    ///         stablecoins via the market's halt redeem path, repays the vault's Aave debt, and
    ///         returns any excess collateral to the borrower. Callable by anyone (keeper, borrower,
    ///         or admin). If collateral cannot cover the debt, the shortfall remains as a
    ///         zero-collateral residual to be closed via {absorbBadDebt}.
    /// @param  borrower Position owner.
    /// @param  asset    Halted asset ticker.
    function settleHaltedPosition(address borrower, bytes32 asset) external;

    /// @notice Sweep dividends accrued on the manager's pooled collateral to the vault manager.
    /// @dev    Permissionless (keeper-friendly): the beneficiary is always the bound vault's manager,
    ///         so the destination is fixed. Dividends earned on collateral held during a borrow accrue
    ///         to the VM as lending revenue; this routes them there, mirroring the lending-premium
    ///         sweep. Reverts when the manager has no claimable dividends on `eToken`.
    /// @param  eToken The eToken (active or legacy) whose pooled dividends to sweep.
    /// @return amount Reward tokens forwarded to the vault manager.
    function sweepDividends(
        address eToken
    ) external returns (uint256 amount);

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice Vault bound to this manager.
    function vault() external view returns (address);

    /// @notice Stablecoin borrowed via this manager (e.g. USDC).
    function stablecoin() external view returns (address);

    /// @notice Interest rate curve parameters.
    function rateParams()
        external
        view
        returns (uint64 basePremiumBps, uint64 optimalUtilBps, uint64 slope1Bps, uint64 slope2Bps);

    /// @notice Liquidation threshold (BPS). Position is liquidatable when
    ///         `collateralValue * liquidationThreshold / 10000 < debt`.
    function liquidationThresholdBps() external view returns (uint256);

    /// @notice Liquidation bonus (BPS) paid out of collateral on liquidation.
    function liquidationBonusBps() external view returns (uint256);

    /// @notice Maximum loan-to-value at borrow time (BPS).
    function borrowLtvBps() external view returns (uint256);

    /// @notice Vault-wide target Aave LTV (BPS) backing the protocol debt cap.
    function targetLtvBps() external view returns (uint256);

    /// @notice Total outstanding protocol debt held by this manager, in USD
    ///         (18 decimals). Includes principal + accrued interest.
    function totalDebtUSD() external view returns (uint256);

    /// @notice Vault collateral value × `targetLtvBps` (USD, 18 decimals).
    function maxDebtUSD() external view returns (uint256);

    /// @notice Current utilization (BPS, capped at 10_000): `totalDebtUSD / maxDebtUSD`.
    function utilizationBps() external view returns (uint256);

    /// @notice The venue's base borrow rate for the stablecoin (BPS), before the protocol premium.
    ///         For the Aave-backed `BorrowManager` this is the live Aave variable borrow rate.
    function baseRateBps() external view returns (uint256);

    /// @notice Per-position view. Returns zero for unopened positions.
    function positionOf(address borrower, bytes32 asset) external view returns (Position memory);

    /// @notice Current debt (principal + accrued interest) for a position.
    function debtOf(address borrower, bytes32 asset) external view returns (uint256);

    /// @notice Current health factor (1e18 = 1.0). Positions with no debt
    ///         return `type(uint256).max`.
    function healthFactor(address borrower, bytes32 asset, uint256 oraclePrice) external view returns (uint256);

    /// @notice Whether borrowing against `asset` is currently enabled on this manager. True by
    ///         default; false only for assets the admin has explicitly disabled.
    function isAssetBorrowable(
        bytes32 asset
    ) external view returns (bool);

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    function setRateParams(
        InterestRateModel.Params calldata params
    ) external;

    function setLiquidationConfig(uint256 liquidationThresholdBps_, uint256 liquidationBonusBps_) external;

    /// @notice Set the vault-wide target Aave LTV (BPS) backing the debt cap. Must be < 10_000.
    function setTargetLtvBps(
        uint256 ltvBps
    ) external;

    /// @notice Enable or disable borrowing against `asset` on this manager. Admin-only. Borrowing is
    ///         enabled for every asset by default; this only needs calling to disable (or re-enable) a
    ///         specific asset. Keyed by ticker so the setting survives stock-split token migrations.
    /// @param asset      Asset ticker.
    /// @param borrowable True to allow borrowing against `asset`, false to block it.
    function setAssetBorrowable(bytes32 asset, bool borrowable) external;
}
