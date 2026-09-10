// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockAssetRegistry — Minimal AssetRegistry surface for EUSDManager unit tests
/// @notice Implements only the getters EUSDManager consumes, with direct test setters.
contract MockAssetRegistry {
    mapping(bytes32 => uint8) private _oracleTypes;
    mapping(bytes32 => mapping(address => bool)) private _validTokens;
    mapping(address => uint256) private _legacyRatios;

    function setOracleType(bytes32 ticker, uint8 oracleType) external {
        _oracleTypes[ticker] = oracleType;
    }

    function setValidToken(bytes32 ticker, address token, bool valid) external {
        _validTokens[ticker][token] = valid;
    }

    /// @dev Mark `token` legacy at `ratio` active units per legacy unit (0 = active).
    function setLegacyRatio(address token, uint256 ratio) external {
        _legacyRatios[token] = ratio;
    }

    function legacyRatioToActive(
        address token
    ) external view returns (uint256) {
        return _legacyRatios[token];
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
