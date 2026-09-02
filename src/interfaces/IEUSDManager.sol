// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IEUSDManager — CDP engine for the eUSD stablecoin
/// @notice Custodies eToken collateral (eSPY at launch, extensible to other eTokens) and owns all
///         CDP logic: open/adjust positions, mint eUSD against a FRESH oracle price, repay/close,
///         keeper liquidation at a fixed bonus, and riskiest-first redemption (peg anchor).
///
///         Price-freshness asymmetry (mirrors the PSM, docs/psm-design.md §2): risk-increasing
///         actions (mint, collateral withdrawal against debt) require an in-session price no older
///         than `mintPriceMaxAge`; exits (repay, close, redeem, liquidate) work off-hours against
///         the last oracle anchor with no age bound, so no holder or keeper is ever blocked by a
///         market being closed. Collateral here is debtor collateral — never LP equity — so
///         redemptions transfer value only from the position owner whose debt they retire.
///
///         Positions with both debt and collateral are kept in a per-collateral sorted list ordered
///         by nominal ratio (collateral units per debt unit — price-invariant within one
///         collateral). The list head is the riskiest position; redemptions consume from the head.
///         A debt-only residual (an underwater position whose collateral was fully redeemed) stays
///         off-list until it is repaid, closed, liquidated or topped up. Ordering uses stored
///         (last-accrued) debt, so positions untouched for long periods are marginally riskier
///         than their list position implies — the drift is bounded by the stability fee rate.
///
///         A permanently halted asset (VaultManager.haltAsset) is valued at its fixed halt price
///         — the only value its eToken can still be redeemed for — and the feed is not consulted,
///         so exits never brick; mint and collateral withdrawal against debt are refused. The
///         same two actions are refused while the asset's trading is paused (leverage pauses
///         with trading, as in BorrowManager); exits are never gated on a pause.
///
///         Collateral is custodied by token address but priced by ticker, and ticker prices are
///         per active eToken unit. After an `AssetRegistry.migrateToken` split the held token
///         becomes legacy; the manager scales its price by `legacyRatioToActive` so every open
///         position keeps its pre-split USD value, and continues to hold and pay out the legacy
///         token. New positions open on the new active token once it is added as collateral.
///
///         The stability fee is a fixed annual rate, accrued lazily per position from a global
///         bps-seconds index (simple interest between touches). Accrued fees are added to position
///         debt and simultaneously minted as eUSD to the protocol treasury, preserving
///         `eusd.totalSupply() == Σ position debt` exactly.
interface IEUSDManager {
    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @notice Global risk parameters.
    /// @param mcrBps            Min collateral ratio to mint / withdraw collateral (BPS, e.g. 15000).
    /// @param liquidationThresholdBps Ratio below which a position is liquidatable (BPS, e.g. 13000).
    /// @param liquidationBonusBps Collateral bonus paid to the liquidator on top of repaid debt (BPS).
    /// @param stabilityFeeBps   Fixed annual stability fee on outstanding debt (BPS, simple interest).
    /// @param debtCeiling       Global cap on total eUSD debt (18 decimals).
    /// @param minDebt           Minimum debt per position after mint/repay (18 decimals).
    /// @param mintPriceMaxAge   Max oracle price age accepted for mint / withdraw (seconds). Bounds
    ///                          the timestamp the oracle *reports*: the Chainlink leg reports
    ///                          `block.timestamp` for any answer younger than its `clFreshWindow`
    ///                          (deviation-bounded while live), so the effective bound on that leg is
    ///                          `max(mintPriceMaxAge, clFreshWindow)`; the knob bites on the in-house
    ///                          leg and on Chainlink answers older than the window.
    struct RiskParams {
        uint16 mcrBps;
        uint16 liquidationThresholdBps;
        uint16 liquidationBonusBps;
        uint16 stabilityFeeBps;
        uint256 debtCeiling;
        uint256 minDebt;
        uint256 mintPriceMaxAge;
    }

    /// @notice Configuration of one supported collateral eToken.
    /// @param ticker  Asset ticker used for oracle lookups (e.g. bytes32("SPY")).
    /// @param enabled Whether new deposits/mints are accepted. Exits are never gated by this.
    /// @param exists  Whether the collateral has been added.
    struct CollateralConfig {
        bytes32 ticker;
        bool enabled;
        bool exists;
    }

