// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IProtocolRegistry — Central registry of all protocol contract addresses
/// @notice Single governance-upgradable contract that stores all protocol contract addresses.
/// All other contracts reference this instead of storing individual addresses.
/// All address changes require a timelock delay, except for first-time initialization
/// (setting a slot from address(0)), which takes effect immediately.
interface IProtocolRegistry {
    // ──────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────

    /// @notice Emitted when a contract address is set for the first time (no timelock).
    /// @param key     Identifier for the contract slot.
    /// @param newAddr The address that was set.
    event ContractInitialized(bytes32 indexed key, address newAddr);

    /// @notice Emitted when a timelocked address change is proposed.
    /// @param key         Identifier for the contract slot.
    /// @param newAddr     Proposed new address.
    /// @param effectiveAt Timestamp after which the change can be executed.
    event TimelockProposed(bytes32 indexed key, address newAddr, uint256 effectiveAt);

    /// @notice Emitted when a timelocked change is executed.
    /// @param key     Identifier for the contract slot.
    /// @param oldAddr The previous address.
    /// @param newAddr The address that is now active.
    event TimelockExecuted(bytes32 indexed key, address oldAddr, address newAddr);

    /// @notice Emitted when a pending timelock proposal is cancelled.
    /// @param key Identifier for the contract slot.
    event TimelockCancelled(bytes32 indexed key);

    /// @notice Emitted when the global price-proof max age is updated.
    /// @param oldMaxAge The previous max age (seconds).
    /// @param newMaxAge The new max age (seconds).
    event PriceMaxAgeUpdated(uint256 oldMaxAge, uint256 newMaxAge);

    // ──────────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────────

    /// @notice Thrown when a zero address is provided.
    error ZeroAddress();

    /// @notice Thrown when the timelock delay has not elapsed yet.
    error TimelockNotReady();

    /// @notice Thrown when trying to execute or cancel a timelock that was never proposed.
    error TimelockNotProposed();

    /// @notice Thrown when the new address is the same as the current one.
    error SameAddress();

    /// @notice Thrown when trying to use setAddress for a slot that is already initialized.
    error AlreadyInitialized();

    /// @notice Thrown when a zero price-proof max age is provided (would reject all proofs).
    error InvalidPriceMaxAge();

    // ──────────────────────────────────────────────────────────────
    //  Getters
    // ──────────────────────────────────────────────────────────────

    /// @notice Returns the OwnMarket contract address.
    function market() external view returns (address);

    /// @notice Returns the AssetRegistry contract address.
    function assetRegistry() external view returns (address);

    /// @notice Returns the PythOracleVerifier contract address.
    function pythOracle() external view returns (address);

    /// @notice Returns the in-house OracleVerifier contract address.
    function inhouseOracle() external view returns (address);

    /// @notice Returns the ETokenFactory contract address.
    function etokenFactory() external view returns (address);

    /// @notice Returns the VaultManager contract address.
    function vaultManager() external view returns (address);

    /// @notice Returns the protocol treasury address (bad-debt collateral sink, fee recipient).
    function treasury() external view returns (address);

    /// @notice Returns the timelock delay duration in seconds.
    function timelockDelay() external view returns (uint256);

    /// @notice Max age (seconds) accepted for an inline "current price" proof — the force-execute
    ///         collateral leg and BorrowManager risk decisions. Governance-tunable. Does NOT bound
    ///         the force-execute asset leg, which uses the order's own [createdAt, now] window.
    function priceMaxAge() external view returns (uint256);

    /// @notice Set the global price-proof max age (seconds). Governance only; takes effect
    ///         immediately. Reverts on zero.
    /// @param newMaxAge The new max age in seconds.
    function setPriceMaxAge(
        uint256 newMaxAge
    ) external;

    // ──────────────────────────────────────────────────────────────
    //  Initialization (first-time set, no timelock)
    // ──────────────────────────────────────────────────────────────

    /// @notice Set a contract address for the first time. Only works when the slot is address(0).
    /// @param key     The contract slot key.
    /// @param newAddr The address to set.
    function setAddress(bytes32 key, address newAddr) external;

    // ──────────────────────────────────────────────────────────────
    //  Timelocked Updates (all changes after initialization)
    // ──────────────────────────────────────────────────────────────

    /// @notice Propose a new address for a contract slot (subject to timelock).
    /// @param key     The contract slot key.
    /// @param newAddr The proposed new address.
    function proposeAddress(bytes32 key, address newAddr) external;

    /// @notice Execute a pending timelocked change after the delay has elapsed.
    /// @param key The contract slot key to execute.
    function executeTimelock(
        bytes32 key
    ) external;

    /// @notice Cancel a pending timelocked change.
    /// @param key The contract slot key to cancel.
    function cancelTimelock(
        bytes32 key
    ) external;

    /// @notice Returns the pending timelock proposal for a given key.
    /// @param key The contract slot key.
    /// @return newAddr     The proposed new address (address(0) if none).
    /// @return effectiveAt The timestamp after which it can be executed (0 if none).
    function pendingTimelockOf(
        bytes32 key
    ) external view returns (address newAddr, uint256 effectiveAt);
}
