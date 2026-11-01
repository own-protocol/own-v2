// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IEUSDManager — CDP engine for the eUSD stablecoin
/// @notice Overcollateralized eUSD minting against tokenized assets (Robinhood stock tokens, WETH).
///         One manager runs per collateral risk group, and every manager mints the same eUSD.
///         Covers deposits and withdrawals, minting, repay and close, keeper liquidation at a fixed
///         bonus, and riskiest-first redemption, which anchors the peg.
///
///         Price freshness: mint, withdrawal against debt, redemption and the fee leg of a
///         principal-only close need a price no older than `mintPriceMaxAge`. Repay and
///         {closePosition} need no price, and liquidation uses the latest oracle price with no age
///         bound, so a debtor can always exit and an unsafe position can always be cleared while a
///         market is closed.
///
///         Positions with both debt and collateral sit in a per-collateral list sorted by nominal
///         ratio (collateral units per debt unit, which is price-invariant within one collateral).
///         The head is the riskiest position; redemptions consume from the head. A debt-only
///         residual (an underwater position whose collateral was fully redeemed) stays off the list
///         until it is repaid, closed, liquidated or topped up. Ordering uses stored debt, so a
///         position untouched for a long time is slightly riskier than its place implies.
///
///         Each collateral is priced by the oracle ticker set when it is added, per token unit.
///         Disabling a collateral stops new exposure; exits are never gated.
///
///         The stability fee is a fixed annual rate charged on principal (`debt - feesAccrued`) as
///         simple interest, accrued lazily from a global index. Accrued fees are added to the
///         position's debt and minted to the treasury, so eUSD supply equals the sum of every
///         manager's `totalDebt`.
interface IEUSDManager {
    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @notice Risk parameters of this manager.
    /// @param mcrBps                  Min collateral ratio to mint or withdraw against debt (BPS).
    /// @param liquidationThresholdBps Ratio below which a position is liquidatable (BPS).
    /// @param liquidationBonusBps     Collateral bonus paid to the liquidator on top of repaid debt (BPS).
    /// @param stabilityFeeBps         Annual stability fee on principal (BPS, simple interest).
    /// @param debtCeiling             Cap on this manager's total debt (18 decimals).
    /// @param minDebt                 Minimum debt of a position with debt (18 decimals).
    /// @param mintPriceMaxAge         Max age of the oracle price for actions that need a fresh price
    ///                                (seconds). Applies to the timestamp the oracle reports, so on
    ///                                the Chainlink leg the effective bound is
    ///                                `max(mintPriceMaxAge, clFreshWindow)`.
    struct RiskParams {
        uint16 mcrBps;
        uint16 liquidationThresholdBps;
        uint16 liquidationBonusBps;
        uint16 stabilityFeeBps;
        uint256 debtCeiling;
        uint256 minDebt;
        uint256 mintPriceMaxAge;
    }

    /// @notice Configuration of one supported collateral token.
    /// @param ticker  Asset ticker used for oracle lookups (e.g. bytes32("SPY")).
    /// @param enabled Whether new deposits/mints are accepted. Exits are never gated by this.
    /// @param exists  Whether the collateral has been added.
    struct CollateralConfig {
        bytes32 ticker;
        bool enabled;
        bool exists;
    }

    /// @notice A CDP position, keyed by (collateral token, owner).
    /// @param collateral       Collateral held (token units, 18 decimals).
    /// @param debt             eUSD debt including fees accrued up to `feeIndexSnapshot` (18 decimals).
    /// @param feeIndexSnapshot Global fee index (bps-seconds) at the last accrual.
    /// @param feesAccrued      Stability fees folded into `debt` and not yet repaid (18 decimals).
    ///                         Every debt reduction retires these fees first. Bounds the fee portion
    ///                         settleable from collateral in {closePositionPrincipalOnly}.
    struct Position {
        uint256 collateral;
        uint256 debt;
        uint256 feeIndexSnapshot;
        uint256 feesAccrued;
    }

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a collateral token is added.
    /// @param collateral Collateral token address.
    /// @param ticker     Oracle ticker bound to the collateral.
    event CollateralAdded(address indexed collateral, bytes32 indexed ticker);

