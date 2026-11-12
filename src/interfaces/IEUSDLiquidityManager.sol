// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IEUSDLiquidityManager — eUSD minted into DEX liquidity
/// @notice A CDP engine whose collateral is an asset/eUSD liquidity position. A user brings the
///         asset, the manager mints eUSD against it, and both go into a liquidity range on a DEX
///         pool. Minted eUSD only ever goes into the pool; it is never paid to the user's wallet.
///         One manager runs per volatility group, holds pools from any DEX, and mints the same eUSD
///         as the other managers.
///
///         Each (pool, owner) position lives in its own vault ({ILiquidityVault}), a beacon proxy
///         created on first use. The vault holds the liquidity plus idle asset and eUSD; the
///         manager tracks only the debt.
///
///         Valuation: the liquidity is valued at the oracle price, as the amounts the range would
///         hold if the pool traded at that price, plus idle balances, with eUSD at $1. For a
///         concentrated-liquidity range, what the liquidity actually holds at any pool price is
///         worth at least that much at the oracle price, so pool manipulation cannot make a
///         position look safer than it is.
///
///         eUSD the vault receives (when liquidity is removed or moved) is burned against the debt
///         straight away, leaving either no debt or at least `minDebt`; any surplus goes to the
///         owner once the debt is zero.
///
///         Health rule after a liquidity change: when the debt grew, minting must be open, the price
///         fresh, the debt within the ceiling and at least `minDebt`, and the ratio at least MCR.
///         Otherwise a ratio below MCR must not fall. Adding and moving liquidity also need the pool
///         price within `poolPriceBandBps` of the oracle, which protects the user from adding into a
///         stale or sandwiched pool.
///
///         Rebalancing: the owner, or the delegate the owner names on the vault, can move the range
///         and, on the way, swap the vault's asset for eUSD or back at no worse than the oracle
///         price less `poolPriceBandBps`. eUSD the swap brings in is burned against the debt like any
///         other. A delegate can never move tokens out of the vault.
///
///         Two stability fees: one for staked liquidity (which earns DEX emissions) and a lower one
///         for unstaked liquidity. The fee is simple interest on principal, minted to the treasury.
///
///         Exits need no fresh price: repay and close use no price, and liquidation uses the latest
///         oracle price with no age bound. Liquidation can be partial: clearing part of the debt
///         removes the same share of the range, its eUSD is burned against the debt, the liquidator
///         burns the rest of the cleared debt and receives asset worth that plus the bonus on all of
///         the cleared debt. A partial liquidation takes at most the cleared share of the position's
///         value. The remaining range stays in place (and staked); a full liquidation sends
///         everything left to the owner.
///
///         Redemption gives eUSD a floor: anyone burns eUSD for asset worth the same at the oracle
///         price, less `redeemFeeBps`, taken from positions they name. Only positions whose vault is
///         mostly asset at the pool price (out of range or near it, on the asset side) can be
///         redeemed; the owner's debt falls by the eUSD burned and the fee stays in their vault, so
///         their value does not fall and their ratio rises.
interface IEUSDLiquidityManager {
    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @notice Risk parameters of this manager.
    /// @param mcrBps                  Min collateral ratio after a debt increase or withdrawal (BPS).
    /// @param liquidationThresholdBps Ratio below which a position is liquidatable (BPS).
    /// @param liquidationBonusBps     Bonus paid to the liquidator on the debt it repays (BPS).
    /// @param stakedFeeBps            Annual stability fee while the liquidity is staked (BPS).
    /// @param unstakedFeeBps          Annual stability fee while the liquidity is unstaked (BPS).
    /// @param poolPriceBandBps        Max gap between pool and oracle price to add or move liquidity,
    ///                                and most a rebalance swap may return below its oracle value (BPS).
    /// @param debtCeiling             Cap on this manager's total debt (18 decimals).
    /// @param minDebt                 Minimum debt of a position with debt (18 decimals).
    /// @param mintPriceMaxAge         Max oracle price age for a debt increase or withdrawal (seconds).
    /// @param redeemMinAssetShareBps  Least share of a vault's value, at the pool price, that must be
    ///                                asset for the position to be redeemable (BPS); 0 turns
    ///                                redemption off.
    /// @param redeemFeeBps            Share of a redemption's asset kept in the owner's vault (BPS,
    ///                                below 10,000). Covers the oracle's lag behind the market.
    struct RiskParams {
        uint16 mcrBps;
        uint16 liquidationThresholdBps;
        uint16 liquidationBonusBps;
        uint16 stakedFeeBps;
        uint16 unstakedFeeBps;
        uint16 poolPriceBandBps;
        uint16 redeemMinAssetShareBps;
        uint16 redeemFeeBps;
        uint256 debtCeiling;
        uint256 minDebt;
        uint256 mintPriceMaxAge;
    }

