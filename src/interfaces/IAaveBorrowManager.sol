// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InterestRateModel} from "../libraries/InterestRateModel.sol";

/// @title IAaveBorrowManager — User borrowing against eTokens via vault Aave credit
/// @notice Borrowers post eTokens as collateral, the manager borrows the
///         vault's stablecoin (USDC) from Aave V3 via credit delegation, and
///         hands the stablecoin to the borrower. Each (borrower, asset)
///         carries its own position. Liquidation is full-close, signed-price
///         gated, and bonus is capped by available collateral.
///
///         Pooled per-asset eToken custody: the manager holds one balance of
///         each eToken across all borrowers; per-position bookkeeping tracks
///         each borrower's share.
interface IAaveBorrowManager {
    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @notice A user's borrow position for one asset.
    /// @param eTokenCollateral Amount of the asset's eToken posted (18 dec).
    /// @param principal        Stablecoin debt principal in stablecoin decimals.
    /// @param interestIndex    Snapshot of the manager's per-asset interest
    ///                         index at last accrual.
    struct Position {
        uint256 eTokenCollateral;
        uint256 principal;
        uint256 interestIndex;
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

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error OnlyAdmin();
    error AssetNotSupportedByVault(bytes32 asset);
    error AssetNotActive(bytes32 asset);
    error PassThroughNotEnabled(address eToken);
    error VaultEffectivelyHalted();
    error ETokenMismatch(address expected, address actual);
    error InsufficientCollateral(uint256 requested, uint256 maxAllowed);
    error PositionAlreadyOpen(address borrower, bytes32 asset);
    error NoPosition(address borrower, bytes32 asset);
    error NotLiquidatable(uint256 healthFactor);
    error InvalidLiquidationConfig();

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

    /// @notice Liquidate an underwater `(borrower, asset)` position. Full close.
    /// @dev    Liquidator pays the full outstanding debt; receives eToken
    ///         collateral up to `repayAmount * (1 + bonus) / oraclePrice`,
    ///         capped at the remaining collateral. Residual collateral (if
    ///         any) is returned to the borrower in the same call.
    /// @param  borrower  Underwater position's borrower.
    /// @param  asset     Asset ticker.
    /// @param  priceData Signed price proof for `asset`.
    function liquidate(address borrower, bytes32 asset, bytes calldata priceData) external payable;

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice Vault bound to this manager.
    function vault() external view returns (address);

    /// @notice Stablecoin borrowed via this manager (e.g. USDC).
    function stablecoin() external view returns (address);

    /// @notice Aave variable debt token for the stablecoin.
    function debtToken() external view returns (address);

    /// @notice Aave V3 Pool address.
    function aavePool() external view returns (address);

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

    /// @notice Per-position view. Returns zero for unopened positions.
    function positionOf(address borrower, bytes32 asset) external view returns (Position memory);

    /// @notice Current debt (principal + accrued interest) for a position.
    function debtOf(address borrower, bytes32 asset) external view returns (uint256);

    /// @notice Current health factor (1e18 = 1.0). Positions with no debt
    ///         return `type(uint256).max`.
    function healthFactor(address borrower, bytes32 asset, uint256 oraclePrice) external view returns (uint256);

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    function setRateParams(
        InterestRateModel.Params calldata params
    ) external;

    function setLiquidationConfig(uint256 liquidationThresholdBps_, uint256 liquidationBonusBps_) external;
}