    /// @notice Emitted when a collateral's enabled flag changes.
    /// @param collateral Collateral token address.
    /// @param enabled    New enabled state.
    event CollateralEnabledSet(address indexed collateral, bool enabled);

    /// @notice Emitted when the ratio risk parameters change.
    /// @param mcrBps                  New min collateral ratio (BPS).
    /// @param liquidationThresholdBps New liquidation threshold (BPS).
    /// @param liquidationBonusBps     New liquidation bonus (BPS).
    event RiskParamsSet(uint16 mcrBps, uint16 liquidationThresholdBps, uint16 liquidationBonusBps);

    /// @notice Emitted when the annual stability fee changes.
    /// @param stabilityFeeBps New annual fee (BPS).
    event StabilityFeeSet(uint16 stabilityFeeBps);

    /// @notice Emitted when the global debt ceiling changes.
    /// @param debtCeiling New ceiling (18 decimals).
    event DebtCeilingSet(uint256 debtCeiling);

    /// @notice Emitted when the per-position minimum debt changes.
    /// @param minDebt New minimum (18 decimals).
    event MinDebtSet(uint256 minDebt);

    /// @notice Emitted when the mint price freshness bound changes.
    /// @param mintPriceMaxAge New max age (seconds).
    event MintPriceMaxAgeSet(uint256 mintPriceMaxAge);

    /// @notice Emitted when minting is paused or unpaused (emergency brake; exits unaffected).
    /// @param paused New paused state.
    event MintPausedSet(bool paused);

    /// @notice Emitted when collateral is deposited into a position.
    /// @param collateral Collateral token.
    /// @param owner      Position owner.
    /// @param amount     Collateral added (18 decimals).
    event CollateralDeposited(address indexed collateral, address indexed owner, uint256 amount);

    /// @notice Emitted when collateral is withdrawn from a position.
    /// @param collateral Collateral token.
    /// @param owner      Position owner.
    /// @param amount     Collateral removed (18 decimals).
    event CollateralWithdrawn(address indexed collateral, address indexed owner, uint256 amount);

    /// @notice Emitted when eUSD is minted against a position.
    /// @param collateral Collateral token.
    /// @param owner      Position owner.
    /// @param amount     eUSD minted (18 decimals).
    /// @param newDebt    Position debt after the mint (18 decimals).
    event EUSDMinted(address indexed collateral, address indexed owner, uint256 amount, uint256 newDebt);

    /// @notice Emitted when position debt is repaid.
    /// @param collateral Collateral token.
    /// @param owner      Position owner.
    /// @param payer      Account whose eUSD was burned.
    /// @param amount     eUSD burned (18 decimals).
    /// @param newDebt    Position debt after the repay (18 decimals).
    event EUSDRepaid(
        address indexed collateral, address indexed owner, address indexed payer, uint256 amount, uint256 newDebt
    );

    /// @notice Emitted when a position is fully closed by its owner.
    /// @param collateral         Collateral token.
    /// @param owner              Position owner.
    /// @param collateralReturned Collateral returned to the owner (18 decimals).
    /// @param debtRepaid         eUSD burned to retire the debt (18 decimals).
    event PositionClosed(
        address indexed collateral, address indexed owner, uint256 collateralReturned, uint256 debtRepaid
    );

    /// @notice Emitted when a position close settles its accrued fees from collateral.
    /// @param collateral    Collateral token.
    /// @param owner         Position owner.
    /// @param feesSettled   Fee debt retired by burning the treasury's eUSD (18 decimals).
    /// @param feeCollateral Collateral transferred to the treasury in exchange (18 decimals).
    event PositionFeesSettledFromCollateral(
        address indexed collateral, address indexed owner, uint256 feesSettled, uint256 feeCollateral
    );

    /// @notice Emitted when a position is liquidated.
    /// @param collateral         Collateral token.
    /// @param owner              Position owner.
    /// @param liquidator         Keeper that repaid the debt.
    /// @param debtRepaid         eUSD burned from the liquidator (18 decimals).
    /// @param collateralSeized   Collateral paid to the liquidator (18 decimals).
    /// @param collateralReturned Surplus collateral returned to the owner (18 decimals).
    event PositionLiquidated(
        address indexed collateral,
        address indexed owner,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized,
        uint256 collateralReturned
    );

