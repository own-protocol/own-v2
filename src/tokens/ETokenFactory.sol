// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IETokenFactory} from "../interfaces/IETokenFactory.sol";
import {EToken} from "./EToken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ETokenFactory — Deploys eToken contracts
/// @notice Admin-only factory for creating new eToken instances.
contract ETokenFactory is IETokenFactory, Ownable {
    /// @dev ProtocolRegistry address, passed to each eToken.
    address public immutable registry;

    /// @param admin    Initial owner (protocol admin).
    /// @param registry_ ProtocolRegistry address.
    constructor(address admin, address registry_) Ownable(admin) {
        require(registry_ != address(0), "zero registry");
        registry = registry_;
    }

    /// @inheritdoc IETokenFactory
    function createEToken(
        string calldata name,
        string calldata symbol,
        bytes32 ticker,
        address rewardToken
    ) external onlyOwner returns (address token) {
        token = address(new EToken(name, symbol, ticker, registry, rewardToken));
        emit ETokenCreated(token, ticker, symbol);
    }
}
