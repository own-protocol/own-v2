// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title HookMiner — finds a CREATE2 salt whose address encodes a hook's permission flags
/// @notice Uniswap v4 reads a hook's permissions from the low 14 bits of its address, so the hook
///         must be deployed at an address whose low bits equal exactly its flags.
library HookMiner {
    uint160 internal constant FLAG_MASK = Hooks.ALL_HOOK_MASK;
    uint256 internal constant MAX_LOOP = 200_000;

    error SaltNotFound();

    /// @param deployer      CREATE2 deployer (forge scripts use the deterministic deployer).
    /// @param flags         Required low bits.
    /// @param creationCode  Contract creation code.
    /// @param args          ABI-encoded constructor arguments.
    /// @return hook The address the salt deploys to.
    /// @return salt The salt.
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory args
    ) internal view returns (address hook, bytes32 salt) {
        flags = flags & FLAG_MASK;
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, args));
        for (uint256 i; i < MAX_LOOP; ++i) {
            salt = bytes32(i);
            hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if (uint160(hook) & FLAG_MASK == flags && hook.code.length == 0) return (hook, salt);
        }
        revert SaltNotFound();
    }
}