    /// @notice Emitted once per position touched by a redemption.
    /// @param collateral       Collateral token.
    /// @param owner            Redeemed position owner.
    /// @param debtRepaid       Debt retired on this position (18 decimals).
    /// @param collateralSeized Collateral seized from this position (18 decimals).
    event RedeemedFromPosition(
        address indexed collateral, address indexed owner, uint256 debtRepaid, uint256 collateralSeized
    );

    /// @notice Emitted at the end of a redemption.
    /// @param collateral    Collateral token.
    /// @param redeemer      Account that burned eUSD.
    /// @param debtRepaid    Total eUSD burned (18 decimals).
    /// @param collateralOut Total collateral paid to the redeemer (18 decimals).
    event Redeemed(address indexed collateral, address indexed redeemer, uint256 debtRepaid, uint256 collateralOut);

    /// @notice Emitted when a position's pending stability fee is folded into its debt.
    /// @param collateral Collateral token.
    /// @param owner      Position owner.
    /// @param fee        Fee added to debt and minted to the treasury (18 decimals).
    event StabilityFeeAccrued(address indexed collateral, address indexed owner, uint256 fee);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice A required address was the zero address.
    error ZeroAddress();
    /// @notice A required amount was zero.
    error ZeroAmount();
    /// @notice Caller is not the admin.
    error OnlyAdmin();
    /// @notice Caller is not the operator.
    error OnlyOperator();
    /// @notice The collateral token has not been added.
    /// @param collateral Collateral token.
    error CollateralNotSupported(address collateral);
    /// @notice The collateral token is disabled for new positions and minting. Existing debtors
    ///         may still top up collateral.
    /// @param collateral Collateral token.
    error CollateralDisabled(address collateral);
    /// @notice The collateral token was already added.
    /// @param collateral Collateral token.
    error CollateralAlreadySupported(address collateral);
    /// @notice Collateral tokens must have 18 decimals.
    /// @param decimals The token's decimals.
    error InvalidCollateralDecimals(uint8 decimals);
    /// @notice Risk parameter bounds are inconsistent (see setters for the exact constraints).
    error InvalidRiskParams();
    /// @notice Minting (and collateral withdrawal against debt) is paused.
    error MintingPaused();
    /// @notice The oracle price is older than `mintPriceMaxAge`.
    /// @param priceTimestamp Oracle price observation timestamp (unix seconds).
    /// @param maxAge         Max accepted age (seconds).
    error StaleMintPrice(uint256 priceTimestamp, uint256 maxAge);
    /// @notice Position debt would end below the minimum.
    /// @param debt    Resulting debt (18 decimals).
    /// @param minDebt Required minimum (18 decimals).
    error BelowMinimumDebt(uint256 debt, uint256 minDebt);
    /// @notice The global debt ceiling would be exceeded.
    /// @param totalDebt Resulting total debt (18 decimals).
    /// @param ceiling   The ceiling (18 decimals).
    error DebtCeilingExceeded(uint256 totalDebt, uint256 ceiling);
    /// @notice Position collateral ratio would fall below the MCR.
    /// @param ratioBps Resulting ratio (BPS).
    /// @param mcrBps   Required minimum (BPS).
    error CollateralRatioTooLow(uint256 ratioBps, uint256 mcrBps);
    /// @notice Withdrawal exceeds the position's collateral.
    /// @param requested Requested amount (18 decimals).
    /// @param available Position collateral (18 decimals).
    error InsufficientCollateral(uint256 requested, uint256 available);
    /// @notice The position has no debt.
    /// @param collateral Collateral token.
    /// @param owner      Position owner.
    error NoDebt(address collateral, address owner);
    /// @notice The position is empty (no collateral, no debt).
    /// @param collateral Collateral token.
    /// @param owner      Position owner.
    error EmptyPosition(address collateral, address owner);
    /// @notice The position's ratio is at or above the liquidation threshold.
    /// @param ratioBps     Current ratio (BPS).
    /// @param thresholdBps Liquidation threshold (BPS).
    error PositionNotLiquidatable(uint256 ratioBps, uint256 thresholdBps);
    /// @notice No debt exists to redeem against for this collateral.
    /// @param collateral Collateral token.
    error NothingToRedeem(address collateral);
    /// @notice Redemption returned less collateral than the caller's floor.
    /// @param collateralOut    Collateral the redemption produced (18 decimals).
    /// @param minCollateralOut Caller's floor (18 decimals).
    error SlippageExceeded(uint256 collateralOut, uint256 minCollateralOut);

