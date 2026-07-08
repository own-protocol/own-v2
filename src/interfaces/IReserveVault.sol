// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IReserveVault — Share-less RWA reserve pool backing one asset's eToken supply 1:1
/// @notice Holds a single wrapper token as protocol-owned backing for the asset it is registered
///         against on the VaultManager. No LP shares or queues; reserve enters via the OwnMarket
///         PSM paths and exits via {releaseCollateral}, {withdraw}, or {skimExcess}.
interface IReserveVault {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when wrapper reserve is deposited (maker hedge delivery / donation).
    /// @param sender Depositor.
    /// @param amount Wrapper token amount deposited.
    event ReserveDeposited(address indexed sender, uint256 amount);

    /// @notice Emitted when reserve collateral is released to a PSM redeemer.
    /// @param to     Recipient of the wrapper tokens.
    /// @param amount Wrapper token amount released.
    event CollateralReleased(address indexed to, uint256 amount);

    /// @notice Emitted when surplus reserve above the asset's outstanding exposure is skimmed.
    /// @param to     Treasury address receiving the surplus.
    /// @param amount Wrapper token amount skimmed.
    event ExcessSkimmed(address indexed to, uint256 amount);

    /// @notice Emitted when a maker withdraws surplus reserve to its linked settlement address.
    /// @param signer Registered quote signer that initiated the withdrawal.
    /// @param to     The signer's linked settlement address receiving the wrapper.
    /// @param amount Wrapper token amount withdrawn.
    event SurplusWithdrawn(address indexed signer, address indexed to, uint256 amount);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Caller is not the market contract.
    error OnlyMarket();
    /// @notice Caller does not hold the operator role.
    error OnlyOperator();
    /// @notice Caller is not a registered quote signer (maker).
    error OnlyMaker();
    /// @notice A required address was the zero address.
    error ZeroAddress();
    /// @notice A required amount was zero.
    error ZeroAmount();
    /// @notice Release amount exceeds the reserve balance.
    error AmountExceedsReserve();
    /// @notice The wrapper token reports more than 18 decimals.
    error DecimalsTooHigh(uint8 decimals);
    /// @notice The release would drop the reserve below the asset's outstanding exposure.
    error SkimExceedsSurplus();
    /// @notice The deposit received less than the sent amount (fee-on-transfer token).
    error FeeOnTransferNotSupported();
    /// @notice The protocol treasury address is unset in the registry.
    error TreasuryNotSet();
    /// @notice This vault is not registered on the VaultManager as an RWA reserve vault.
    error VaultNotRwaRegistered();

    // ──────────────────────────────────────────────────────────
    //  Functions
    // ──────────────────────────────────────────────────────────

    /// @notice The wrapper token held as reserve.
    function asset() external view returns (address);

    /// @notice Current reserve balance (wrapper token units held by this vault).
    function totalAssets() external view returns (uint256);

    /// @notice Deposit wrapper reserve without minting (maker hedge delivery); syncs the
    ///         collateral mark so the deposit nets against the asset's exposure immediately.
    function deposit(
        uint256 amount
    ) external;

    /// @notice Release `amount` of reserve to `to` for a PSM redemption, syncing the collateral
    ///         mark before the transfer. Market-only.
    function releaseCollateral(address to, uint256 amount) external;

    /// @notice Skim reserve in excess of the asset's outstanding exposure to the treasury.
    ///         Operator-only; only the surplus above gross exposure is spendable.
    function skimExcess(
        uint256 amount
    ) external;

    /// @notice Withdraw surplus reserve to the caller's linked settlement address. Callable by
    ///         registered quote signers; only the surplus above gross exposure is spendable.
    function withdraw(
        uint256 amount
    ) external;
}
