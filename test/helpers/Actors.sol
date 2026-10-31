// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Actors — Predefined addresses for test scenarios
/// @notice Deterministic addresses derived from labels for readability in traces.
library Actors {
    address constant ADMIN = address(uint160(uint256(keccak256("admin"))));
    address constant LP1 = address(uint160(uint256(keccak256("lp1"))));
    address constant MINTER1 = address(uint160(uint256(keccak256("minter1"))));
    address constant MINTER2 = address(uint160(uint256(keccak256("minter2"))));
    address constant LIQUIDATOR = address(uint160(uint256(keccak256("liquidator"))));
    address constant ATTACKER = address(uint160(uint256(keccak256("attacker"))));
}
