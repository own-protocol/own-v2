// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFeeAccrual — Protocol fee collection and three-way distribution
/// @notice Collects fees from OwnMarket on each order confirmation and tracks
///         accrued balances for protocol treasury, LPs (per vault), and VMs.
interface IFeeAccrual {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a fee is accrued and split.
    /// @param vault          Vault that backed the order.
    /// @param vm             Vault manager who confirmed the order.
    /// @param token          Stablecoin in which the fee is denominated.
    /// @param totalAmount    Total fee amount accrued.
    /// @param protocolAmount Protocol's share.
    /// @param lpAmount       LP share (credited to vault).
    /// @param vmAmount       VM's share.
    event FeeAccrued(
        address indexed vault,
        address indexed vm,
        address indexed token,
        uint256 totalAmount,
        uint256 protocolAmount,
        uint256 lpAmount,
        uint256 vmAmount
    );

    /// @notice Emitted when protocol fees are claimed.
    /// @param token  Token claimed.
    /// @param amount Amount transferred to treasury.
    event ProtocolFeesClaimed(address indexed token, uint256 amount);

    /// @notice Emitted when LP fees are claimed for a vault.
    /// @param vault  Vault receiving the fees.
    /// @param token  Token transferred.
    /// @param amount Amount transferred to vault.
    event LPFeesClaimed(address indexed vault, address indexed token, uint256 amount);

    /// @notice Emitted when a VM claims their accrued fees.
    /// @param vm     Vault manager address.
    /// @param token  Token claimed.
    /// @param amount Amount transferred.
    event VMFeesClaimed(address indexed vm, address indexed token, uint256 amount);

    /// @notice Emitted when the protocol share is updated.
    /// @param oldShareBps Previous share in BPS.
    /// @param newShareBps New share in BPS.
    event ProtocolShareUpdated(uint256 oldShareBps, uint256 newShareBps);

    /// @notice Emitted when the VM share for a vault is updated.
    /// @param vault       Vault address.
    /// @param oldShareBps Previous share in BPS.
    /// @param newShareBps New share in BPS.
    event VMShareUpdated(address indexed vault, uint256 oldShareBps, uint256 newShareBps);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The caller is not the OwnMarket contract.
    error OnlyMarket();

    /// @notice The caller is not the VM for the given vault.
    error OnlyVaultVM(address vault);

    /// @notice No fees available to claim.
    error NoFeesToClaim();

    /// @notice The share exceeds maximum allowed BPS.
    error ShareTooHigh(uint256 shareBps, uint256 maxBps);

    /// @notice A zero address was provided.
    error ZeroAddress();

    // ──────────────────────────────────────────────────────────
    //  Fee accrual (called by OwnMarket)
    // ──────────────────────────────────────────────────────────

    /// @notice Record and split a collected fee. Called by OwnMarket on order confirmation.
    /// @param vault  Vault that backed the claim.
    /// @param vm     Vault manager who confirmed.
    /// @param amount Total fee amount (already transferred to this contract).
    /// @param token  Stablecoin address.
    function accrueFee(address vault, address vm, uint256 amount, address token) external;

    // ──────────────────────────────────────────────────────────
    //  Claims
    // ──────────────────────────────────────────────────────────

    /// @notice Claim accrued protocol fees for a token. Transfers to treasury.
    /// @param token Stablecoin address.
    function claimProtocolFees(
        address token
    ) external;

    /// @notice Claim accrued LP fees for a vault. Transfers to the vault address
    ///         so that totalAssets() increases and share price appreciates.
    /// @param vault Vault address.
    /// @param token Stablecoin address.
    function claimLPFees(address vault, address token) external;

    /// @notice Claim accrued VM fees. Caller must be the VM.
    /// @param token Stablecoin address.
    function claimVMFees(
        address token
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Admin configuration
    // ──────────────────────────────────────────────────────────

    /// @notice Set the protocol's share of all fees.
    /// @param shareBps Protocol share in basis points (e.g. 2000 = 20%).
    function setProtocolShareBps(
        uint256 shareBps
    ) external;

    /// @notice Set the VM's share of the LP+VM remainder for a vault.
    ///         Only callable by the vault's VM.
    /// @param vault    Vault address.
    /// @param shareBps VM share of remainder in basis points.
    function setVMShareBps(address vault, uint256 shareBps) external;

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @notice Return the protocol share in BPS.
    function protocolShareBps() external view returns (uint256);

    /// @notice Return the VM share for a vault in BPS.
    /// @param vault Vault address.
    function vmShareBps(
        address vault
    ) external view returns (uint256);

    /// @notice Return accrued unclaimed protocol fees for a token.
    /// @param token Stablecoin address.
    function accruedProtocolFees(
        address token
    ) external view returns (uint256);

    /// @notice Return accrued unclaimed LP fees for a vault and token.
    /// @param vault Vault address.
    /// @param token Stablecoin address.
    function accruedLPFees(address vault, address token) external view returns (uint256);

    /// @notice Return accrued unclaimed VM fees.
    /// @param vm    Vault manager address.
    /// @param token Stablecoin address.
    function accruedVMFees(address vm, address token) external view returns (uint256);
}