    /// @notice Configuration of one pool.
    /// @param beacon        Beacon of the DEX's vault implementation.
    /// @param asset         The pool's non-eUSD token.
    /// @param ticker        Oracle ticker of the asset.
    /// @param assetDecimals Decimals of the asset (at most 18).
    /// @param enabled       Whether new liquidity is accepted. Exits are never gated by this.
    /// @param exists        Whether the pool has been added.
    /// @param poolData      DEX-specific pool description passed to each new vault.
    struct PoolConfig {
        address beacon;
        address asset;
        bytes32 ticker;
        uint8 assetDecimals;
        bool enabled;
        bool exists;
        bytes poolData;
    }

    /// @notice A position, keyed by (pool id, owner).
    /// @param vault            The position's vault (zero until first use; kept after close).
    /// @param staked           Whether the position's liquidity is staked; selects the fee rate.
    /// @param debt             eUSD debt including fees accrued up to `feeIndexSnapshot` (18 decimals).
    /// @param feeIndexSnapshot Fee index (bps-seconds) of the position's rate at the last accrual.
    /// @param feesAccrued      Fees folded into `debt` and not yet repaid (18 decimals). Debt
    ///                         reductions retire these first.
    struct Position {
        address vault;
        bool staked;
        uint256 debt;
        uint256 feeIndexSnapshot;
        uint256 feesAccrued;
    }

    /// @notice Arguments of {addLiquidity}.
    /// @param poolId       Pool id.
    /// @param tickLower    Lower tick of the range (must match the open range, if any).
    /// @param tickUpper    Upper tick of the range (must match the open range, if any).
    /// @param assetDeposit Asset pulled from the caller into the vault first (asset units, may be 0).
    /// @param assetMax     Most of the vault's idle asset to put into the range (asset units).
    /// @param eusdMax      Most eUSD to put into the range, minted as needed (18 decimals).
    /// @param staked       Whether the position is staked from now on, its open range included.
    struct AddLiquidityParams {
        uint256 poolId;
        int24 tickLower;
        int24 tickUpper;
        uint256 assetDeposit;
        uint256 assetMax;
        uint256 eusdMax;
        bool staked;
    }

    /// @notice Arguments of {rebalance}.
    /// @param poolId      Pool id.
    /// @param owner       Position owner.
    /// @param assetMin    Least asset the old range must return (asset units).
    /// @param eusdMin     Least eUSD the old range must return (18 decimals).
    /// @param swapAmount  Amount the vault sells between removing and adding (0 = no swap).
    /// @param assetToEusd Whether the swap sells asset for eUSD (else eUSD for asset).
    /// @param route       DEX-specific swap route; empty swaps in the position's own pool.
    /// @param tickLower   Lower tick of the new range.
    /// @param tickUpper   Upper tick of the new range.
    /// @param assetMax    Most of the vault's idle asset to put into the new range (asset units).
    /// @param eusdMax     Most eUSD to put into the new range, from the vault first, then minted (18 decimals).
    /// @param staked      Whether the position is staked from now on, its new range included.
    struct RebalanceParams {
        uint256 poolId;
        address owner;
        uint256 assetMin;
        uint256 eusdMin;
        uint256 swapAmount;
        bool assetToEusd;
        bytes route;
        int24 tickLower;
        int24 tickUpper;
        uint256 assetMax;
        uint256 eusdMax;
        bool staked;
    }

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a pool is added.
    /// @param poolId Pool id.
    /// @param beacon Vault beacon of the pool's DEX.
    /// @param asset  The pool's non-eUSD token.
    /// @param ticker Oracle ticker of the asset.
    event PoolAdded(uint256 indexed poolId, address indexed beacon, address indexed asset, bytes32 ticker);

