// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVaultYieldManager — automated LP yield distribution shell
/// @notice Installed as an OwnVault's `manager` (via `OwnVault.setManager`), so all
///         BorrowManager revenue — premium sweeps, dividend sweeps, interest claims —
///         lands here as stablecoin. Anyone can crank {distribute}: a treasury cut
///         (BPS) goes to `ProtocolRegistry.treasury()` and the remainder is converted
///         1:1 into the vault's aToken via `OwnLendingPool.supply` (lossless — the
///         pool mints its aToken 1:1 for the underlying) and pushed to LPs with
///         `OwnVault.shareYield`, lifting the share price.
///
///         Yield realization ({distribute}, {claimEarnedInterest}) is permissionless;
///         `BorrowManager.sweepDividends` already is. The deposit queue stays with the
///         shell's own `manager` (the VM entity) via passthroughs. The shell is
///         stateless between transactions apart from undistributed revenue;
///         installing or removing it is one admin `OwnVault.setManager` call.
interface IVaultYieldManager {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Revenue split executed: `treasuryCut` stablecoin to the treasury,
    ///         `lpYield` supplied to the pool and shared to vault LPs.
    event YieldDistributed(address indexed caller, uint256 treasuryCut, uint256 lpYield);

    /// @notice Treasury cut updated (BPS).
    event TreasuryCutUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Shell manager (the VM entity driving deposit acceptance) updated.
    event ManagerUpdated(address indexed oldManager, address indexed newManager);

    /// @notice Non-revenue token rescued to `to`.
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Caller does not hold the registry ADMIN role.
    error OnlyAdmin();

    /// @notice Caller is not the shell manager.
    error OnlyManager();

    /// @notice Caller is neither a registry OPERATOR nor the shell manager.
    error OnlyOperatorOrManager();

    /// @notice Zero address argument (or unset registry treasury at distribution time).
    error ZeroAddress();

    /// @notice Treasury cut exceeds 100%.
    error InvalidTreasuryCut(uint256 bps);

    /// @notice The pool's aToken is not the vault's ERC-4626 asset.
    error AssetMismatch(address vaultAsset, address poolAToken);

    /// @notice No undistributed revenue held.
    error NothingToDistribute();

    /// @notice The vault has no shares outstanding — yield would accrue to the
    ///         first depositor; revenue waits until LPs exist.
    error NoSharesOutstanding();

    /// @notice The revenue stablecoin cannot be rescued — it exits only via {distribute}.
    error CannotRescueRevenue(address token);

    // ──────────────────────────────────────────────────────────
    //  Distribution
    // ──────────────────────────────────────────────────────────

    /// @notice Split this contract's full stablecoin balance: `treasuryCutBps` to the
    ///         protocol treasury, remainder converted 1:1 to the vault's aToken and
    ///         distributed to LPs via `shareYield`. Permissionless crank.
    function distribute() external;

    /// @notice Realize earned-but-uncollected lending premium mid-term (forwards
    ///         `BorrowManager.claimEarnedInterest`). Permissionless like {distribute}:
    ///         the claim is bounded and HF-gated by the BorrowManager itself, and the
    ///         stablecoin lands on this contract where {distribute} is its only exit —
    ///         a caller can only accelerate yield realization, never redirect it.
    /// @param amount Stablecoin amount to claim (must be <= `claimableInterest()`).
    function claimEarnedInterest(
        uint256 amount
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Manager passthroughs (the VM entity drives the deposit queue)
    // ──────────────────────────────────────────────────────────

    /// @notice Accept a pending vault deposit request (forwards `OwnVault.acceptDeposit`).
    /// @param requestId Deposit queue request id.
    function acceptDeposit(
        uint256 requestId
    ) external;

    /// @notice Reject a pending vault deposit request (forwards `OwnVault.rejectDeposit`).
    /// @param requestId Deposit queue request id.
    function rejectDeposit(
        uint256 requestId
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Admin / ops
    // ──────────────────────────────────────────────────────────

    /// @notice Update the treasury cut (BPS, <= 10_000). ADMIN only.
    function setTreasuryCutBps(
        uint256 bps
    ) external;

    /// @notice Update the shell manager (the VM entity). ADMIN only.
    function setManager(
        address newManager
    ) external;

    /// @notice Rescue a non-revenue token mistakenly sent here. Callable by a
    ///         registry OPERATOR or the shell manager. The revenue stablecoin is
    ///         excluded — it can only exit through {distribute}.
    /// @param token Token to rescue (must not be the revenue stablecoin).
    /// @param to    Recipient.
    function rescueToken(address token, address to) external;

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice The OwnVault this shell manages.
    function vault() external view returns (address);

    /// @notice The shell manager — the VM entity that drives the deposit queue.
    function manager() external view returns (address);

    /// @notice The OwnLendingPool used for 1:1 stablecoin → aToken conversion.
    function pool() external view returns (address);

    /// @notice The revenue stablecoin (the pool's underlying).
    function stablecoin() external view returns (address);

    /// @notice Treasury cut in BPS.
    function treasuryCutBps() external view returns (uint256);

    /// @notice Undistributed revenue currently held (stablecoin units).
    function pendingYield() external view returns (uint256);
}
