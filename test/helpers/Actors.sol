// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Actors — Predefined addresses for test scenarios
/// @notice Deterministic addresses derived from labels for readability in traces.
library Actors {
    address constant ADMIN = address(uint160(uint256(keccak256("admin"))));
    address constant LP1 = address(uint160(uint256(keccak256("lp1"))));
    address constant LP2 = address(uint160(uint256(keccak256("lp2"))));
    address constant LP3 = address(uint160(uint256(keccak256("lp3"))));
    address constant VM1 = address(uint160(uint256(keccak256("vm1"))));
    address constant VM2 = address(uint160(uint256(keccak256("vm2"))));
    address constant MINTER1 = address(uint160(uint256(keccak256("minter1"))));
    address constant MINTER2 = address(uint160(uint256(keccak256("minter2"))));
    address constant LIQUIDATOR = address(uint160(uint256(keccak256("liquidator"))));
    address constant ATTACKER = address(uint160(uint256(keccak256("attacker"))));
    address constant ORACLE_SIGNER = address(uint160(uint256(keccak256("oracleSigner"))));
    address constant FEE_RECIPIENT = address(uint160(uint256(keccak256("feeRecipient"))));
}