    /// @notice Emitted when a pool's enabled flag changes.
    /// @param poolId  Pool id.
    /// @param enabled New enabled state.
    event PoolEnabledSet(uint256 indexed poolId, bool enabled);

    /// @notice Emitted when the ratio risk parameters change.
    /// @param mcrBps                  New min collateral ratio (BPS).
    /// @param liquidationThresholdBps New liquidation threshold (BPS).
    /// @param liquidationBonusBps     New liquidation bonus (BPS).
    event RiskParamsSet(uint16 mcrBps, uint16 liquidationThresholdBps, uint16 liquidationBonusBps);

    /// @notice Emitted when the stability fees change.
    /// @param stakedFeeBps   New annual fee while staked (BPS).
    /// @param unstakedFeeBps New annual fee while unstaked (BPS).
    event StabilityFeesSet(uint16 stakedFeeBps, uint16 unstakedFeeBps);

    /// @notice Emitted when the pool price band changes.
    /// @param poolPriceBandBps New band (BPS).
    event PoolPriceBandSet(uint16 poolPriceBandBps);

    /// @notice Emitted when the debt ceiling changes.
    /// @param debtCeiling New ceiling (18 decimals).
    event DebtCeilingSet(uint256 debtCeiling);

    /// @notice Emitted when the per-position minimum debt changes.
    /// @param minDebt New minimum (18 decimals).
    event MinDebtSet(uint256 minDebt);

    /// @notice Emitted when the mint price freshness bound changes.
    /// @param mintPriceMaxAge New max age (seconds).
    event MintPriceMaxAgeSet(uint256 mintPriceMaxAge);

    /// @notice Emitted when minting is paused or unpaused (exits unaffected).
    /// @param paused New paused state.
    event MintPausedSet(bool paused);

    /// @notice Emitted when the redemption parameters change.
    /// @param minAssetShareBps New least asset share for a position to be redeemable (BPS).
    /// @param feeBps           New redemption fee kept by the owner (BPS).
    event RedeemParamsSet(uint16 minAssetShareBps, uint16 feeBps);

    /// @notice Emitted when a position's vault is created.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @param vault  The new vault.
    event VaultCreated(uint256 indexed poolId, address indexed owner, address vault);

    /// @notice Emitted when asset is deposited into a vault.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @param amount Asset deposited (asset units).
    event AssetDeposited(uint256 indexed poolId, address indexed owner, uint256 amount);

    /// @notice Emitted when idle asset is withdrawn from a vault.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @param amount Asset withdrawn (asset units).
    event AssetWithdrawn(uint256 indexed poolId, address indexed owner, uint256 amount);

    /// @notice Emitted when eUSD is minted into a vault.
    /// @param poolId  Pool id.
    /// @param owner   Position owner.
    /// @param amount  eUSD minted (18 decimals).
    /// @param newDebt Position debt after the mint (18 decimals).
    event EUSDMinted(uint256 indexed poolId, address indexed owner, uint256 amount, uint256 newDebt);

    /// @notice Emitted when position debt is repaid, by a payer or from the vault's own eUSD.
    /// @param poolId  Pool id.
    /// @param owner   Position owner.
    /// @param payer   Address whose eUSD was burned (the vault for its own eUSD).
    /// @param amount  Debt repaid (18 decimals).
    /// @param newDebt Position debt after the repayment (18 decimals).
    event DebtRepaid(
        uint256 indexed poolId, address indexed owner, address indexed payer, uint256 amount, uint256 newDebt
    );

