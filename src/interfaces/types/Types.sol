// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Types — Shared constants for the eUSD contracts

/// @dev Basis-point denominator (10 000 = 100%).
uint256 constant BPS = 10_000;

/// @dev Fixed-point precision for prices and per-share accumulators.
uint256 constant PRECISION = 1e18;