    /// @notice A CDP position, keyed by (collateral token, owner).
    /// @param collateral       Collateral held (eToken units, 18 decimals).
    /// @param debt             eUSD debt including fees accrued up to `feeIndexSnapshot` (18 decimals).
    /// @param feeIndexSnapshot Global fee index (bps-seconds) at the last accrual.
    struct Position {
        uint256 collateral;
        uint256 debt;
        uint256 feeIndexSnapshot;
    }

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a collateral eToken is added.
    /// @param collateral Collateral eToken address.
    /// @param ticker     Oracle ticker bound to the collateral.
    event CollateralAdded(address indexed collateral, bytes32 indexed ticker);

    /// @notice Emitted when a collateral's enabled flag changes.
    /// @param collateral Collateral eToken address.
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
    /// @param collateral Collateral eToken.
    /// @param owner      Position owner.
    /// @param amount     Collateral added (18 decimals).
    event CollateralDeposited(address indexed collateral, address indexed owner, uint256 amount);

    /// @notice Emitted when collateral is withdrawn from a position.
    /// @param collateral Collateral eToken.
    /// @param owner      Position owner.
    /// @param amount     Collateral removed (18 decimals).
    event CollateralWithdrawn(address indexed collateral, address indexed owner, uint256 amount);

    /// @notice Emitted when eUSD is minted against a position.
    /// @param collateral Collateral eToken.
    /// @param owner      Position owner.
    /// @param amount     eUSD minted (18 decimals).
    /// @param newDebt    Position debt after the mint (18 decimals).
    event EUSDMinted(address indexed collateral, address indexed owner, uint256 amount, uint256 newDebt);

    /// @notice Emitted when position debt is repaid.
    /// @param collateral Collateral eToken.
    /// @param owner      Position owner.
    /// @param payer      Account whose eUSD was burned.
    /// @param amount     eUSD burned (18 decimals).
    /// @param newDebt    Position debt after the repay (18 decimals).
    event EUSDRepaid(
        address indexed collateral, address indexed owner, address indexed payer, uint256 amount, uint256 newDebt
    );

    /// @notice Emitted when a position is fully closed by its owner.
    /// @param collateral         Collateral eToken.
    /// @param owner              Position owner.
    /// @param collateralReturned Collateral returned to the owner (18 decimals).
    /// @param debtRepaid         eUSD burned to retire the debt (18 decimals).
    event PositionClosed(
        address indexed collateral, address indexed owner, uint256 collateralReturned, uint256 debtRepaid
    );

    /// @notice Emitted when collateral eToken dividends held by the manager are swept to the treasury.
    /// @param collateral  Collateral eToken whose rewards were claimed.
    /// @param rewardToken Reward token forwarded.
    /// @param amount      Amount forwarded (reward-token decimals).
    event CollateralRewardsSwept(address indexed collateral, address indexed rewardToken, uint256 amount);

    /// @notice Emitted when a position is liquidated.
    /// @param collateral         Collateral eToken.
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
    /// @param collateral       Collateral eToken.
    /// @param owner            Redeemed position owner.
    /// @param debtRepaid       Debt retired on this position (18 decimals).
    /// @param collateralSeized Collateral seized from this position (18 decimals).
    event RedeemedFromPosition(
        address indexed collateral, address indexed owner, uint256 debtRepaid, uint256 collateralSeized
    );

    /// @notice Emitted at the end of a redemption.
    /// @param collateral    Collateral eToken.
    /// @param redeemer      Account that burned eUSD.
    /// @param debtRepaid    Total eUSD burned (18 decimals).
    /// @param collateralOut Total collateral paid to the redeemer (18 decimals).
    event Redeemed(address indexed collateral, address indexed redeemer, uint256 debtRepaid, uint256 collateralOut);

