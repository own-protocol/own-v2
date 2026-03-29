// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VMConfig} from "./types/Types.sol";

/// @title IVaultManager — Vault manager registration and configuration
/// @notice Manages VM lifecycle: registration with a vault, exposure caps, and
///         active status. Each VM is bound 1:1 to a single vault.
interface IVaultManager {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    event VaultManagerRegistered(address indexed vm, address indexed vault);
    event VaultManagerDeregistered(address indexed vm, address indexed vault);
    event ExposureCapsUpdated(address indexed vm, uint256 maxExposure);
    event ExposureUpdated(address indexed vm, uint256 newExposure);
    event VMActiveStatusUpdated(address indexed vm, bool active);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    error VMAlreadyRegistered(address vm);
    error VMNotRegistered(address vm);
    error VMAlreadyHasVault(address vm);
    error VaultAlreadyHasVM(address vault);
    error ExposureCapExceeded(address vm, uint256 currentExposure, uint256 maxExposure);
    error ZeroAddress();
    error VMNotActive(address vm);

    // ──────────────────────────────────────────────────────────
    //  VM registration
    // ──────────────────────────────────────────────────────────

    /// @notice Register the caller as a vault manager for a specific vault.
    function registerVM(
        address vault
    ) external;

    /// @notice Deregister the caller as a vault manager.
    function deregisterVM() external;

    // ──────────────────────────────────────────────────────────
    //  VM configuration
    // ──────────────────────────────────────────────────────────

    /// @notice Set the caller's max exposure cap.
    /// @param maxExposure Max USD notional (18 decimals).
    function setExposureCaps(
        uint256 maxExposure
    ) external;

    /// @notice Pause or resume the caller's participation in order claiming.
    function setVMActive(
        bool active
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Exposure tracking (restricted — OwnMarket only)
    // ──────────────────────────────────────────────────────────

    /// @notice Update a VM's current exposure. Called by OwnMarket on claim/confirm/close.
    /// @param vm    Vault manager address.
    /// @param delta Signed exposure change (positive = increase, negative = decrease).
    function updateExposure(address vm, int256 delta) external;

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    function getVMConfig(address vm) external view returns (VMConfig memory config);
    function getVMVault(address vm) external view returns (address vault);
    function getVaultVM(address vault) external view returns (address vm);
}
