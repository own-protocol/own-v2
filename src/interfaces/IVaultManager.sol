// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VMConfig} from "./types/Types.sol";

/// @title IVaultManager — Vault manager registration and configuration
/// @notice Manages the lifecycle of vault managers: registration with a vault,
///         exposure settings, stablecoin acceptance, and per-asset off-market toggles.
///         Each VM is bound 1:1 to a single vault.
interface IVaultManager {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a vault manager registers with a vault.
    /// @param vm    Vault manager address.
    /// @param vault Vault address.
    event VaultManagerRegistered(address indexed vm, address indexed vault);

    /// @notice Emitted when a vault manager deregisters.
    /// @param vm    Vault manager address.
    /// @param vault Vault address.
    event VaultManagerDeregistered(address indexed vm, address indexed vault);

    /// @notice Emitted when a VM creates a new vault (future use).
    /// @param vm         Vault manager address.
    /// @param vault      Vault address.
    /// @param collateral Collateral token address.
    event VaultCreated(address indexed vm, address indexed vault, address indexed collateral);

    /// @notice Emitted when a VM updates their exposure caps.
    /// @param vm                   Vault manager address.
    /// @param maxExposure          New max exposure (18 decimals).
    /// @param maxOffMarketExposure New max off-market exposure (18 decimals).
    event ExposureCapsUpdated(address indexed vm, uint256 maxExposure, uint256 maxOffMarketExposure);

    /// @notice Emitted when a VM's current exposure changes.
    /// @param vm          Vault manager address.
    /// @param newExposure Updated current exposure (18 decimals).
    event ExposureUpdated(address indexed vm, uint256 newExposure);

    /// @notice Emitted when a VM toggles acceptance of a payment token.
    /// @param vm        Vault manager address.
    /// @param token     Payment token address.
    /// @param accepted  Whether the token is now accepted.
    event PaymentTokenAcceptanceUpdated(address indexed vm, address indexed token, bool accepted);

    /// @notice Emitted when a VM toggles per-asset off-market execution.
    /// @param vm      Vault manager address.
    /// @param asset   Asset ticker.
    /// @param enabled Whether off-market execution is enabled.
    event AssetOffMarketToggled(address indexed vm, bytes32 indexed asset, bool enabled);

    /// @notice Emitted when a VM pauses or resumes participation.
    /// @param vm     Vault manager address.
    /// @param active Whether the VM is now active.
    event VMActiveStatusUpdated(address indexed vm, bool active);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The vault manager is already registered.
    error VMAlreadyRegistered(address vm);

    /// @notice The vault manager is not registered.
    error VMNotRegistered(address vm);

    /// @notice The vault already has a VM bound to it.
    error VMAlreadyHasVault(address vm);

    /// @notice The vault is already bound to another VM.
    error VaultAlreadyHasVM(address vault);

    /// @notice The VM's current exposure exceeds its cap.
    error ExposureCapExceeded(address vm, uint256 currentExposure, uint256 maxExposure);

    /// @notice The VM does not accept the given payment token.
    error PaymentTokenNotAccepted(address vm, address token);

    /// @notice A zero address was provided.
    error ZeroAddress();

    /// @notice The VM is not active (paused).
    error VMNotActive(address vm);

    // ──────────────────────────────────────────────────────────
    //  VM registration
    // ──────────────────────────────────────────────────────────

    /// @notice Register the caller as a vault manager for a specific vault.
    /// @dev Enforces 1:1 binding between VMs and vaults.
    /// @param vault Vault address to register with.
    function registerVM(
        address vault
    ) external;

    /// @notice Deregister the caller as a vault manager.
    function deregisterVM() external;

    // ──────────────────────────────────────────────────────────
    //  VM configuration
    // ──────────────────────────────────────────────────────────

    /// @notice Set the caller's exposure caps.
    /// @param maxExposure          Max USD notional (18 decimals).
    /// @param maxOffMarketExposure Max USD notional during off-market hours (18 decimals).
    function setExposureCaps(uint256 maxExposure, uint256 maxOffMarketExposure) external;

    /// @notice Toggle acceptance of a payment token for orders.
    /// @param token    Payment token address.
    /// @param accepted Whether to accept the token.
    function setPaymentTokenAcceptance(address token, bool accepted) external;

    /// @notice Toggle per-asset off-market execution.
    /// @param asset   Asset ticker.
    /// @param enabled Whether to enable off-market execution for this asset.
    function setAssetOffMarketEnabled(bytes32 asset, bool enabled) external;

    /// @notice Pause or resume the caller's participation in order claiming.
    /// @dev When inactive, the VM cannot claim new orders but existing claims remain intact.
    /// @param active Whether the VM should be active.
    function setVMActive(
        bool active
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Exposure tracking (restricted caller — OwnMarket)
    // ──────────────────────────────────────────────────────────

    /// @notice Update a VM's current exposure. Called by OwnMarket on claim/confirm.
    /// @param vm    Vault manager address.
    /// @param delta Signed exposure change (positive = increase, negative = decrease).
    function updateExposure(address vm, int256 delta) external;

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @notice Return the full configuration for a vault manager.
    /// @param vm Vault manager address.
    /// @return config The VM's configuration.
    function getVMConfig(
        address vm
    ) external view returns (VMConfig memory config);

    /// @notice Return the vault a VM is registered with.
    /// @param vm Vault manager address.
    /// @return vault The vault address.
    function getVMVault(
        address vm
    ) external view returns (address vault);

    /// @notice Return the VM bound to a specific vault (reverse lookup).
    /// @param vault Vault address.
    /// @return vm The vault manager address (address(0) if none).
    function getVaultVM(
        address vault
    ) external view returns (address vm);

    /// @notice Check whether a VM accepts a specific payment token.
    /// @param vm    Vault manager address.
    /// @param token Payment token address.
    /// @return True if accepted.
    function isPaymentTokenAccepted(address vm, address token) external view returns (bool);

    /// @notice Check whether a VM has enabled off-market execution for an asset.
    /// @param vm    Vault manager address.
    /// @param asset Asset ticker.
    /// @return True if off-market execution is enabled.
    function isAssetOffMarketEnabled(address vm, bytes32 asset) external view returns (bool);
}
