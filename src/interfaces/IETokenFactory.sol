// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IETokenFactory — Factory for deploying eToken contracts
/// @notice Deploys eToken instances. Admin-only creation.
interface IETokenFactory {
    /// @notice Emitted when a new eToken is deployed.
    event ETokenCreated(address indexed token, bytes32 indexed ticker, string symbol);

    /// @notice Deploy a new eToken contract.
    /// @param name        Human-readable token name (e.g. "Own Tesla").
    /// @param symbol      Token symbol (e.g. "eTSLA").
    /// @param ticker      Asset identifier as bytes32 (e.g. bytes32("TSLA")).
    /// @param rewardToken ERC-20 token used for dividend payouts.
    /// @return token      Address of the deployed eToken.
    function createEToken(
        string calldata name,
        string calldata symbol,
        bytes32 ticker,
        address rewardToken
    ) external returns (address token);
}
