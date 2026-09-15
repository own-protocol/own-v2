// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOwnStakeZap — one-transaction routes into OwnStakingV2
/// @notice Stateless router collapsing the multi-step basket flows (PSM-mint collateral, CDP
///         deposit, eUSD mint, dual-asset stake) into single transactions on any wallet. Holds no
///         funds and no admin: replace by deploying a new zap and repointing the whitelists on
///         EUSDManager and OwnStakingV2.
interface IOwnStakeZap {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a basket is built or extended through the zap.
    /// @param user        Position owner.
    /// @param spyIn       SPY the user brought (18 decimals; 0 for non-SPY entries).
    /// @param moneyStaked $MONEY staked (18 decimals).
    /// @param eusdStaked  eUSD staked (18 decimals).
    event ZapStaked(address indexed user, uint256 spyIn, uint256 moneyStaked, uint256 eusdStaked);

    /// @notice Emitted when sEUSD is migrated into the staking contract.
    /// @param user        Position owner.
    /// @param sharesIn    sEUSD shares redeemed.
    /// @param eusdStaked  eUSD staked from the redemption (18 decimals).
    /// @param moneyStaked $MONEY staked alongside (18 decimals).
    event Migrated(address indexed user, uint256 sharesIn, uint256 eusdStaked, uint256 moneyStaked);

    /// @notice Emitted when claimed SPY rewards are compounded into CDP collateral.
    /// @param user            Position owner.
    /// @param spyClaimed      SPY rewards claimed (18 decimals).
    /// @param collateralAdded Collateral eTokens deposited (18 decimals).
    event Compounded(address indexed user, uint256 spyClaimed, uint256 collateralAdded);

    /// @notice Emitted when staked eUSD is unwound into a debt repayment.
    /// @param user          Position owner.
    /// @param eusdUnstaked  eUSD pulled from the staking position (18 decimals).
    /// @param debtRepaid    eUSD burned against the CDP (18 decimals).
    /// @param eusdReturned  Unused remainder returned to the user (18 decimals).
    event Rebalanced(address indexed user, uint256 eusdUnstaked, uint256 debtRepaid, uint256 eusdReturned);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice A required address was the zero address.
    error ZeroAddress();
    /// @notice A required amount was zero.
    error ZeroAmount();
    /// @notice The SPY slice to swap exceeds the SPY brought.
    error InvalidSplit(uint256 spyForMoney, uint256 spyAmount);
    /// @notice The swap call to the router reverted.
    error SwapFailed();
    /// @notice The swap produced less $MONEY than the caller's floor.
    /// @param moneyOut    $MONEY received (18 decimals).
    /// @param minMoneyOut Caller's floor (18 decimals).
    error InsufficientMoneyOut(uint256 moneyOut, uint256 minMoneyOut);
    /// @notice No settled rewards to compound.
    error NothingToCompound();

    // ──────────────────────────────────────────────────────────
    //  Entries
    // ──────────────────────────────────────────────────────────

    /// @notice Build a basket from SPY alone: swap `spyForMoney` of it to $MONEY through the
    ///         vetted router, PSM-mint the rest into collateral eTokens, deposit them into the
    ///         caller's CDP, mint `eusdToMint` eUSD against it and stake both legs — one
    ///         transaction.
    /// @param spyAmount   SPY pulled from the caller (18 decimals).
    /// @param spyForMoney Slice of `spyAmount` sold for $MONEY (may be zero = no boost leg).
    /// @param minMoneyOut Floor on the $MONEY received for the slice (required when swapping).
    /// @param swapData    Router calldata prepared by the app for the SPY→$MONEY fill.
    /// @param eusdToMint  eUSD minted against the new collateral and staked (may be zero).
    /// @param hint        Sorted-list insert hint for the CDP (see IEUSDManager.deposit).
    function stakeFromSpy(
        uint256 spyAmount,
        uint256 spyForMoney,
        uint256 minMoneyOut,
        bytes calldata swapData,
        uint256 eusdToMint,
        address hint
    ) external;

    /// @notice Same as {stakeFromSpy} without the swap: the caller brings the $MONEY leg.
    /// @param spyAmount   SPY pulled from the caller and PSM-minted into collateral (18 decimals).
    /// @param moneyAmount $MONEY pulled from the caller and staked (may be zero).
    /// @param eusdToMint  eUSD minted against the new collateral and staked (may be zero).
    /// @param hint        Sorted-list insert hint for the CDP.
    function stakeFromSpyAndMoney(
        uint256 spyAmount,
        uint256 moneyAmount,
        uint256 eusdToMint,
        address hint
    ) external;

    /// @notice Stake eUSD and $MONEY the caller already holds. No CDP involved.
    /// @param eusdAmount  eUSD pulled and staked (may be zero).
    /// @param moneyAmount $MONEY pulled and staked (may be zero; both zero reverts).
    function stakeFromEusdAndMoney(
        uint256 eusdAmount,
        uint256 moneyAmount
    ) external;

    /// @notice Migrate from sEUSD: redeem the caller's shares (instant, no cooldown), stake the
    ///         eUSD alongside `moneyAmount` of $MONEY.
    /// @param shares      sEUSD shares redeemed (caller must have approved the zap).
    /// @param moneyAmount $MONEY pulled and staked alongside (may be zero).
    function stakeFromSeusd(
        uint256 shares,
        uint256 moneyAmount
    ) external;

    /// @notice Compound: claim the caller's settled SPY rewards, PSM-mint them into collateral
    ///         eTokens and deposit them into the caller's CDP — yield becomes index collateral.
    /// @param hint Sorted-list insert hint for the CDP.
    function compound(
        address hint
    ) external;

    /// @notice The "SPY fell" button: pull staked eUSD from the caller's position and repay their
    ///         CDP debt with it in the same transaction (health only improves). Any repayment
    ///         remainder above the outstanding debt is returned to the caller as eUSD.
    /// @param eusdAmount Staked eUSD to unwind into the repayment (18 decimals).
    /// @param hint       Sorted-list insert hint for the CDP.
    function rebalance(
        uint256 eusdAmount,
        address hint
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Views (wiring, all immutable)
    // ──────────────────────────────────────────────────────────

    /// @notice The CDP engine.
    function eusdManager() external view returns (address);

    /// @notice The staking contract.
    function staking() external view returns (address);

    /// @notice The market whose PSM converts SPY into collateral eTokens.
    function market() external view returns (address);

    /// @notice The legacy sEUSD vault (migration source).
    function sEusd() external view returns (address);

    /// @notice The collateral eToken (eSPY).
    function collateral() external view returns (address);

    /// @notice The PSM asset ticker for the collateral.
    function collateralTicker() external view returns (bytes32);

    /// @notice The vetted swap router for the SPY→$MONEY leg.
    function swapRouter() external view returns (address);
}
