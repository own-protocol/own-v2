// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InterestRateModel} from "../libraries/InterestRateModel.sol";

/// @title ILPBorrowManager — LP borrowing against vault shares
/// @notice LPs transfer their `OwnVault` shares to the manager (custody
///         transfer) as collateral. The manager borrows the vault's stablecoin
///         (USDC) from Aave V3 via credit delegation and either hands the
///         stablecoin to the LP or routes it into an `OwnMarket.placeMintOrder`
///         on the LP's behalf.
///
///         The manager is registered on the vault as a *share custodian*: when
///         the manager later transfers shares back to the LP (on repay or
///         residual return), the vault's pass-through redirect routes the
///         vault-fee rewards earned during custody back to the LP.
///
///         Multicall-friendly: a single transaction can `borrow` then
///         `placeMintOrder` to atomically open a position and queue a mint.
///         Order ownership stays with the manager (msg.sender of placeMintOrder);
///         the eToken is delivered to the manager on confirmation, and the LP
///         claims it via `claimMintedETokens(orderId)`.
///
///         One position per LP. Vault-share collateral is fungible, so no
///         per-asset position segmentation. Liquidation is full-close,
///         signed-price gated; the liquidator receives the seized vault
///         shares (a claim on the vault, not the underlying) so vault
///         solvency for the remaining LPs is preserved.
interface ILPBorrowManager {
    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @notice Per-LP position.
    /// @param sharesHeld     Vault shares the manager holds as collateral for this LP.
    /// @param principal      Scaled stablecoin debt (auto-grows with `_index`).
    /// @param interestIndex  Snapshot of `_index` at last touch.
    struct Position {
        uint256 sharesHeld;
        uint256 principal;
        uint256 interestIndex;
    }

    /// @notice Off-chain mapping of OwnMarket order → LP that funded it.
    /// @param lp     LP that owns the borrowed stablecoin and the eventual eTokens.
    /// @param asset  Asset ticker the order was placed for.
    /// @param claimed Whether the LP has already claimed the minted eTokens.
    struct OrderRef {
        address lp;
        bytes32 asset;
        bool claimed;
    }

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    event Borrowed(address indexed lp, uint256 sharesHeld, uint256 stablecoinAmount, uint256 collateralValueUSD);
    event Repaid(address indexed lp, uint256 repayAmount, uint256 sharesReleased, uint256 remainingPrincipal);
    event MintOrderPlaced(address indexed lp, uint256 indexed orderId, bytes32 indexed asset, uint256 stablecoinAmount);
    event MintedETokensClaimed(address indexed lp, uint256 indexed orderId, address indexed eToken, uint256 amount);
    event Liquidated(
        address indexed lp,
        address indexed liquidator,
        uint256 repayAmount,
        uint256 sharesSeized,
        uint256 sharesReturnedToLP
    );
    event RateParamsUpdated(InterestRateModel.Params params);
    event LiquidationConfigUpdated(uint256 liquidationThresholdBps, uint256 liquidationBonusBps);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error OnlyAdmin();
    error PositionAlreadyOpen(address lp);
    error NoPosition(address lp);
    error InsufficientCollateral(uint256 requested, uint256 maxAllowed);
    error NotLiquidatable(uint256 healthFactor);
    error InvalidLiquidationConfig();
    error OrderNotForLP(uint256 orderId);
    error OrderNotConfirmed(uint256 orderId);
    error OrderAlreadyClaimed(uint256 orderId);
    error InsufficientStablecoinBalance(uint256 needed, uint256 available);

    // ──────────────────────────────────────────────────────────
    //  Borrower flows
    // ──────────────────────────────────────────────────────────

    /// @notice Open or top up a borrow position. Pulls `sharesAmount` vault
    ///         shares from the caller into custody and borrows
    ///         `stablecoinAmount` USDC. The borrowed stablecoin stays in the
    ///         manager — the caller follows up with `withdrawBorrowed` (to
    ///         receive USDC) or `placeMintOrder` (to immediately queue a
    ///         mint), typically in the same multicall.
    /// @dev    Caller must have approved this contract for `sharesAmount` of
    ///         vault shares.
    /// @param sharesAmount     Vault shares to pledge.
    /// @param stablecoinAmount USDC to borrow (in stablecoin decimals).
    /// @param priceData        Signed wstETH oracle proof for share valuation.
    function borrow(uint256 sharesAmount, uint256 stablecoinAmount, bytes calldata priceData) external payable;

    /// @notice Repay outstanding debt. Pass `type(uint256).max` to fully close.
    /// @return sharesReleased Vault shares unencumbered for the LP.
    function repay(
        uint256 amount
    ) external returns (uint256 sharesReleased);

    /// @notice Send already-borrowed stablecoin (sitting in the manager) to the LP.
    /// @param amount Amount of stablecoin to withdraw.
    function withdrawBorrowed(
        uint256 amount
    ) external;

    /// @notice Place a mint order on `OwnMarket` using the LP's borrowed stablecoin.
    ///         The LP must already have at least `stablecoinAmount` of borrowed
    ///         (un-withdrawn) stablecoin held by this manager. The manager
    ///         pulls the stablecoin internally — the LP does not need to
    ///         transfer it.
    /// @param asset            Asset ticker.
    /// @param stablecoinAmount Amount of USDC to send into the order.
    /// @param maxPrice         Max price per eToken the LP will accept.
    /// @param expiry           Unix expiry for the order.
    /// @return orderId         OwnMarket order id (manager is owner).
    function placeMintOrder(
        bytes32 asset,
        uint256 stablecoinAmount,
        uint256 maxPrice,
        uint256 expiry
    ) external returns (uint256 orderId);

    /// @notice Claim the eTokens minted for `orderId` to the LP that funded it.
    function claimMintedETokens(
        uint256 orderId
    ) external;

    /// @notice Liquidate an underwater LP position. Full close.
    /// @param lp        LP whose position is being closed.
    /// @param priceData Signed wstETH oracle proof.
    function liquidate(address lp, bytes calldata priceData) external payable;

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    function vault() external view returns (address);
    function stablecoin() external view returns (address);
    function debtToken() external view returns (address);
    function aavePool() external view returns (address);
    function market() external view returns (address);
    function collateralAsset() external view returns (bytes32);

    function rateParams()
        external
        view
        returns (uint64 basePremiumBps, uint64 optimalUtilBps, uint64 slope1Bps, uint64 slope2Bps);

    function liquidationThresholdBps() external view returns (uint256);
    function liquidationBonusBps() external view returns (uint256);
    function borrowLtvBps() external view returns (uint256);

    function positionOf(
        address lp
    ) external view returns (Position memory);
    function debtOf(
        address lp
    ) external view returns (uint256);
    function lpStablecoinBalance(
        address lp
    ) external view returns (uint256);
    function orderRef(
        uint256 orderId
    ) external view returns (OrderRef memory);

    /// @notice Health factor: `collateralValueUSD * threshold / debt`. Returns
    ///         `type(uint256).max` if the position has no debt.
    function healthFactor(address lp, uint256 wstETHPriceUSD) external view returns (uint256);

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    function setRateParams(
        InterestRateModel.Params calldata params
    ) external;
    function setLiquidationConfig(uint256 liquidationThresholdBps_, uint256 liquidationBonusBps_) external;
}
