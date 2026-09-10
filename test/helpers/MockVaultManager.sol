// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockVaultManager — Minimal halt surface for EUSDManager unit tests
contract MockVaultManager {
    mapping(bytes32 => bool) private _halted;
    mapping(bytes32 => uint256) private _haltPrice;
    mapping(bytes32 => bool) private _paused;

    function halt(bytes32 asset, uint256 haltPrice) external {
        _halted[asset] = true;
        _haltPrice[asset] = haltPrice;
    }

    function setTradingPaused(bytes32 asset, bool paused) external {
        _paused[asset] = paused;
    }

    function isTradingPaused(
        bytes32 asset
    ) external view returns (bool) {
        return _paused[asset];
    }

    function isAssetHalted(
        bytes32 asset
    ) external view returns (bool) {
        return _halted[asset];
    }

    function assetHaltPrice(
        bytes32 asset
    ) external view returns (uint256) {
        return _haltPrice[asset];
    }
}