    /// @notice Emitted when liquidity is added to a position.
    /// @param poolId    Pool id.
    /// @param owner     Position owner.
    /// @param tickLower Lower tick of the range.
    /// @param tickUpper Upper tick of the range.
    /// @param liquidity Liquidity added.
    /// @param assetUsed Asset put into the range (asset units).
    /// @param eusdUsed  eUSD put into the range (18 decimals).
    event LiquidityAdded(
        uint256 indexed poolId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 assetUsed,
        uint256 eusdUsed
    );

    /// @notice Emitted when liquidity is removed from a position into its vault.
    /// @param poolId    Pool id.
    /// @param owner     Position owner.
    /// @param liquidity Liquidity removed.
    /// @param assetOut  Asset returned to the vault (asset units).
    /// @param eusdOut   eUSD returned to the vault (18 decimals).
    event LiquidityRemoved(
        uint256 indexed poolId, address indexed owner, uint128 liquidity, uint256 assetOut, uint256 eusdOut
    );

    /// @notice Emitted when a position switches between staked and unstaked.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @param staked New staked state.
    event StakedSet(uint256 indexed poolId, address indexed owner, bool staked);

    /// @notice Emitted when a position is rebalanced.
    /// @param poolId      Pool id.
    /// @param owner       Position owner.
    /// @param caller      The owner or the delegate.
    /// @param assetToEusd Whether the swap sold asset for eUSD (else eUSD for asset).
    /// @param swapIn      Amount sold (0 when no swap).
    /// @param swapOut     Amount bought (0 when no swap).
    event Rebalanced(
        uint256 indexed poolId,
        address indexed owner,
        address indexed caller,
        bool assetToEusd,
        uint256 swapIn,
        uint256 swapOut
    );

    /// @notice Emitted when stability fees accrue on a position (minted to the treasury).
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @param fee    Fee added to the debt (18 decimals).
    event StabilityFeeAccrued(uint256 indexed poolId, address indexed owner, uint256 fee);

    /// @notice Emitted when a principal-only close settles accrued fees from the vault's asset.
    /// @param poolId      Pool id.
    /// @param owner       Position owner.
    /// @param feesSettled Fee debt retired by burning the treasury's eUSD (18 decimals).
    /// @param feeAsset    Asset sent to the treasury in exchange (asset units).
    event PositionFeesSettledFromAsset(
        uint256 indexed poolId, address indexed owner, uint256 feesSettled, uint256 feeAsset
    );

    /// @notice Emitted when an owner closes a position.
    /// @param poolId     Pool id.
    /// @param owner      Position owner.
    /// @param debt       Debt retired (18 decimals).
    /// @param paidByUser Part of the debt burned from the owner's wallet (18 decimals).
    /// @param assetOut   Asset sent to the owner (asset units).
    /// @param eusdOut    eUSD sent to the owner (18 decimals).
    event PositionClosed(
        uint256 indexed poolId,
        address indexed owner,
        uint256 debt,
        uint256 paidByUser,
        uint256 assetOut,
        uint256 eusdOut
    );

    /// @notice Emitted when a position is liquidated.
    /// @param poolId      Pool id.
    /// @param owner       Position owner.
    /// @param liquidator  Liquidator.
    /// @param debt          Debt cleared by the liquidation (18 decimals).
    /// @param repaid        Part of it burned from the liquidator (18 decimals).
    /// @param seized        Asset paid to the liquidator (asset units).
    /// @param assetRefund   Asset returned to the owner, on a full liquidation (asset units).
    /// @param eusdRefund    eUSD returned to the owner, on a full liquidation (18 decimals).
    /// @param remainingDebt Debt left on the position (18 decimals).
    event PositionLiquidated(
        uint256 indexed poolId,
        address indexed owner,
        address indexed liquidator,
        uint256 debt,
        uint256 repaid,
        uint256 seized,
        uint256 assetRefund,
        uint256 eusdRefund,
        uint256 remainingDebt
    );

    /// @notice Emitted for each position a redemption takes from.
    /// @param poolId        Pool id.
    /// @param owner         Position owner.
    /// @param redeemer      Account that burned eUSD.
    /// @param repaid        eUSD burned from the redeemer against the debt (18 decimals).
    /// @param seized        Asset paid to the redeemer (asset units).
    /// @param remainingDebt Debt left on the position (18 decimals).
    event PositionRedeemed(
        uint256 indexed poolId,
        address indexed owner,
        address indexed redeemer,
        uint256 repaid,
        uint256 seized,
        uint256 remainingDebt
    );

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Thrown when the caller lacks the registry ADMIN role.
    error OnlyAdmin();

