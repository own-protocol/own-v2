// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {OwnVault} from "../OwnVault.sol";

/// @title OwnVaultDeployer — Stateless deployer for `OwnVault` instances
/// @notice Holds `OwnVault`'s creation code so that `VaultFactory`'s runtime
///         bytecode stays under EIP-170. Called by `VaultFactory.createVault`.
contract OwnVaultDeployer {
    function deploy(
        address collateral,
        string calldata name,
        string calldata symbol,
        address registry,
        address vm,
        uint256 maxUtilBps,
        uint256 vmShareBps
    ) external returns (address) {
        return address(new OwnVault(collateral, name, symbol, registry, vm, maxUtilBps, vmShareBps));
    }
}
