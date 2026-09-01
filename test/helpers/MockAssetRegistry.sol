// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockAssetRegistry — Minimal AssetRegistry surface for EUSDManager unit tests
/// @notice Implements only the getters EUSDManager consumes, with direct test setters.
contract MockAssetRegistry {
    mapping(bytes32 => uint8) private _oracleTypes;
    mapping(bytes32 => mapping(address => bool)) private _validTokens;

    function setOracleType(bytes32 ticker, uint8 oracleType) external {
        _oracleTypes[ticker] = oracleType;
    }

    function setValidToken(bytes32 ticker, address token, bool valid) external {
        _validTokens[ticker][token] = valid;
    }

    function getOracleType(
        bytes32 ticker
    ) external view returns (uint8) {
        return _oracleTypes[ticker];
    }

    function isValidToken(bytes32 ticker, address token) external view returns (bool) {
        return _validTokens[ticker][token];
    }
}
