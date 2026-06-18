// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IETokenFactory} from "../interfaces/IETokenFactory.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {EToken} from "./EToken.sol";

/// @title ETokenFactory — Deploys eToken contracts
/// @notice ADMIN-only factory for creating new eToken instances.
contract ETokenFactory is IETokenFactory {
    /// @notice ProtocolRegistry, passed to each eToken and used to resolve the factory admin role.
    IProtocolRegistry public immutable registry;

    bytes32 private constant ADMIN = keccak256("ADMIN");

    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    /// @param registry_ ProtocolRegistry address.
    constructor(
        address registry_
    ) {
        require(registry_ != address(0), "zero registry");
        registry = IProtocolRegistry(registry_);
    }

    /// @inheritdoc IETokenFactory
    function createEToken(
        string calldata name,
        string calldata symbol,
        bytes32 ticker,
        address rewardToken
    ) external onlyAdmin returns (address token) {
        token = address(new EToken(name, symbol, ticker, address(registry), rewardToken));
        emit ETokenCreated(token, ticker, symbol);
    }
}