    /// @notice Thrown when a position is managed by neither its owner nor its delegate.
    error OnlyOwnerOrDelegate();

    /// @notice Thrown when the caller lacks the registry OPERATOR role.
    error OnlyOperator();

    /// @notice Thrown when a required address is zero.
    error ZeroAddress();

    /// @notice Thrown when a required amount is zero.
    error ZeroAmount();

    /// @notice Thrown when risk parameters are inconsistent or out of range.
    error InvalidRiskParams();

    /// @notice Thrown when a pool id has not been added.
    /// @param poolId Pool id.
    error PoolNotSupported(uint256 poolId);

    /// @notice Thrown when new exposure is requested in a disabled pool.
    /// @param poolId Pool id.
    error PoolDisabled(uint256 poolId);

    /// @notice Thrown when an asset has more than 18 decimals.
    /// @param decimals The asset's decimals.
    error InvalidAssetDecimals(uint8 decimals);

    /// @notice Thrown when a debt increase or withdrawal is attempted while minting is paused.
    error MintingPaused();

    /// @notice Thrown when the oracle price is older than `mintPriceMaxAge`.
    /// @param timestamp Price timestamp.
    /// @param maxAge    Allowed age (seconds).
    error StaleMintPrice(uint256 timestamp, uint256 maxAge);

    /// @notice Thrown when the pool price is outside the band around the oracle price.
    /// @param poolPrice   Pool price (18 decimals).
    /// @param oraclePrice Oracle price (18 decimals).
    error PoolPriceOutOfBand(uint256 poolPrice, uint256 oraclePrice);

    /// @notice Thrown when an action leaves the collateral ratio too low.
    /// @param ratioBps    Resulting ratio (BPS).
    /// @param requiredBps Required ratio (BPS).
    error CollateralRatioTooLow(uint256 ratioBps, uint256 requiredBps);

    /// @notice Thrown when a debt increase would exceed the debt ceiling.
    /// @param totalDebt Resulting total debt (18 decimals).
    /// @param ceiling   Debt ceiling (18 decimals).
    error DebtCeilingExceeded(uint256 totalDebt, uint256 ceiling);

    /// @notice Thrown when a position's debt would be non-zero and below `minDebt`.
    /// @param debt    Resulting debt (18 decimals).
    /// @param minDebt Minimum debt (18 decimals).
    error BelowMinimumDebt(uint256 debt, uint256 minDebt);

    /// @notice Thrown when the position has no debt.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    error NoDebt(uint256 poolId, address owner);

    /// @notice Thrown when the position has no vault.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    error NoVault(uint256 poolId, address owner);

    /// @notice Thrown when closing a position that holds nothing and owes nothing.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    error EmptyPosition(uint256 poolId, address owner);

    /// @notice Thrown when withdrawing more idle asset than the vault holds.
    /// @param requested Amount requested (asset units).
    /// @param available Idle asset in the vault (asset units).
    error InsufficientIdleAsset(uint256 requested, uint256 available);

    /// @notice Thrown when liquidating a position at or above the liquidation threshold.
    /// @param ratioBps     Current ratio (BPS).
    /// @param thresholdBps Liquidation threshold (BPS).
    error PositionNotLiquidatable(uint256 ratioBps, uint256 thresholdBps);

    /// @notice Thrown when redemption is off for this manager.
    error RedeemDisabled();

    /// @notice Thrown when a redemption burns none of the caller's eUSD.
    error NothingToRedeem();

    /// @notice Thrown when a redemption pays less asset than the caller's minimum.
    /// @param assetOut    Asset the redemption would pay (asset units).
    /// @param minAssetOut Caller's minimum (asset units).
    error SlippageExceeded(uint256 assetOut, uint256 minAssetOut);