    // ──────────────────────────────────────────────────────────
    //  Position management
    // ──────────────────────────────────────────────────────────

    /// @notice Deposit collateral into the caller's position. Needs no oracle price (health only
    ///         improves). While the collateral is disabled only existing debtors may deposit (a
    ///         defensive top-up); a debt-free caller cannot open new exposure.
    /// @param collateral Collateral token to deposit.
    /// @param amount     Amount to deposit (18 decimals).
    /// @param hint       Sorted-list insert hint: the position owner expected to precede the
    ///                   caller's position after the update (address(0) = walk from the head).
    function deposit(address collateral, uint256 amount, address hint) external;

    /// @notice Withdraw collateral from the caller's position. With debt, this has the same gates
    ///         as minting: not paused, a fresh price and a resulting ratio ≥ MCR. Debt-free
    ///         withdrawals need no price.
    /// @param collateral Collateral token to withdraw.
    /// @param amount     Amount to withdraw (18 decimals).
    /// @param hint       Sorted-list insert hint (see {deposit}).
    function withdrawCollateral(address collateral, uint256 amount, address hint) external;

    /// @notice Mint eUSD against the caller's position. Requires a fresh price, a resulting ratio
    ///         ≥ MCR, resulting debt ≥ minDebt and total debt ≤ debtCeiling. Reverts while paused or
    ///         while the collateral is disabled.
    /// @param collateral Collateral token backing the mint.
    /// @param amount     eUSD to mint to the caller (18 decimals).
    /// @param hint       Sorted-list insert hint (see {deposit}).
    function mint(address collateral, uint256 amount, address hint) external;

    /// @notice Repay debt on any position; the eUSD is burned from the caller. Amounts above the
    ///         position's debt are capped to it. The remaining debt must be zero or ≥ minDebt.
    ///         Needs no oracle price.
    /// @param collateral Collateral token of the position.
    /// @param owner      Position owner (anyone may repay on an owner's behalf).
    /// @param amount     eUSD to burn from the caller (18 decimals, capped to the debt).
    /// @param hint       Sorted-list insert hint (see {deposit}).
    function repay(address collateral, address owner, uint256 amount, address hint) external;

    /// @notice Close the caller's position: burn its full debt (including pending fees) from the
    ///         caller and return all collateral. Needs no oracle price, so it always works.
    /// @param collateral Collateral token of the position.
    function closePosition(
        address collateral
    ) external;

    /// @notice Close the caller's position paying only the principal in eUSD, so a debtor who
    ///         minted X never needs more than X eUSD to exit. Accrued fees (up to `feesAccrued`) are
    ///         settled by sending collateral of equal value, rounded against the owner, to the
    ///         treasury and burning the same amount of eUSD from the treasury. With fees to settle
    ///         it needs a fresh price, and it reverts if the treasury's eUSD balance cannot cover
    ///         the burn; {closePosition} always works instead.
    /// @param collateral Collateral token of the position.
    function closePositionPrincipalOnly(
        address collateral
    ) external;

    /// @notice Fold any position's pending stability fee into its debt, mint it to the treasury and
    ///         re-sort the position. Permissionless bookkeeping: it never changes what a position
    ///         owes. Reverts on a debt-free position. Needs no oracle price.
    /// @param collateral Collateral token of the position.
    /// @param owner      Position owner.
    /// @param hint       Sorted-list insert hint (see {deposit}).
    function accrue(address collateral, address owner, address hint) external;

    // ──────────────────────────────────────────────────────────
    //  Liquidation & redemption
    // ──────────────────────────────────────────────────────────

