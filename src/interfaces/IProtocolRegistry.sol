// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IProtocolRegistry — Central registry of all protocol contract addresses + role authority
/// @notice Single governance-controlled contract that stores all protocol contract addresses and
///         acts as the protocol's AccessControl authority. Other contracts reference this instead
///         of storing individual addresses and resolve permissions via {hasRole}.
/// @dev Address changes and `priceMaxAge` are gated by the `PROTOCOL_ADMIN` role, which is
///      expected to be held by a TimelockController, so those changes are time-delayed.
interface IProtocolRegistry is IAccessControl {
    // ──────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────

    /// @notice Emitted when a contract address slot is set or updated.
    /// @param key     Identifier for the contract slot.
    /// @param oldAddr The previous address (address(0) if first set).
    /// @param newAddr The address that is now active.
    event AddressSet(bytes32 indexed key, address oldAddr, address newAddr);

    /// @notice Emitted when the global price-proof max age is updated.
    /// @param oldMaxAge The previous max age (seconds).
    /// @param newMaxAge The new max age (seconds).
    event PriceMaxAgeUpdated(uint256 oldMaxAge, uint256 newMaxAge);

    // ──────────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────────

    /// @notice Thrown when a zero address is provided.
    error ZeroAddress();

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

    /// @notice Returns the protocol treasury address (bad-debt collateral sink).
    function treasury() external view returns (address);

    /// @notice Max age (seconds) accepted for an inline "current price" proof — the force-execute
    ///         collateral leg and BorrowManager risk decisions. Governance-tunable. Does NOT bound
    ///         the force-execute asset leg, which uses the order's own [createdAt, now] window.
    function priceMaxAge() external view returns (uint256);

    // ──────────────────────────────────────────────────────────────
    //  Setters (PROTOCOL_ADMIN — held by the timelock)
    // ──────────────────────────────────────────────────────────────

    /// @notice Set or update a contract address slot. Gated by `PROTOCOL_ADMIN`.
    /// @param key     The contract slot key.
    /// @param newAddr The address to set (non-zero).
    function setAddress(bytes32 key, address newAddr) external;

    /// @notice Set the global price-proof max age (seconds). Gated by `PROTOCOL_ADMIN`.
    ///         Reverts on zero.
    /// @param newMaxAge The new max age in seconds.
    function setPriceMaxAge(
        uint256 newMaxAge
    ) external;
}