    // ──────────────────────────────────────────────────────────
    //  Position management
    // ──────────────────────────────────────────────────────────

    /// @notice Deposit asset into the caller's vault as idle collateral. Creates the vault on first
    ///         use. A disabled pool only accepts deposits from a position with debt.
    /// @param poolId Pool id.
    /// @param amount Asset to deposit (asset units).
    function deposit(uint256 poolId, uint256 amount) external;

    /// @notice Withdraw idle asset from the caller's vault. With debt, needs minting open, a fresh
    ///         price, and a ratio of at least MCR afterwards.
    /// @param poolId Pool id.
    /// @param amount Asset to withdraw (asset units).
    function withdraw(uint256 poolId, uint256 amount) external;

    /// @notice Add liquidity to the caller's range: optionally deposit asset, then put up to
    ///         `assetMax` idle asset and up to `eusdMax` eUSD into the range, minting the eUSD the
    ///         vault lacks. Unused eUSD is burned against the debt; unused asset stays idle. Sets
    ///         the position's staked mode first, as {setStaked}. The pool must be enabled and within
    ///         the price band, and the health rule applies.
    /// @param params See {AddLiquidityParams}.
    /// @return liquidity Liquidity added.
    function addLiquidity(
        AddLiquidityParams calldata params
    ) external returns (uint128 liquidity);

    /// @notice Remove liquidity from the caller's range into the vault. The eUSD received is
    ///         burned against the debt; the asset stays idle in the vault.
    /// @param poolId    Pool id.
    /// @param liquidity Liquidity to remove.
    /// @param assetMin  Least asset to receive (asset units).
    /// @param eusdMin   Least eUSD to receive (18 decimals).
    function removeLiquidity(uint256 poolId, uint128 liquidity, uint256 assetMin, uint256 eusdMin) external;

    /// @notice Rebalance a position, as its owner or its vault's delegate: remove all liquidity,
    ///         optionally swap `swapAmount` of the vault's asset for eUSD or back, set the staked
    ///         mode, then add up to `assetMax` asset and `eusdMax` eUSD to the new range, using the
    ///         vault's eUSD first and minting the rest. eUSD left over is burned against the debt.
    ///         The swap needs a fresh price and returns at least its oracle value less
    ///         `poolPriceBandBps`. The pool must be enabled and within the price band, and the
    ///         health rule applies.
    /// @param params See {RebalanceParams}.
    /// @return liquidity Liquidity in the new range.
    function rebalance(
        RebalanceParams calldata params
    ) external returns (uint128 liquidity);

    /// @notice Stake or unstake the caller's liquidity. Staked liquidity earns DEX emissions and
    ///         pays the staked fee; unstaked liquidity keeps swap fees and pays the unstaked fee.
    ///         New positions start unstaked; {addLiquidity} also sets the mode.
    /// @param poolId Pool id.
    /// @param staked Whether the liquidity should be staked.
    function setStaked(uint256 poolId, bool staked) external;

    /// @notice Repay debt of any position with the caller's eUSD. The remaining debt must be zero
    ///         or at least `minDebt`. Needs no price.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @param amount eUSD to repay, capped at the debt (18 decimals).
    function repay(uint256 poolId, address owner, uint256 amount) external;

    /// @notice Close the caller's position: remove all liquidity, burn the vault's eUSD against the
    ///         debt, burn any shortfall from the caller, and send the vault's asset and remaining
    ///         eUSD to the caller. Needs no price.
    /// @param poolId   Pool id.
    /// @param assetMin Least asset the range must return (asset units).
    /// @param eusdMin  Least eUSD the range must return (18 decimals).
    function close(uint256 poolId, uint256 assetMin, uint256 eusdMin) external;