    /// @notice Liquidate a position whose ratio is below the liquidation threshold at the latest
    ///         oracle price (no age bound). The caller burns up to `amount` of the debt and receives
    ///         collateral worth repaid × (1 + bonus), capped at the position's collateral. A full
    ///         liquidation refunds any surplus collateral to the owner and deletes the position. A
    ///         partial one must leave at least `minDebt` and is also capped at the pro-rata share
    ///         `collateral × repaid / debt`, so the remaining position's ratio never worsens.
    ///         Partial liquidation lets any position be cleared in chunks.
    /// @param collateral Collateral token of the position.
    /// @param owner      Position owner to liquidate.
    /// @param amount     Max eUSD debt to repay (type(uint256).max = full).
    /// @param hint       Sorted-list insert hint for the remainder (see {deposit}).
    function liquidate(address collateral, address owner, uint256 amount, address hint) external;

    /// @notice Redeem eUSD for collateral at the oracle price: burn X eUSD and receive X dollars of
    ///         collateral (rounded down), taken from the riskiest positions first. Never pausable,
    ///         but needs a fresh price. Each touched position loses debt and collateral of equal
    ///         value, so its ratio improves. An underwater position only redeems its collateral
    ///         value; the unbacked residual stays on the owner's books off the list. The last
    ///         position touched is left at zero or at least `minDebt`, so `debtRepaid` can be up to
    ///         `minDebt` short of `amount`.
    /// @param collateral       Collateral token to redeem into.
    /// @param amount           Max eUSD to burn from the caller (18 decimals).
    /// @param minCollateralOut Min collateral acceptable for the burned amount (18 decimals).
    /// @param maxPositions     Max positions to touch (0 = unlimited).
    /// @param hint             Insert hint for re-sorting the final, partially-redeemed position.
    /// @return collateralOut Collateral transferred to the caller (18 decimals).
    /// @return debtRepaid    eUSD actually burned (≤ amount; 18 decimals).
    function redeem(
        address collateral,
        uint256 amount,
        uint256 minCollateralOut,
        uint256 maxPositions,
        address hint
    ) external returns (uint256 collateralOut, uint256 debtRepaid);

    // ──────────────────────────────────────────────────────────
    //  Admin (ADMIN role via ProtocolRegistry)
    // ──────────────────────────────────────────────────────────

    /// @notice Add a collateral token, enabled. The token must have 18 decimals and `ticker` must
    ///         be priced by the oracle.
    /// @param collateral Collateral token address.
    /// @param ticker     Oracle ticker for valuations.
    function addCollateral(address collateral, bytes32 ticker) external;

    /// @notice Enable or disable new exposure for a collateral: first deposits and all minting.
    ///         Existing debtors may still top up, and exits are unaffected.
    /// @param collateral Collateral token address.
    /// @param enabled    New enabled state.
    function setCollateralEnabled(address collateral, bool enabled) external;

    /// @notice Set the ratio parameters. Requires mcr ≥ liquidationThreshold ≥ BPS + bonus, so a
    ///         fresh mint is never instantly liquidatable and a threshold liquidation is solvent.
    /// @param mcrBps                  Min collateral ratio (BPS).
    /// @param liquidationThresholdBps Liquidation threshold (BPS).
    /// @param liquidationBonusBps     Liquidator bonus (BPS).
    function setRiskParams(uint16 mcrBps, uint16 liquidationThresholdBps, uint16 liquidationBonusBps) external;

    /// @notice Set the annual stability fee (≤ BPS). Settles the global fee index first, so the
    ///         new rate applies only prospectively.
    /// @param stabilityFeeBps New annual fee (BPS).
    function setStabilityFee(
        uint16 stabilityFeeBps
    ) external;

    /// @notice Set this manager's debt ceiling. Only gates new mints; fee accrual may exceed it.
    /// @param debtCeiling New ceiling (18 decimals).
    function setDebtCeiling(
        uint256 debtCeiling
    ) external;

    /// @notice Set the per-position minimum debt.
    /// @param minDebt New minimum (18 decimals).
    function setMinDebt(
        uint256 minDebt
    ) external;

    /// @notice Set the price age bound for actions that need a fresh price. Must be nonzero. See
    ///         {RiskParams}.
    /// @param mintPriceMaxAge New max age (seconds).
    function setMintPriceMaxAge(
        uint256 mintPriceMaxAge
    ) external;