    /// @notice Emitted when a position's pending stability fee is folded into its debt.
    /// @param collateral Collateral eToken.
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
    error CollateralNotSupported(address collateral);
    /// @notice The collateral token is disabled for new deposits/mints.
    error CollateralDisabled(address collateral);
    /// @notice The collateral token was already added.
    error CollateralAlreadySupported(address collateral);
    /// @notice Collateral eTokens must have 18 decimals.
    error InvalidCollateralDecimals(uint8 decimals);
    /// @notice The token is not a valid eToken for the ticker in the AssetRegistry.
    error TickerTokenMismatch(bytes32 ticker, address collateral);
    /// @notice The asset is permanently halted; only wind-down actions are allowed.
    error CollateralHalted(bytes32 ticker);
    /// @notice Trading in the asset is paused; mint and withdrawal against debt wait for resume.
    error CollateralPaused(bytes32 ticker);
    /// @notice The token is already a legacy (post-split) eToken; onboard the active token instead.
    error LegacyCollateral(address collateral);
    /// @notice Risk parameter bounds are inconsistent (see setters for the exact constraints).
    error InvalidRiskParams();
    /// @notice Minting is paused.
    error MintingPaused();
    /// @notice Oracle price is too old for a risk-increasing action (mint / withdraw).
    /// @param priceTimestamp Oracle price observation timestamp (unix seconds).
    /// @param maxAge         Max accepted age (seconds).
    error StaleMintPrice(uint256 priceTimestamp, uint256 maxAge);
    /// @notice Oracle returned a zero price.
    error ZeroOraclePrice(bytes32 ticker);
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
    error NoDebt(address collateral, address owner);
    /// @notice The position is empty (no collateral, no debt).
    error EmptyPosition(address collateral, address owner);
    /// @notice The position's ratio is at or above the liquidation threshold.
    /// @param ratioBps     Current ratio (BPS).
    /// @param thresholdBps Liquidation threshold (BPS).
    error PositionNotLiquidatable(uint256 ratioBps, uint256 thresholdBps);
    /// @notice The collateral eToken has no claimable rewards for the manager.
    error NoRewardsToSweep(address collateral);
    /// @notice No debt exists to redeem against for this collateral.
    error NothingToRedeem(address collateral);
    /// @notice Redemption returned less collateral than the caller's floor.
    /// @param collateralOut    Collateral the redemption produced (18 decimals).
    /// @param minCollateralOut Caller's floor (18 decimals).
    error SlippageExceeded(uint256 collateralOut, uint256 minCollateralOut);

    // ──────────────────────────────────────────────────────────
    //  Position management
    // ──────────────────────────────────────────────────────────

    /// @notice Deposit collateral into the caller's position. Always allowed while the collateral
    ///         is enabled; needs no oracle price (health only improves).
    /// @param collateral Collateral eToken to deposit.
    /// @param amount     Amount to deposit (18 decimals).
    /// @param hint       Sorted-list insert hint: the position owner expected to precede the
    ///                   caller's position after the update (address(0) = walk from the head).
    function deposit(address collateral, uint256 amount, address hint) external;

    /// @notice Withdraw collateral from the caller's position. If the position has debt, requires
    ///         a fresh oracle price (≤ mintPriceMaxAge) and the resulting ratio ≥ MCR — the same
    ///         gate as minting, since withdrawal is risk-increasing. Debt-free withdrawals need no
    ///         price and work off-hours.
    /// @param collateral Collateral eToken to withdraw.
    /// @param amount     Amount to withdraw (18 decimals).
    /// @param hint       Sorted-list insert hint (see {deposit}).
    function withdrawCollateral(address collateral, uint256 amount, address hint) external;

    /// @notice Mint eUSD against the caller's position, valued at the live oracle price. Requires
    ///         a fresh in-session price (≤ mintPriceMaxAge), resulting ratio ≥ MCR, resulting
    ///         position debt ≥ minDebt, and total debt ≤ debtCeiling. Reverts while paused.
    /// @param collateral Collateral eToken backing the mint.
    /// @param amount     eUSD to mint to the caller (18 decimals).
    /// @param hint       Sorted-list insert hint (see {deposit}).
    function mint(address collateral, uint256 amount, address hint) external;