    /// @notice Close the caller's position like {close}, but the caller never pays accrued fees in
    ///         eUSD. Of the shortfall the caller would burn, the part that is still accrued fees (up
    ///         to `feesAccrued`, plus up to 1e9 wei of DEX rounding dust) is settled by sending asset
    ///         of equal value, rounded against the owner, from the vault to the treasury and burning
    ///         the same amount of eUSD from the treasury. Any principal shortfall beyond that (the
    ///         range sold eUSD for asset) is still burned from the caller. With fees to settle it
    ///         needs a fresh price, and it reverts if the treasury's eUSD balance cannot cover the
    ///         burn; {close} always works instead.
    /// @param poolId   Pool id.
    /// @param assetMin Least asset the range must return (asset units).
    /// @param eusdMin  Least eUSD the range must return (18 decimals).
    function closePrincipalOnly(uint256 poolId, uint256 assetMin, uint256 eusdMin) external;

    /// @notice Fold a position's pending stability fee into its debt.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    function accrue(uint256 poolId, address owner) external;

    /// @notice Liquidate a position below the liquidation threshold, in part or in full. Clearing
    ///         `amount` of the debt removes the same share of the range (all of it on a full
    ///         liquidation), burns the vault's eUSD against the cleared debt, burns the rest of it
    ///         from the caller, and pays the caller asset worth that plus the bonus on the cleared
    ///         debt at the oracle price (capped at the vault's asset; on a partial liquidation, also
    ///         capped so the position loses at most the cleared share of its value). On a partial
    ///         liquidation the remaining range stays in place, and leftover eUSD is burned against
    ///         the remaining debt; on a full one everything left goes to the owner. The remaining
    ///         debt must be zero or at least `minDebt`.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @param amount Debt to clear, capped at the debt (18 decimals; `type(uint256).max` for all).
    function liquidate(uint256 poolId, address owner, uint256 amount) external;

    /// @notice Burn up to `amount` of the caller's eUSD against the named positions' debt, in order,
    ///         for asset worth the same at an oracle price no older than `mintPriceMaxAge`, less
    ///         `redeemFeeBps` (rounded down). A position is skipped when it has no debt, when less than
    ///         `redeemMinAssetShareBps` of its vault is asset at the pool price, or when it is
    ///         liquidatable. Each pays from its vault's idle asset first, then from just enough of its
    ///         range; eUSD that range returns is burned against the owner's debt. Each position is
    ///         left with zero debt or at least `minDebt`. The fee stays in the owner's vault. When pool
    ///         rounding frees a few wei less asset than owed, the caller receives what was freed.
    /// @param poolId      Pool id.
    /// @param owners      Positions to redeem from, in order.
    /// @param amount      Most eUSD to burn (18 decimals).
    /// @param minAssetOut Least asset to receive (asset units).
    /// @return assetOut Asset paid to the caller (asset units).
    /// @return burned   eUSD burned from the caller (18 decimals).
    function redeem(
        uint256 poolId,
        address[] calldata owners,
        uint256 amount,
        uint256 minAssetOut
    ) external returns (uint256 assetOut, uint256 burned);

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @notice Add a pool. ADMIN only. The beacon's implementation must accept the pool data.
    /// @param beacon   Beacon of the DEX's vault implementation.
    /// @param asset    The pool's non-eUSD token (at most 18 decimals, no transfer fee).
    /// @param ticker   Oracle ticker of the asset (must be priced).
    /// @param poolData DEX-specific pool description.
    /// @return poolId The new pool id.
    function addPool(
        address beacon,
        address asset,
        bytes32 ticker,
        bytes calldata poolData
    ) external returns (uint256 poolId);

    /// @notice Enable or disable new liquidity in a pool. ADMIN only.
    /// @param poolId  Pool id.
    /// @param enabled New state.
    function setPoolEnabled(uint256 poolId, bool enabled) external;

    /// @notice Set the ratio parameters. ADMIN only. Requires mcr ≥ threshold ≥ 100% + bonus.
    /// @param mcrBps                  Min collateral ratio (BPS).
    /// @param liquidationThresholdBps Liquidation threshold (BPS).
    /// @param liquidationBonusBps     Liquidation bonus (BPS).
    function setRiskParams(uint16 mcrBps, uint16 liquidationThresholdBps, uint16 liquidationBonusBps) external;

    /// @notice Set the stability fees, applying from now. ADMIN only.
    /// @param stakedFeeBps   Annual fee while staked (BPS, at most 100%).
    /// @param unstakedFeeBps Annual fee while unstaked (BPS, at most 100%).
    function setStabilityFees(uint16 stakedFeeBps, uint16 unstakedFeeBps) external;