    /// @notice Pause or unpause minting and withdrawal against debt (OPERATOR). Deposits, repays,
    ///         closes, redemptions and liquidations are never paused.
    /// @param paused New paused state.
    function setMintPaused(
        bool paused
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice The eUSD token this manager mints and burns.
    /// @return eUSD token address.
    function eusd() external view returns (address);

    /// @notice Current risk parameters.
    /// @return The risk parameters.
    function riskParams() external view returns (RiskParams memory);

    /// @notice Configuration of a collateral token.
    /// @param collateral Collateral token address.
    /// @return The collateral's configuration.
    function collateralConfig(
        address collateral
    ) external view returns (CollateralConfig memory);

    /// @notice Whether minting is currently paused.
    /// @return Whether minting is paused.
    function mintPaused() external view returns (bool);

    /// @notice Total outstanding eUSD debt across this manager's positions (18 decimals). eUSD supply
    ///         equals the sum of this value over every manager.
    /// @return Total debt (18 decimals).
    function totalDebt() external view returns (uint256);

    /// @notice Total collateral held for a token across all positions (18 decimals). Equals the
    ///         manager's token balance, excluding direct transfers.
    /// @param collateral Collateral token address.
    /// @return Total collateral (18 decimals).
    function totalCollateral(
        address collateral
    ) external view returns (uint256);

    /// @notice A position's stored state (debt as of its last accrual).
    /// @param collateral Collateral token address.
    /// @param owner      Position owner.
    /// @return The stored position.
    function getPosition(address collateral, address owner) external view returns (Position memory);

    /// @notice A position's live debt including pending (unaccrued) stability fees.
    /// @param collateral Collateral token address.
    /// @param owner      Position owner.
    /// @return Live debt (18 decimals).
    function currentDebt(address collateral, address owner) external view returns (uint256);

    /// @notice A position's live collateral ratio in BPS at the current oracle price, using live
    ///         debt. Returns type(uint256).max for debt-free positions.
    /// @param collateral Collateral token address.
    /// @param owner      Position owner.
    /// @return Ratio in BPS.
    function collateralRatioBps(address collateral, address owner) external view returns (uint256);

    /// @notice Whether a position can be liquidated right now (live ratio < threshold).
    /// @param collateral Collateral token address.
    /// @param owner      Position owner.
    /// @return Whether the position is liquidatable.
    function isLiquidatable(address collateral, address owner) external view returns (bool);

    /// @notice A position's nominal ratio — stored collateral × 1e18 / stored debt — the
    ///         sorted-list ordering key. Reverts for debt-free positions.
    /// @param collateral Collateral token address.
    /// @param owner      Position owner.
    /// @return Nominal ratio (1e18 scale).
    function nominalRatio(address collateral, address owner) external view returns (uint256);

    /// @notice Riskiest position (lowest nominal ratio) for a collateral; address(0) if none.
    /// @param collateral Collateral token address.
    /// @return Owner of the head position.
    function listHead(
        address collateral
    ) external view returns (address);

    /// @notice Safest position (highest nominal ratio) for a collateral; address(0) if none.
    /// @param collateral Collateral token address.
    /// @return Owner of the tail position.
    function listTail(
        address collateral
    ) external view returns (address);

    /// @notice Next (safer) position after `owner` in the sorted list; address(0) at the tail.
    /// @param collateral Collateral token address.
    /// @param owner      Position owner currently in the list.
    /// @return The next owner.
    function listNext(address collateral, address owner) external view returns (address);

    /// @notice Previous (riskier) position before `owner`; address(0) at the head.
    /// @param collateral Collateral token address.
    /// @param owner      Position owner currently in the list.
    /// @return The previous owner.
    function listPrev(address collateral, address owner) external view returns (address);

    /// @notice Number of listed positions (debt and collateral) for a collateral.
    /// @param collateral Collateral token address.
    /// @return Number of listed positions.
    function listSize(
        address collateral
    ) external view returns (uint256);

    /// @notice Off-chain helper: the owner that should precede a position with nominal ratio
    ///         `ratio` (address(0) = new head). Walks the list from the head.
    /// @param collateral Collateral token address.
    /// @param ratio      Nominal ratio of the position being (re)inserted (1e18 scale).
    /// @return The owner to pass as `hint`.
    function findInsertHint(address collateral, uint256 ratio) external view returns (address);

    /// @notice Global stability-fee index (bps-seconds), including time elapsed since the last
    ///         settlement.
    /// @return Fee index (BPS × seconds).
    function globalFeeIndex() external view returns (uint256);
}
