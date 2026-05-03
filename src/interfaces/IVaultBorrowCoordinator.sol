// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVaultBorrowCoordinator — Shared debt and utilization oracle for a vault
/// @notice Single source of truth that aggregates outstanding debt across every
///         borrow manager registered against a vault. Drives:
///         - The utilization figure that each manager passes into its
///           InterestRateModel premium curve.
///         - The protocol-level hard cap on total debt (vs. vault collateral).
///         - The live Aave borrow rate (read once, shared by all managers).
///
///         One coordinator per vault (1:1 binding). Borrow managers query it
///         on every state-changing call.
interface IVaultBorrowCoordinator {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    event ManagerRegistered(address indexed manager);
    event ManagerDeregistered(address indexed manager);
    event TargetLtvBpsUpdated(uint256 oldBps, uint256 newBps);
    event StablecoinUpdated(address indexed oldStablecoin, address indexed newStablecoin);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error OnlyAdmin();
    error ManagerAlreadyRegistered(address manager);
    error ManagerNotRegistered(address manager);
    error InvalidLtv();
    error BorrowExceedsCap(uint256 attempted, uint256 cap);

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @notice Register `manager` as a debt contributor. Reverts if already registered.
    function registerManager(
        address manager
    ) external;

    /// @notice Deregister `manager`. Useful for migrations / sunsets.
    function deregisterManager(
        address manager
    ) external;

    /// @notice Set the target Aave LTV (BPS) used as the protocol-level debt cap.
    /// @dev    Must be < 10_000.
    function setTargetLtvBps(
        uint256 ltvBps
    ) external;

    /// @notice Set the stablecoin used to read Aave's live borrow rate. Set
    ///         once at deployment; admin can update if the vault ever moves
    ///         to a different reserve.
    function setStablecoin(
        address stablecoin
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Hard cap (called by managers before borrowing)
    // ──────────────────────────────────────────────────────────

    /// @notice Revert if borrowing `additionalUSD` more would push protocol
    ///         debt past the configured cap. Pure precondition — does not mutate.
    /// @param additionalUSD Additional USD-value debt to be added (18 decimals).
    function preBorrowCheck(
        uint256 additionalUSD
    ) external view;

    // ──────────────────────────────────────────────────────────
    //  Views consumed by managers' rate logic
    // ──────────────────────────────────────────────────────────

    /// @notice Utilization across all registered managers (BPS, capped at 10_000).
    /// @return utilBps `totalDebtUSD * 10_000 / maxDebtUSD`, clamped.
    function utilizationBps() external view returns (uint256 utilBps);

    /// @notice Sum of `IBorrowDebt.totalDebtUSD()` across registered managers (18 decimals).
    function totalDebtUSD() external view returns (uint256);

    /// @notice Vault collateral value × `targetLtvBps` (USD, 18 decimals).
    function maxDebtUSD() external view returns (uint256);

    /// @notice Live Aave variable borrow rate for the configured stablecoin
    ///         (BPS). Reads `IAaveV3Pool.getReserveData` and converts RAY → BPS.
    function liveAaveRateBps() external view returns (uint256);

    // ──────────────────────────────────────────────────────────
    //  Plain views
    // ──────────────────────────────────────────────────────────

    function vault() external view returns (address);
    function aavePool() external view returns (address);
    function stablecoin() external view returns (address);
    function targetLtvBps() external view returns (uint256);
    function isManager(
        address manager
    ) external view returns (bool);
    function managers() external view returns (address[] memory);
}
