// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVaultFactory — Admin-controlled vault deployment and registry
/// @notice Protocol admin creates vaults with chosen collateral and VM.
///         OwnMarket verifies vaults are registered here before processing orders.
interface IVaultFactory {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    event VaultCreated(address indexed vault, address indexed collateral, address indexed vm);
    event VaultDeregistered(address indexed vault);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error VaultNotRegistered(address vault);

    // ──────────────────────────────────────────────────────────
    //  Vault creation (admin only)
    // ──────────────────────────────────────────────────────────

    /// @notice Deploy a new vault. Only callable by protocol admin.
    /// @param collateral Underlying collateral ERC-20 (e.g. WETH).
    /// @param vm         Vault manager address bound to this vault.
    /// @param name       Vault share token name.
    /// @param symbol     Vault share token symbol.
    /// @param maxUtilBps Initial max utilization in BPS.
    /// @param vmShareBps Initial VM fee share (of LP+VM remainder) in BPS.
    /// @return vault The deployed vault address.
    function createVault(
        address collateral,
        address vm,
        string calldata name,
        string calldata symbol,
        uint256 maxUtilBps,
        uint256 vmShareBps
    ) external returns (address vault);

    /// @notice Deregister a vault so it can no longer be used. Only callable by admin.
    /// @param vault The vault address to deregister.
    function deregisterVault(
        address vault
    ) external;

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @notice Check if a vault was deployed by this factory.
    function isRegisteredVault(
        address vault
    ) external view returns (bool);

    /// @notice Return all factory-deployed vault addresses.
    function getAllVaults() external view returns (address[] memory);
}