    /// @notice Repay debt on any position; the eUSD is burned from the caller. Amounts above the
    ///         position's debt are capped to it. The remaining debt must be zero or ≥ minDebt.
    ///         Works off-hours — no oracle price involved.
    /// @param collateral Collateral eToken of the position.
    /// @param owner      Position owner (anyone may repay on an owner's behalf).
    /// @param amount     eUSD to burn from the caller (18 decimals, capped to the debt).
    /// @param hint       Sorted-list insert hint (see {deposit}).
    function repay(address collateral, address owner, uint256 amount, address hint) external;

    /// @notice Close the caller's position: burn its full debt (including pending fees) from the
    ///         caller and return all collateral. Needs no oracle price — the guaranteed off-hours
    ///         exit.
    /// @param collateral Collateral eToken of the position.
    function closePosition(
        address collateral
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Liquidation & redemption
    // ──────────────────────────────────────────────────────────

    /// @notice Liquidate a position whose ratio is below the liquidation threshold at the current
    ///         oracle anchor (no freshness bound — works off-hours). The caller burns up to
    ///         `amount` of the debt and receives collateral worth repaid × (1 + liquidationBonus),
    ///         capped at the position's collateral. A full close (amount ≥ debt) refunds any
    ///         surplus collateral to the owner and deletes the position; a partial leaves the
    ///         remainder in place, re-sorted, and must not drop the debt below `minDebt`. Partial
    ///         liquidation means a position can always be cleared in chunks, so no single debt
    ///         can exceed the eUSD any one liquidator can assemble. If the position is underwater
    ///         the caller absorbs the shortfall.
    /// @param collateral Collateral eToken of the position.
    /// @param owner      Position owner to liquidate.
    /// @param amount     Max eUSD debt to repay (type(uint256).max = full).
    /// @param hint       Sorted-list insert hint for the remainder (see {deposit}).
    function liquidate(address collateral, address owner, uint256 amount, address hint) external;

    /// @notice Redeem eUSD for collateral at the oracle anchor price — burn X eUSD, receive X
    ///         dollars' worth of collateral (rounded down), sourced from the riskiest positions
    ///         first (list head). The peg anchor: always available, no freshness bound, never
    ///         pausable. Each touched position's debt and collateral shrink at exactly 1:1 value,
    ///         so its ratio improves (deleveraging). An underwater head only redeems its
    ///         collateral-backed portion: the burn is capped at that collateral's value, the
    ///         unbacked debt residual stays on the owner's books off-list, and the walk continues.
    ///         A partial redemption may leave the last position below minDebt.
    /// @param collateral       Collateral eToken to redeem into.
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

    /// @notice Claim the dividends a collateral eToken has accrued to the manager (the holder of
    ///         record while eTokens sit as CDP collateral) and forward them to the protocol
    ///         treasury — the same rule as `OwnMarket.sweepDividends` and the borrow manager's
    ///         collateral-dividend sweep. Permissionless. Reverts if nothing is claimable.
    /// @param collateral Collateral eToken to sweep.
    /// @return amount Reward tokens forwarded.
    function sweepCollateralRewards(
        address collateral
    ) external returns (uint256 amount);

    // ──────────────────────────────────────────────────────────
    //  Admin (ADMIN role via ProtocolRegistry)
    // ──────────────────────────────────────────────────────────

    /// @notice Add a collateral eToken. The token must have 18 decimals and be a valid eToken for
    ///         `ticker` in the AssetRegistry (active or legacy). Enabled on add.
    /// @param collateral Collateral eToken address.
    /// @param ticker     Oracle ticker for valuations.
    function addCollateral(address collateral, bytes32 ticker) external;

    /// @notice Enable or disable new deposits/mints for a collateral. Exits are unaffected.
    /// @param collateral Collateral eToken address.
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

    /// @notice Set the global debt ceiling. Only gates new mints — fee accrual may exceed it.
    /// @param debtCeiling New ceiling (18 decimals).
    function setDebtCeiling(
        uint256 debtCeiling
    ) external;

    /// @notice Set the per-position minimum debt.
    /// @param minDebt New minimum (18 decimals).
    function setMinDebt(
        uint256 minDebt
    ) external;

    /// @notice Set the price freshness bound for mint / withdraw. Must be non-zero. See the
    ///         `RiskParams.mintPriceMaxAge` note: on the Chainlink leg the effective bound is
    ///         `max(mintPriceMaxAge, oracle clFreshWindow)`.
    /// @param mintPriceMaxAge New max age (seconds).
    function setMintPriceMaxAge(
        uint256 mintPriceMaxAge
    ) external;

    /// @notice Pause or unpause minting (OPERATOR — instant emergency brake). Deposits, repays,
    ///         closes, redemptions and liquidations are never pausable.
    /// @param paused New paused state.
    function setMintPaused(
        bool paused
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice The eUSD token this manager mints and burns.
    function eusd() external view returns (address);

    /// @notice Current global risk parameters.
    function riskParams() external view returns (RiskParams memory);

    /// @notice Configuration of a collateral token.
    /// @param collateral Collateral eToken address.
    function collateralConfig(
        address collateral
    ) external view returns (CollateralConfig memory);

    /// @notice Whether minting is currently paused.
    function mintPaused() external view returns (bool);

    /// @notice Total outstanding eUSD debt across all positions (18 decimals). Equals
    ///         eusd.totalSupply() at all times.
    function totalDebt() external view returns (uint256);

    /// @notice Total collateral held for a token across all positions (18 decimals). Equals the
    ///         manager's token balance absent direct transfers.
    /// @param collateral Collateral eToken address.
    function totalCollateral(
        address collateral
    ) external view returns (uint256);

    /// @notice A position's stored state (debt as of its last accrual).
    /// @param collateral Collateral eToken address.
    /// @param owner      Position owner.
    function getPosition(address collateral, address owner) external view returns (Position memory);

    /// @notice A position's live debt including pending (unaccrued) stability fees.
    /// @param collateral Collateral eToken address.
    /// @param owner      Position owner.
    function currentDebt(address collateral, address owner) external view returns (uint256);

    /// @notice A position's live collateral ratio in BPS at the current oracle anchor, using live
    ///         debt. Returns type(uint256).max for debt-free positions.
    /// @param collateral Collateral eToken address.
    /// @param owner      Position owner.
    function collateralRatioBps(address collateral, address owner) external view returns (uint256);

    /// @notice Whether a position can be liquidated right now (live ratio < threshold).
    /// @param collateral Collateral eToken address.
    /// @param owner      Position owner.
    function isLiquidatable(address collateral, address owner) external view returns (bool);

    /// @notice A position's nominal ratio — stored collateral × 1e18 / stored debt — the
    ///         sorted-list ordering key. Reverts for debt-free positions.
    /// @param collateral Collateral eToken address.
    /// @param owner      Position owner.
    function nominalRatio(address collateral, address owner) external view returns (uint256);

    /// @notice Riskiest position (lowest nominal ratio) for a collateral; address(0) if none.
    /// @param collateral Collateral eToken address.
    function listHead(
        address collateral
    ) external view returns (address);

    /// @notice Safest position (highest nominal ratio) for a collateral; address(0) if none.
    /// @param collateral Collateral eToken address.
    function listTail(
        address collateral
    ) external view returns (address);

    /// @notice Next (safer) position after `owner` in the sorted list; address(0) at the tail.
    /// @param collateral Collateral eToken address.
    /// @param owner      Position owner currently in the list.
    function listNext(address collateral, address owner) external view returns (address);

    /// @notice Previous (riskier) position before `owner`; address(0) at the head.
    /// @param collateral Collateral eToken address.
    /// @param owner      Position owner currently in the list.
    function listPrev(address collateral, address owner) external view returns (address);

    /// @notice Number of positions with debt for a collateral.
    /// @param collateral Collateral eToken address.
    function listSize(
        address collateral
    ) external view returns (uint256);

    /// @notice Off-chain helper: the owner whose node should precede a position with nominal
    ///         ratio `ratio` (address(0) = would become the new head). Walks the whole list.
    /// @param collateral Collateral eToken address.
    /// @param ratio      Nominal ratio of the position being (re)inserted (1e18 scale).
    function findInsertHint(address collateral, uint256 ratio) external view returns (address);

    /// @notice Global stability-fee index (bps-seconds), including time elapsed since the last
    ///         settlement.
    function globalFeeIndex() external view returns (uint256);
}