    /// @notice Set the pool price band. ADMIN only.
    /// @param poolPriceBandBps Band (BPS, above 0 and at most 100%).
    function setPoolPriceBand(
        uint16 poolPriceBandBps
    ) external;

    /// @notice Set the debt ceiling. ADMIN only.
    /// @param debtCeiling Ceiling (18 decimals).
    function setDebtCeiling(
        uint256 debtCeiling
    ) external;

    /// @notice Set the per-position minimum debt. ADMIN only.
    /// @param minDebt Minimum (18 decimals).
    function setMinDebt(
        uint256 minDebt
    ) external;

    /// @notice Set the max oracle price age for debt increases and withdrawals. ADMIN only.
    /// @param mintPriceMaxAge Max age (seconds, non-zero).
    function setMintPriceMaxAge(
        uint256 mintPriceMaxAge
    ) external;

    /// @notice Set the redemption parameters. ADMIN only.
    /// @param minAssetShareBps Least asset share, at the pool price, for a position to be
    ///                         redeemable (BPS, at most 10,000); 0 turns redemption off.
    /// @param feeBps           Redemption fee kept in the owner's vault (BPS, below 10,000).
    function setRedeemParams(uint16 minAssetShareBps, uint16 feeBps) external;

    /// @notice Pause or unpause debt increases and withdrawals against debt. OPERATOR only.
    /// @param paused New state.
    function setMintPaused(
        bool paused
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice The eUSD token.
    /// @return The token address.
    function eusd() external view returns (address);

    /// @notice Whether debt increases and withdrawals against debt are paused.
    /// @return Paused flag.
    function mintPaused() external view returns (bool);

    /// @notice Total debt of all positions, as of their last accrual (18 decimals).
    /// @return Total debt.
    function totalDebt() external view returns (uint256);

    /// @notice Number of pools added; pool ids run from 0 to `poolCount - 1`.
    /// @return Pool count.
    function poolCount() external view returns (uint256);

    /// @notice Current risk parameters.
    /// @return The parameters.
    function riskParams() external view returns (RiskParams memory);

    /// @notice A pool's configuration.
    /// @param poolId Pool id.
    /// @return The configuration.
    function poolConfig(
        uint256 poolId
    ) external view returns (PoolConfig memory);

    /// @notice A position as stored (debt as of its last accrual).
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @return The position.
    function getPosition(uint256 poolId, address owner) external view returns (Position memory);

    /// @notice Number of positions ever opened in a pool (one per owner, including closed ones).
    /// @param poolId Pool id.
    /// @return Count.
    function positionCount(
        uint256 poolId
    ) external view returns (uint256);

    /// @notice Owner of the `index`-th position opened in a pool.
    /// @param poolId Pool id.
    /// @param index  Index, below {positionCount}.
    /// @return The owner.
    function positionOwnerAt(uint256 poolId, uint256 index) external view returns (address);

    /// @notice Debt including fees accrued up to now (18 decimals).
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @return Debt.
    function currentDebt(uint256 poolId, address owner) external view returns (uint256);

    /// @notice Collateral value of a position at the latest oracle price (18 decimals, in eUSD).
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @return Value.
    function collateralValue(uint256 poolId, address owner) external view returns (uint256);

    /// @notice Collateral ratio at the latest oracle price with debt accrued to now (BPS;
    ///         type(uint256).max without debt).
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @return Ratio.
    function collateralRatioBps(uint256 poolId, address owner) external view returns (uint256);

    /// @notice Whether a position is below the liquidation threshold.
    /// @param poolId Pool id.
    /// @param owner  Position owner.
    /// @return Liquidatable flag.
    function isLiquidatable(uint256 poolId, address owner) external view returns (bool);

    /// @notice Fee index (bps-seconds) of the staked or unstaked rate, as of now.
    /// @param staked Which rate.
    /// @return Index.
    function globalFeeIndex(
        bool staked
    ) external view returns (uint256);
}
